import Foundation
import MeetingLog

struct ChannelOutput: Sendable, Equatable {
    var speaker: Speaker
    var start: Date
    var end: Date
    var line: MeetingLine
}

/// One capture channel (mic = Me, system = Others): samples in, stamped
/// lines out. Samples arrive from audio threads through an `AsyncStream`
/// so their order is kept; one task drains it, so VAD and transcription
/// never run concurrently for the same channel.
actor MeetingChannel {
    private let speaker: Speaker
    private let detector: SpeechDetector
    private let transcriber: any Transcriber
    private let sampleRate: Double
    private let clock: @Sendable () -> Date
    private let onOutput: @Sendable (ChannelOutput) async -> Void
    private let continuation: AsyncStream<[Float]>.Continuation
    private var chunker: FrameChunker
    private var segmenter: SpeechSegmenter
    private var origin: Date?
    private let stream: AsyncStream<[Float]>
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
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(2_000))
        self.continuation = continuation
        self.stream = stream
        // Starts draining right away so the bounded buffer never fills during a
        // call. `finish()` also calls this; it is idempotent (actor-isolated).
        Task { await self.startDrainingIfNeeded() }
    }

    nonisolated func feed(_ samples: [Float]) {
        continuation.yield(samples)
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
            for await samples in stream { await self.process(samples) }
            await self.emit(self.flushSegmenter())
        }
    }

    private func process(_ samples: [Float]) async {
        if origin == nil { origin = clock() }
        for frame in chunker.push(samples) {
            let speech = (try? await detector.isSpeech(frame)) ?? false
            await emit(segmenter.push(frame: frame, isSpeech: speech))
        }
    }

    private func flushSegmenter() -> [SpeechSegment] {
        segmenter.flush()
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
                line = MeetingLine(time: start, kind: .gap(until: end))
            }
            await onOutput(ChannelOutput(speaker: speaker, start: start, end: end, line: line))
        }
    }
}
