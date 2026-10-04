import Foundation
import MeetingLog
import Testing
@testable import Reed

private final class FakeDetector: SpeechDetector, @unchecked Sendable {
    func isSpeech(_ frame: [Float]) async throws -> Bool { frame.first ?? 0 > 0 }
}

/// Counts how often VAD actually runs.
private final class CountingDetector: SpeechDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func isSpeech(_ frame: [Float]) async throws -> Bool {
        lock.withLock { count += 1 }
        return frame.first ?? 0 > 0
    }
}

private struct FakeTranscriber: Transcriber {
    var fail = false
    func prepare() async throws {}
    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        if fail { throw CancellationError() }
        return TranscriptionPass(text: "fala \(samples.count)", words: [], confidence: 1)
    }
}

private actor Sink {
    var outputs: [ChannelOutput] = []
    func add(_ o: ChannelOutput) { outputs.append(o) }
}

private let t0 = Date(timeIntervalSince1970: 1_000)

/// Test clock: tests set the "wall time" before each feed.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(_ now: Date) { self.now = now }
    func set(_ date: Date) { lock.lock(); now = date; lock.unlock() }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return now }
}

/// Feeds are paced like live audio; stream time (4 samples = 1 s) and clock agree.
private func makeChannel(_ speaker: Speaker, _ transcriber: FakeTranscriber, _ clock: TestClock, _ sink: Sink) -> MeetingChannel {
    MeetingChannel(speaker: speaker, detector: FakeDetector(), transcriber: transcriber,
                   frameSize: 4, sampleRate: 4, clock: { clock.read() }, onOutput: { await sink.add($0) })
}

@Test func speechBecomesALineStampedFromTheFirstSample() async {
    let sink = Sink(), clock = TestClock(t0)
    let channel = makeChannel(.me, FakeTranscriber(), clock, sink)
    clock.set(t0.addingTimeInterval(1)); channel.feed([0, 0, 0, 0])             // silence frame (pre-roll)
    clock.set(t0.addingTimeInterval(3)); channel.feed([1, 1, 1, 1, 1, 1, 1, 1]) // two speech frames
    clock.set(t0.addingTimeInterval(4)); channel.feed([0, 0, 0, 0])             // silence: segment ends
    await channel.finish()
    let outputs = await sink.outputs
    #expect(outputs == [ChannelOutput(
        speaker: .me, start: t0, end: t0.addingTimeInterval(4),
        line: MeetingLine(time: t0, kind: .speech(.me, "fala 16"))
    )])
}

@Test func transcriptionFailureWritesAGap() async {
    let sink = Sink(), clock = TestClock(t0.addingTimeInterval(2))
    let channel = makeChannel(.others, FakeTranscriber(fail: true), clock, sink)
    channel.feed([1, 1, 1, 1, 0, 0, 0, 0])
    await channel.finish()
    let outputs = await sink.outputs
    #expect(outputs.map(\.line.kind) == [.gap(until: t0.addingTimeInterval(2))])
}

@Test func silenceProducesNoOutput() async {
    let sink = Sink(), clock = TestClock(t0)
    let channel = makeChannel(.others, FakeTranscriber(), clock, sink)
    for i in 1...20 { clock.set(t0.addingTimeInterval(Double(i))); channel.feed([0, 0, 0, 0]) }
    await channel.finish()
    #expect(await sink.outputs.isEmpty)
}

@Test func aGapInFeedingReanchorsLaterLinesToWallTime() async {
    let sink = Sink(), clock = TestClock(t0.addingTimeInterval(2))
    let channel = makeChannel(.me, FakeTranscriber(), clock, sink)
    channel.feed([1, 1, 1, 1, 0, 0, 0, 0])                 // line at t0
    clock.set(t0.addingTimeInterval(62))                    // 60 s with no feeding
    channel.feed([1, 1, 1, 1, 0, 0, 0, 0])                 // line should be at t0 + 60
    await channel.finish()
    let times = await sink.outputs.map(\.line.time)
    #expect(times == [t0, t0.addingTimeInterval(60)])
}

@Test func trailingPartialFrameIsStillAnalysedOnFinish() async {
    let sink = Sink(), clock = TestClock(t0.addingTimeInterval(1))
    let channel = makeChannel(.me, FakeTranscriber(), clock, sink)
    channel.feed([1, 1, 1])                                 // less than one frame
    await channel.finish()
    let outputs = await sink.outputs
    #expect(outputs.count == 1)
    #expect(outputs.first?.line.kind == .speech(.me, "fala 4"))
}

@Test func digitalSilenceSkipsSpeechDetection() async {
    let sink = Sink(), clock = TestClock(t0), detector = CountingDetector()
    let channel = MeetingChannel(speaker: .others, detector: detector, transcriber: FakeTranscriber(),
                                 frameSize: 4, sampleRate: 4, clock: { clock.read() }, onOutput: { await sink.add($0) })
    for i in 1...10 { clock.set(t0.addingTimeInterval(Double(i))); channel.feed([0, 0, 0, 0]) }
    clock.set(t0.addingTimeInterval(11)); channel.feed([0.001, 0, 0, 0])  // quiet but not digital silence
    clock.set(t0.addingTimeInterval(12)); channel.feed([1, 1, 1, 1])
    await channel.finish()
    #expect(detector.calls == 2)
    #expect(await sink.outputs.count == 1)
}
