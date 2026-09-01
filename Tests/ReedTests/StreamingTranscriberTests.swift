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
    let fake = ScriptedTranscriber(passes: Array(repeating: pass(script), count: 4))
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))  // 10 seconds
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }

    let lengths = await fake.receivedLengths
    // The finished sentences confirm on the 3rd process() call (a baseline
    // pass plus 2 agreeing passes), but a pass's slice is dispatched BEFORE
    // that pass's own process() runs — so the 3rd pass still sends the full,
    // untrimmed buffer, and it's the 4th pass (index 3) that is the first
    // to start from the trimmed position.
    #expect(lengths.count == 4)
    #expect(lengths[3] < lengths[0])
}

@Test func offsetsTrackWhereTheSliceBeginsInTheRecording() async throws {
    let fake = ScriptedTranscriber(passes: Array(repeating: pass(script), count: 4))
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }

    let offsets = await fake.offsets
    #expect(offsets[0] == 0)
    // "one two. three four. five six." confirms on the 3rd process() call,
    // but that pass's own slice was already dispatched at offset 0 before
    // its process() ran. The 4th pass (index 3) is the first one built after
    // the confirmation, so it's the first to seek to "seven"'s reported
    // start time, 6.0s — minus the leading guard band (Item 13), which
    // pulls the actual seek point back to 5.9s so a slightly-early acoustic
    // onset is never trimmed away.
    #expect(offsets[3] == 6.0 - AgreementConfig().leadingGuardBandSeconds)
}

@Test func trimAndSeekNeverLandCloserThanTheGuardBandToTheFirstUnconfirmedWord() async throws {
    let fake = ScriptedTranscriber(passes: Array(repeating: pass(script), count: 4))
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<4 { _ = await streamer.runPassIfDue() }

    let offsets = await fake.offsets
    let firstUnconfirmedWordStart = 6.0  // "seven", per `script`/`pass(_:)`
    let guardBand = AgreementConfig().leadingGuardBandSeconds
    #expect(guardBand > 0)  // sanity: a band of 0 would make this test meaningless
    #expect(offsets[3] == firstUnconfirmedWordStart - guardBand)
    #expect(offsets[3] < firstUnconfirmedWordStart)
}

@Test func finishTranscribesTheWholeRecordingInOnePass() async throws {
    // Three agreeing passes confirm and trim the opening sentences, so the
    // streaming buffer no longer holds the start of the recording by the
    // time finish() runs. The final pass must still receive every sample —
    // the real audio, not a buffer with the confirmed region blanked out —
    // and its text is the result, with nothing streamed stitched in.
    let fake = ScriptedTranscriber(
        passes: Array(repeating: pass(script), count: 3) + [pass("the clean batch result")]
    )
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<3 { _ = await streamer.runPassIfDue() }

    #expect(try await streamer.finish() == "the clean batch result")
    #expect(await fake.receivedLengths.last == 160_000 + 16_000)
    #expect(await fake.offsets.last == 0)
}

@Test func beginResetsStateBetweenRecordings() async throws {
    let fake = ScriptedTranscriber(
        passes: Array(repeating: pass(script), count: 3) + [pass("first recording")] + [pass("fresh")]
            + [pass("second recording")]
    )
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))
    for _ in 0..<3 { _ = await streamer.runPassIfDue() }
    _ = try await streamer.finish()

    await streamer.begin()

    // A begin() that forgot buffer, wholeRecording, trimmedSamples, or the
    // engine would leak state from the previous recording here.
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

    // A stale wholeRecording would still carry the previous recording's
    // 160,000 samples forward into finish()'s pass.
    #expect(try await streamer.finish() == "second recording")
    #expect(await fake.receivedLengths.last == 32_000 + 16_000)
}

@Test func timingsBeyondTheRecordingDoNotLoseAudio() async throws {
    // The finished sentences confirm exactly as `script` does, but the words
    // carry timings far beyond any audio this test ever appends —
    // simulating the model placing hallucinated words inside the trailing
    // silence pad, which real Parakeet output can do.
    func passWithWordsFarInTheFuture() -> TranscriptionPass {
        let confirmed = [
            TimedWord(text: "one", startTime: 0, endTime: 0.9),
            TimedWord(text: "two.", startTime: 1, endTime: 1.9),
        ]
        let future = ["three", "four.", "five", "six.", "seven", "eight"]
            .enumerated().map { i, w in
                TimedWord(text: w, startTime: 100 + Double(i), endTime: 100 + Double(i) + 0.9)
            }
        let words = confirmed + future
        return TranscriptionPass(text: words.map(\.text).joined(separator: " "), words: words, confidence: 1.0)
    }

    let fake = ScriptedTranscriber(
        passes: Array(repeating: passWithWordsFarInTheFuture(), count: 4)
    )
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 80_000))  // 5 seconds
    for _ in 0..<3 { _ = await streamer.runPassIfDue() }

    // More real audio arrives after a confirmation whose hypothesis start
    // time (104s) sits far beyond anything actually recorded.
    await streamer.append([Float](repeating: 0.1, count: 32_000))  // 2 more seconds
    _ = await streamer.runPassIfDue()

    // No audio was discarded: the next pass must still cover everything —
    // not be skipped, and not have had the buffer wiped out from under it,
    // because the seek point sat far beyond the real recording. Its slice
    // is the full 112,000 real samples (80,000 + 32,000) plus padding, from
    // the start.
    #expect(await fake.receivedLengths.last == 112_000 + 16_000)
    #expect(await fake.offsets.last == 0)
}

@Test func runPassIfDueSplitsConfirmedFromHypothesisAndTheyConcatenateToFullText() async throws {
    let fake = ScriptedTranscriber(passes: Array(repeating: pass(script), count: 3))
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))  // 10 seconds

    // Passes 1-2 haven't reached the confirmation threshold yet: everything
    // sits in the hypothesis half, and the confirmed half is empty — proving
    // the split discriminates in both directions, not just when there is
    // something confirmed to show.
    for _ in 0..<2 {
        let update = try #require(await streamer.runPassIfDue())
        #expect(update.confirmedText.isEmpty)
        #expect(update.hypothesisText == script)
        #expect(update.fullText == script)
    }

    // The 3rd pass crosses the confirmation threshold: the finished
    // sentences move into confirmedText, and only the still-revisable
    // remainder stays in hypothesisText — the two halves are disjoint and
    // concatenate back to exactly what `fullText` (the old, pre-split return
    // value) used to be.
    let third = try #require(await streamer.runPassIfDue())
    #expect(third.confirmedText == "one two. three four. five six.")
    #expect(third.hypothesisText == "seven eight")
    #expect(third.fullText == script)
}

@Test func wordslessPassKeepsAlreadyConfirmedTextVisible() async throws {
    // A 4th pass returns text with no word-level timing at all — the model
    // can do this on a pass it isn't confident enough to timestamp. It must
    // not erase what a prior pass already confirmed.
    let fake = ScriptedTranscriber(
        passes: Array(repeating: pass(script), count: 3)
            + [TranscriptionPass(text: "nine ten", words: [], confidence: 1.0)]
    )
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 160_000))  // 10 seconds

    for _ in 0..<2 { _ = await streamer.runPassIfDue() }
    let third = try #require(await streamer.runPassIfDue())
    #expect(third.confirmedText == "one two. three four. five six.")  // sanity: the confirmation landed

    // The pass under test: no words, so nothing for the agreement engine to
    // process, but the confirmed text must still come back rather than "".
    let fourth = try #require(await streamer.runPassIfDue())
    #expect(fourth.confirmedText == "one two. three four. five six.")
    #expect(fourth.hypothesisText == "nine ten")
    #expect(fourth.fullText == "one two. three four. five six. nine ten")
}

@Test func previewKeepsMovingWhenTheUnconfirmedTailGrowsTooLarge() async throws {
    // Past the cap the streamer force-confirms the oldest hypothesis words
    // (no transcribe call that tick), trims their audio, and keeps passing
    // on the shortened tail — the preview never freezes mid-sentence.
    let fake = ScriptedTranscriber(passes: [pass("the complete batch transcript")])
    let streamer = StreamingTranscriber(transcriber: fake)

    await streamer.begin()
    await streamer.append([Float](repeating: 0.1, count: 17 * 16_000))  // 17s, past the 10s cap
    _ = await streamer.runPassIfDue()
    #expect(await fake.receivedLengths.isEmpty)  // the cap tick never transcribes

    // The final transcript is unaffected: finish() transcribes the whole
    // (complete, correct) recording regardless of what the preview did.
    await streamer.append([Float](repeating: 0.1, count: 5 * 16_000))
    let result = try await streamer.finish()
    #expect(result == "the complete batch transcript")
    #expect(await fake.receivedLengths.last == 22 * 16_000 + 16_000)
}
