import Foundation
import MeetingLog

struct ChannelOutput: Sendable, Equatable {
    var speaker: Speaker
    var start: Date
    var end: Date
    var line: MeetingLine
}

/// Tracks whether the stream is currently dropping audio, so a backlog is
/// logged once per episode rather than once per chunk. Touched from audio threads.
private final class DropEpisode: @unchecked Sendable {
    private let lock = NSLock()
    private var dropping = false

    /// Returns true when a new episode starts (the caller should log).
    func record(dropped: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let starts = dropped && !dropping
        dropping = dropped
        return starts
    }
}

/// One capture channel (mic = Me, system = Others): samples in, stamped
/// lines out. Samples arrive from audio threads through an `AsyncStream`
/// so their order is kept; one task drains it, so VAD and transcription
/// never run concurrently for the same channel.
///
/// Each chunk is stamped with the wall time it was fed. Line times come from
/// sample counts, re-anchored to wall time whenever they drift by more than
/// 1 s (audio dropped on backlog, or a gap in feeding). Callers should still
/// `finish()` and create a new channel when pausing capture.
///
/// `finish()` is required: the drain task retains the channel until the
/// stream ends, so a channel that is only released leaks.
actor MeetingChannel {
    private struct Chunk: Sendable {
        var samples: [Float]
        /// Wall time when the chunk was fed, i.e. the moment its audio ended.
        var capturedAt: Date
    }

    /// Worst-case chunk is 10 ms of audio, so 12_000 chunks is ~120 s of
    /// backlog before the oldest audio is dropped.
    private static let maxBufferedChunks = 12_000
    private static let reanchorThreshold: TimeInterval = 1

    private let speaker: Speaker
    private let detector: SpeechDetector
    private let transcriber: any Transcriber
    private let sampleRate: Double
    private let clock: @Sendable () -> Date
    private let onOutput: @Sendable (ChannelOutput) async -> Void
    private let continuation: AsyncStream<Chunk>.Continuation
    private let drops = DropEpisode()
    private var chunker: FrameChunker
    private var segmenter: SpeechSegmenter
    private var origin: Date?
    private var samplesSeen = 0
    private var vadFailing = false
    private let stream: AsyncStream<Chunk>
    private var drain: Task<Void, Never>?

    init(
        speaker: Speaker, detector: SpeechDetector, transcriber: any Transcriber,
        frameSize: Int = 4096, sampleRate: Double = reedSampleRate,
        clock: @escaping @Sendable () -> Date = { Date() },
        onOutput: @escaping @Sendable (ChannelOutput) async -> Void
    ) {
        self.speaker = speaker
        self.detector = detector
        self.transcriber = transcriber
        self.sampleRate = sampleRate
        self.clock = clock
        self.onOutput = onOutput
        self.chunker = FrameChunker(frameSize: frameSize)
        self.segmenter = SpeechSegmenter(frameSize: frameSize, sampleRate: sampleRate)
        // Bounded: if transcription falls behind for minutes, drop the
        // oldest audio rather than grow without limit.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Chunk.self, bufferingPolicy: .bufferingNewest(Self.maxBufferedChunks))
        self.continuation = continuation
        self.stream = stream
        // Starts draining right away so the bounded buffer never fills during a
        // call. `finish()` also calls this; it is idempotent (actor-isolated).
        Task { await self.startDrainingIfNeeded() }
    }

    nonisolated func feed(_ samples: [Float]) {
        let result = continuation.yield(Chunk(samples: samples, capturedAt: clock()))
        var dropped = false
        if case .dropped = result { dropped = true }
        if drops.record(dropped: dropped) {
            NSLog("Reed meeting (%@): transcription is behind, dropping oldest audio", "\(speaker)")
        }
    }

    /// Stops accepting audio, transcribes whatever speech is still open, returns when done.
    func finish() async {
        // The task started in `init` may not have run yet.
        startDrainingIfNeeded()
        continuation.finish()
        await drain?.value
    }

    private func startDrainingIfNeeded() {
        guard drain == nil else { return }
        let stream = stream
        drain = Task {
            for await chunk in stream { await self.process(chunk) }
            await self.finishStream()
        }
    }

    private func finishStream() async {
        if let tail = chunker.flushRemainder() { await process(frame: tail) }
        await emit(segmenter.flush())
    }

    private func process(_ chunk: Chunk) async {
        let duration = Double(chunk.samples.count) / sampleRate
        let chunkStart = chunk.capturedAt.addingTimeInterval(-duration)
        let streamTime = Double(samplesSeen) / sampleRate
        if let current = origin {
            if abs(current.addingTimeInterval(streamTime).timeIntervalSince(chunkStart)) > Self.reanchorThreshold {
                origin = chunkStart.addingTimeInterval(-streamTime)
            }
        } else {
            origin = chunkStart.addingTimeInterval(-streamTime)
        }
        samplesSeen += chunk.samples.count
        for frame in chunker.push(chunk.samples) { await process(frame: frame) }
    }

    private func process(frame: [Float]) async {
        let speech: Bool
        do {
            speech = try await detector.isSpeech(frame)
            vadFailing = false
        } catch {
            if !vadFailing { NSLog("Reed meeting (%@): speech detection failed: %@", "\(speaker)", "\(error)") }
            vadFailing = true
            speech = false
        }
        await emit(segmenter.push(frame: frame, isSpeech: speech))
    }

    private func emit(_ segments: [SpeechSegment]) async {
        guard let origin else { return }
        for segment in segments {
            let start = origin.addingTimeInterval(Double(segment.startSample) / sampleRate)
            let end = start.addingTimeInterval(Double(segment.samples.count) / sampleRate)
            let line: MeetingLine
            do {
                let pass = try await transcriber.transcribe(segment.samples, timeOffset: 0)
                guard !pass.text.isEmpty else { continue }
                line = MeetingLine(time: start, kind: .speech(speaker, pass.text))
            } catch {
                NSLog("Reed meeting (%@): transcription failed: %@", "\(speaker)", "\(error)")
                line = MeetingLine(time: start, kind: .gap(until: end))
            }
            await onOutput(ChannelOutput(speaker: speaker, start: start, end: end, line: line))
        }
    }
}
