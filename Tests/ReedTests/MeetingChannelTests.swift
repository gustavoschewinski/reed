import Foundation
import MeetingLog
import Testing
@testable import Reed

private final class FakeDetector: SpeechDetector, @unchecked Sendable {
    func isSpeech(_ frame: [Float]) async throws -> Bool { frame.first ?? 0 > 0 }
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

@Test func speechBecomesALineStampedFromTheFirstSample() async {
    let sink = Sink()
    let channel = MeetingChannel(speaker: .me, detector: FakeDetector(), transcriber: FakeTranscriber(),
                                 frameSize: 4, sampleRate: 4, clock: { t0 }, onOutput: { await sink.add($0) })
    channel.feed([0, 0, 0, 0])             // silence frame (pre-roll), stream starts at t0
    channel.feed([1, 1, 1, 1, 1, 1, 1, 1]) // two speech frames
    channel.feed([0, 0, 0, 0])             // silence: segment ends (tail frame included)
    await channel.finish()
    let outputs = await sink.outputs
    #expect(outputs == [ChannelOutput(
        speaker: .me, start: t0, end: t0.addingTimeInterval(4),
        line: MeetingLine(time: t0, kind: .speech(.me, "fala 16"))
    )])
}

@Test func transcriptionFailureWritesAGap() async {
    let sink = Sink()
    let channel = MeetingChannel(speaker: .others, detector: FakeDetector(), transcriber: FakeTranscriber(fail: true),
                                 frameSize: 4, sampleRate: 4, clock: { t0 }, onOutput: { await sink.add($0) })
    channel.feed([1, 1, 1, 1, 0, 0, 0, 0])
    await channel.finish()
    let outputs = await sink.outputs
    #expect(outputs.map(\.line.kind) == [.gap(until: t0.addingTimeInterval(2))])
}

@Test func silenceProducesNoOutput() async {
    let sink = Sink()
    let channel = MeetingChannel(speaker: .others, detector: FakeDetector(), transcriber: FakeTranscriber(),
                                 frameSize: 4, sampleRate: 4, clock: { t0 }, onOutput: { await sink.add($0) })
    for _ in 0..<20 { channel.feed([0, 0, 0, 0]) }
    await channel.finish()
    #expect(await sink.outputs.isEmpty)
}
