import Foundation

/// What one streaming pass has to show, split into the settled prefix and the
/// still-revisable tail so the overlay can render them distinctly — confirmed
/// at `Theme.textPrimary`, hypothesis at `Theme.textDim`.
struct PreviewUpdate: Sendable, Equatable {
    let confirmedText: String
    let hypothesisText: String

    /// The same combined string `AgreementResult.fullText` produced before
    /// the split existed — space-joined, empty halves dropped. What
    /// `DictationSession.previewText` publishes.
    var fullText: String {
        [confirmedText, hypothesisText].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Turns a batch speech model into a live one: repeated bounded passes over the
/// unconfirmed tail, committing only what consecutive passes agree on.
actor StreamingTranscriber {
    private let transcriber: any Transcriber
    private let config: AgreementConfig
    private let engine: WordAgreementEngine

    /// Unconfirmed audio only. Confirmed audio is dropped, which keeps the cost
    /// of a pass bounded — roughly 43 ms per second of tail on an M3, so this is
    /// a timing requirement, not merely a memory one.
    private var buffer: [Float] = []
    /// The whole recording, never trimmed: `finish()` transcribes all of it
    /// in one pass. 64 KB per second, so a five-minute dictation costs about
    /// 19 MB — worth it to never lose words.
    private var wholeRecording: [Float] = []
    /// Samples already discarded from the front, so absolute times stay correct.
    private var trimmedSamples = 0
    /// So the tail-cap warning below logs once per recording, not once per tick.
    private var loggedTailCapped = false

    /// Parakeet rejects very short inputs; below this a pass is skipped.
    private var minimumSamples: Int { Int(0.3 * reedSampleRate) }
    private var silencePad: [Float] {
        [Float](repeating: 0, count: Int(config.trailingSilenceSeconds * reedSampleRate))
    }

    init(transcriber: any Transcriber, config: AgreementConfig = AgreementConfig()) {
        self.transcriber = transcriber
        self.config = config
        self.engine = WordAgreementEngine(config: config)
    }

    func begin() {
        buffer = []
        wholeRecording = []
        trimmedSamples = 0
        loggedTailCapped = false
        engine.reset()
    }

    func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
        wholeRecording.append(contentsOf: samples)
    }

    /// Runs one agreement pass if enough unprocessed audio has accumulated
    /// ahead of the current seek point.
    /// Returns the confirmed/hypothesis split to display, or nil if nothing
    /// changed — nil-vs-value semantics carried over unchanged from when
    /// this returned a plain `String?`.
    @discardableResult
    func runPassIfDue() async -> PreviewUpdate? {
        let total = trimmedSamples + buffer.count
        guard total >= minimumSamples else { return nil }

        let relative = seekRelative(total: total, context: "runPassIfDue")
        guard relative < buffer.count else { return nil }

        // Every pass appends trailing silence before transcribing, and the
        // model can place a hallucinated word's timing inside that pad —
        // which would make the tail look larger than it really is. Cap
        // against the real, un-padded tail so a single bad timestamp can't
        // turn a normal-cost pass into one that blows past the tick interval.
        let tailSamples = buffer.count - relative
        let maxTailSamples = Int(config.maxUnconfirmedTailSeconds * reedSampleRate)
        if tailSamples > maxTailSamples {
            // Long uninterrupted speech can outgrow the re-transcription
            // budget before agreement ever settles. Suspending the preview
            // here (what this used to do) froze the pill mid-sentence for
            // the rest of the recording; instead, promote the oldest
            // hypothesis words to confirmed without waiting for agreement
            // and trim their audio. Only the preview is affected — the
            // final transcript never inherits a streamed word.
            let cutTime = Double(trimmedSamples + buffer.count) / reedSampleRate
                - config.maxUnconfirmedTailSeconds / 2
            engine.forceConfirm(before: cutTime)
            trimConfirmedAudio()
            if !loggedTailCapped {
                loggedTailCapped = true
                NSLog(
                    "Reed: unconfirmed tail exceeded %.0fs; force-confirming preview text.",
                    config.maxUnconfirmedTailSeconds)
            }
            return PreviewUpdate(
                confirmedText: engine.confirmedText, hypothesisText: engine.hypothesisText)
        }

        let slice = Array(buffer[relative...])
        guard slice.count >= minimumSamples else { return nil }

        let offset = Double(trimmedSamples + relative) / reedSampleRate

        // Without trailing silence the model clips the final word and drops its
        // punctuation, which the punctuation rule depends on.
        guard let result = try? await transcriber.transcribe(slice + silencePad, timeOffset: offset)
        else { return nil }
        DebugLog.log(
            "StreamingTranscriber.runPassIfDue() ran, samplesIn=\(slice.count) textLengthOut=\(result.text.count)")

        guard !result.words.isEmpty else {
            // No word-level timing at all this pass, so there is nothing to
            // run through the agreement engine — but whatever the engine
            // already confirmed on an earlier pass must stay visible.
            // Returning "" here would make already-locked-in text vanish
            // from the pill (not dim — gone) until the next pass that does
            // carry timings brings it back; only this pass's raw text is
            // actually uncertain.
            guard !result.text.isEmpty else { return nil }
            return PreviewUpdate(confirmedText: engine.confirmedText, hypothesisText: result.text)
        }

        let agreement = engine.process(words: result.words, passConfidence: result.confidence)
        if !agreement.newlyConfirmedText.isEmpty {
            trimConfirmedAudio()
        }
        return PreviewUpdate(confirmedText: agreement.confirmedText, hypothesisText: agreement.hypothesisText)
    }

    /// Produces the authoritative text: one pass over the whole recording.
    ///
    /// The streamed preview is never stitched into the result. Each preview
    /// pass sees at most `maxUnconfirmedTailSeconds` of audio, so it decides
    /// words, punctuation and capitalization with a fraction of the context
    /// the batch pass has, and every window seam is a place to duplicate or
    /// drop a word. Reusing the streamed prefix used to save the batch pass
    /// — but Parakeet transcribes at roughly 10 ms per second of audio on
    /// the Neural Engine (a minute of dictation in about 0.7 s), so the pass
    /// costs less than the tail-only pass it replaces would have felt like,
    /// and the preview can be as optimistic as it likes without ever
    /// degrading what gets pasted.
    func finish() async throws -> String {
        let result = try await transcriber.transcribe(wholeRecording + silencePad, timeOffset: 0)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where, within `buffer`, the next pass (or the finishing tail pass)
    /// should start reading from.
    ///
    /// The engine's seek time (`hypothesisStartTime`, falling back to
    /// `confirmedEndTime`) is normally trustworthy, but every pass appends
    /// trailing silence before transcribing, and the model can place a word's
    /// timing inside that pad — reporting a seek time beyond any audio we
    /// actually recorded. Trusting that value would compute a `relative`
    /// past the end of `buffer`, silently skipping (or, in `trimConfirmedAudio`,
    /// permanently discarding) real, never-transcribed audio. When the seek
    /// time exceeds `total` — the real audio actually appended — the seek is
    /// untrustworthy, so this falls back to 0: treat everything still in
    /// `buffer` as unconfirmed, rather than skip any of it.
    private func seekRelative(total: Int, context: String) -> Int {
        let seekTime = engine.hypothesisStartTime > 0
            ? engine.hypothesisStartTime
            : engine.confirmedEndTime
        // Subtracting the guard band here and in `trimConfirmedAudio` from
        // the exact same source value (never one from `hypothesisStartTime`
        // and the other from something else) is what keeps the two in sync
        // — otherwise a pass would seek to read from one point while the
        // buffer had already been trimmed to a different one, and word
        // timings would stop matching the audio.
        let seekSample = max(0, Int(seekTime * reedSampleRate) - leadingGuardBandSamples)

        guard seekSample > total else {
            return max(0, seekSample - trimmedSamples)
        }

        NSLog(
            "Reed: %@ saw a seek time of %.2fs beyond the %.2fs of audio actually recorded; "
                + "treating the whole buffer as unconfirmed instead of skipping it.",
            context, seekTime, Double(total) / reedSampleRate)
        return 0
    }

    /// Samples equivalent to `AgreementConfig.leadingGuardBandSeconds` — see
    /// its doc comment. Computed from `config` rather than stored, so a
    /// custom `config` (as tests pass) is always honored.
    private var leadingGuardBandSamples: Int {
        Int(config.leadingGuardBandSeconds * reedSampleRate)
    }

    private func trimConfirmedAudio() {
        let totalAudio = trimmedSamples + buffer.count
        // See `seekRelative`'s comment: the guard band must be subtracted
        // from the same `hypothesisStartTime` value it seeks from, or the
        // two desync.
        let cut = max(0, Int(engine.hypothesisStartTime * reedSampleRate) - leadingGuardBandSamples)

        // See seekRelative's comment: a hallucinated word inside the trailing
        // silence pad can report a time beyond real audio. Trimming to it
        // would discard the entire buffer as "processed" even though it was
        // never transcribed — so when that happens, skip the trim entirely
        // rather than clamp it, which would produce the same data loss.
        guard cut <= totalAudio else {
            NSLog(
                "Reed: hypothesisStartTime (%.2fs) exceeds the %.2fs of audio actually recorded; "
                    + "skipping this trim to avoid discarding untranscribed audio.",
                engine.hypothesisStartTime, Double(totalAudio) / reedSampleRate)
            return
        }

        let amount = min(cut - trimmedSamples, buffer.count)
        guard amount > 0 else { return }
        buffer.removeFirst(amount)
        trimmedSamples += amount
    }
}
