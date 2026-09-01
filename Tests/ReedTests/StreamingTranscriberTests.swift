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
            + [pass("second recording batch")]
    )
    let streamer = StreamingTranscriber(transcriber: fake, config: config)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }
    _ = try await streamer.finish()

    await streamer.begin()
    #expect(await streamer.confirmedSegments == 0)

    // A begin() that reset confirmedSegments but forgot buffer, wholeRecording,
    // trimmedSamples, or the engine would still leak state from the previous
    // recording here — a partial reset like that would still pass the
    // confirmedSegments check above.
    await streamer.append([Float](repeating: 0.1, count: 32_000))  // fresh 2s recording
    _ = await streamer.runPassIfDue()

    let lengths = await fake.receivedLengths
    let offsets = await fake.offsets
    // The slice and offset must reflect only the new recording: a stale
    // buffer would inflate the length, and a stale trimmedSamples would
    // shift the offset away from 0 even though this is the start of a new
    // recording.
    #expect(lengths.last == 32_000 + 16_000)
    #expect(offsets.last == 0)

    // Fewer than 1 confirmation happened on this fresh recording, so
    // finish() takes the batch fallback over wholeRecording — a stale
    // wholeRecording would still carry the previous recording's 160,000
    // samples forward into this length.
    _ = try await streamer.finish()
    #expect(await fake.receivedLengths.last == 32_000 + 16_000)
}

@Test func timingsBeyondTheRecordingDoNotLoseAudio() async throws {
    var config = AgreementConfig()
    config.minConfirmedSegmentsToTrustStreaming = 1

    // "one two." confirms exactly as `script` does, but the hypothesis words
    // ("three" onward) carry timings far beyond any audio this test ever
    // appends — simulating the model placing a hallucinated word inside the
    // trailing silence pad, which real Parakeet output can do.
    func passWithHypothesisFarInTheFuture() -> TranscriptionPass {
        let confirmed = [
            TimedWord(text: "one", startTime: 0, endTime: 0.9),
            TimedWord(text: "two.", startTime: 1, endTime: 1.9),
        ]
        let hypothesis = ["three", "four.", "five", "six.", "seven", "eight"]
            .enumerated().map { i, w in
                TimedWord(text: w, startTime: 100 + Double(i), endTime: 100 + Double(i) + 0.9)
            }
        let words = confirmed + hypothesis
        return TranscriptionPass(text: words.map(\.text).joined(separator: " "), words: words, confidence: 1.0)
    }

    let fake = ScriptedTranscriber(
        passes: Array(repeating: passWithHypothesisFarInTheFuture(), count: 4)
            + [pass("the untranscribed tail")]
    )
    let streamer = StreamingTranscriber(transcriber: fake, config: config)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 80_000))  // 5 seconds
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }
    #expect(await streamer.confirmedSegments == 1)

    // More real audio arrives after the confirmation whose hypothesis start
    // time (100s) sits far beyond anything actually recorded.
    await streamer.append([Float](repeating: 0.1, count: 32_000))  // 2 more seconds

    let result = try await streamer.finish()

    // No audio was discarded: the tail pass must still cover everything
    // appended after "one two." — not be skipped, and not have had the
    // buffer wiped out from under it, because the seek point sat far beyond
    // the real recording.
    #expect(result == "one two. the untranscribed tail")

    let lengths = await fake.receivedLengths
    // The final (finish()) call is the 5th real transcribe call. Its slice
    // must be the full 112,000 real samples (80,000 + 32,000) plus padding —
    // not truncated, and not empty.
    #expect(lengths.last == 112_000 + 16_000)
}

@Test func previewSuspendsWhenTheUnconfirmedTailGrowsTooLarge() async throws {
    // Never actually consumed by runPassIfDue() below, since the cap must
    // stop it from calling transcribe at all — available for finish()'s
    // single fallback call instead.
    let fake = ScriptedTranscriber(passes: [pass("the complete batch transcript")])
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 17 * 16_000))  // 17s, past the 15s cap
    #expect(await streamer.runPassIfDue() == nil)

    // A run-on speaker: more audio keeps arriving without ever confirming.
    await streamer.append([Float](repeating: 0.1, count: 5 * 16_000))
    #expect(await streamer.runPassIfDue() == nil)
    #expect(await fake.receivedLengths.isEmpty)  // never once called transcribe

    // The final transcript is unaffected: confirmedSegments never reached
    // the trust threshold, so finish() falls back to a batch pass over the
    // whole (complete, correct) recording.
    let result = try await streamer.finish()
    #expect(result == "the complete batch transcript")
    #expect(await fake.receivedLengths.last == 22 * 16_000 + 16_000)
}
