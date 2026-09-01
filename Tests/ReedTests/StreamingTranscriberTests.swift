import Testing
@testable import Reed

/// Returns scripted passes in order, and records what it was asked to transcribe.
private actor ScriptedTranscriber: Transcriber {
    private var passes: [TranscriptionPass]
    private(set) var receivedLengths: [Int] = []
    private(set) var offsets: [Double] = []

    init(passes: [TranscriptionPass]) { self.passes = passes }

    func prepare() async throws {}

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        receivedLengths.append(samples.count)
        offsets.append(timeOffset)
        return passes.isEmpty ? .empty : passes.removeFirst()
    }
}

private func pass(_ text: String, from start: Double = 0, confidence: Float = 1.0)
    -> TranscriptionPass
{
    let words = text.split(separator: " ").enumerated().map { i, w in
        TimedWord(
            text: String(w), startTime: start + Double(i),
            endTime: start + Double(i) + 0.9, confidence: confidence
        )
    }
    return TranscriptionPass(text: text, words: words, confidence: confidence)
}

private let script = "one two. three four. five six. seven eight"

@Test func passesArePaddedWithTrailingSilence() async throws {
    let fake = ScriptedTranscriber(passes: [pass(script)])
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 32_000))  // 2 seconds
    _ = await streamer.runPassIfDue()

    let lengths = await fake.receivedLengths
    // 2s of audio plus 1s of appended silence.
    #expect(lengths == [32_000 + 16_000])
}

@Test func nothingIsTranscribedBelowTheMinimumAudioLength() async throws {
    let fake = ScriptedTranscriber(passes: [pass(script)])
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 800))  // 50 ms
    _ = await streamer.runPassIfDue()

    #expect(await fake.receivedLengths.isEmpty)
}

@Test func confirmedAudioIsTrimmedFromTheBuffer() async throws {
    let fake = ScriptedTranscriber(passes: Array(repeating: pass(script), count: 5))
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))  // 10 seconds
    for _ in 0..<5 { _ = await streamer.runPassIfDue() }

    let lengths = await fake.receivedLengths
    // "one two." confirms on the 4th process() call (Task 3's engine needs a
    // first pass to establish a baseline plus 3 agreeing passes after it), but
    // a pass's slice is dispatched BEFORE that pass's own process() runs — so
    // the 4th pass still sends the full, untrimmed buffer, and it's the 5th
    // pass (index 4) that is the first to start from the trimmed position.
    #expect(lengths.count == 5)
    #expect(lengths[4] < lengths[0])
    #expect(await streamer.confirmedSegments == 1)
}

@Test func offsetsTrackWhereTheSliceBeginsInTheRecording() async throws {
    let fake = ScriptedTranscriber(passes: Array(repeating: pass(script), count: 5))
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<5 { _ = await streamer.runPassIfDue() }

    let offsets = await fake.offsets
    #expect(offsets[0] == 0)
    // "one two." confirms on the 4th process() call, but that pass's own slice
    // was already dispatched at offset 0 before its process() ran. The 5th
    // pass (index 4) is the first one built after the confirmation, so it's
    // the first to seek to "three"'s start time, 2.0s.
    #expect(offsets[4] == 2.0)
}

@Test func finishFallsBackToBatchWhenTooLittleWasConfirmed() async throws {
    let fake = ScriptedTranscriber(passes: [pass("mumbled"), pass("the clean batch result")])
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 48_000))
    _ = await streamer.runPassIfDue()

    // One confirmed segment is below the threshold of three, so streaming output
    // is discarded entirely.
    #expect(try await streamer.finish() == "the clean batch result")
}

@Test func finishAppendsTheTailToConfirmedTextWhenStreamingIsTrusted() async throws {
    var config = AgreementConfig()
    config.minConfirmedSegmentsToTrustStreaming = 1

    let fake = ScriptedTranscriber(
        passes: Array(repeating: pass(script), count: 4) + [pass("nine ten")]
    )
    let streamer = StreamingTranscriber(transcriber: fake, config: config)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }

    #expect(try await streamer.finish() == "one two. nine ten")
}

@Test func fallbackTranscribesTheRealAudioNotSilence() async throws {
    // One confirmation trims audio while still leaving confirmedSegments below
    // the threshold, so the fallback fires against an already-trimmed buffer.
    let fake = ScriptedTranscriber(
        passes: Array(repeating: pass(script), count: 4) + [pass("batch result")]
    )
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }
    #expect(await streamer.confirmedSegments == 1)

    _ = try await streamer.finish()

    // The final call is the fallback. It must receive the whole 160,000 samples
    // plus padding — not a buffer with the confirmed region blanked out.
    let lengths = await fake.receivedLengths
    #expect(lengths.last == 160_000 + 16_000)
}

@Test func beginResetsStateBetweenRecordings() async throws {
    var config = AgreementConfig()
    config.minConfirmedSegmentsToTrustStreaming = 1

    let fake = ScriptedTranscriber(
        passes: Array(repeating: pass(script), count: 4) + [pass("")] + [pass("fresh")]
    )
    let streamer = StreamingTranscriber(transcriber: fake, config: config)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }
    _ = try await streamer.finish()

    await streamer.begin()
    #expect(await streamer.confirmedSegments == 0)
}
