import Foundation

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
    /// The whole recording, never trimmed. The batch fallback needs real audio
    /// for the confirmed region; reconstructing it as silence would transcribe
    /// the opening of the recording as nothing. 64 KB per second, so a
    /// five-minute dictation costs about 19 MB — worth it to never lose words.
    private var wholeRecording: [Float] = []
    /// Samples already discarded from the front, so absolute times stay correct.
    private var trimmedSamples = 0
    private(set) var confirmedSegments = 0

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
        confirmedSegments = 0
        engine.reset()
    }

    func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
        wholeRecording.append(contentsOf: samples)
    }

    /// Runs one agreement pass if enough unprocessed audio has accumulated
    /// ahead of the current seek point.
    /// Returns the text to display, or nil if nothing changed.
    @discardableResult
    func runPassIfDue() async -> String? {
        let total = trimmedSamples + buffer.count
        guard total >= minimumSamples else { return nil }

        let seekTime = engine.hypothesisStartTime > 0
            ? engine.hypothesisStartTime
            : engine.confirmedEndTime
        let seekSample = max(0, Int(seekTime * reedSampleRate))
        let relative = max(0, seekSample - trimmedSamples)
        guard relative < buffer.count else { return nil }

        let slice = Array(buffer[relative...])
        guard slice.count >= minimumSamples else { return nil }

        let offset = Double(trimmedSamples + relative) / reedSampleRate

        // Without trailing silence the model clips the final word and drops its
        // punctuation, which the punctuation rule depends on.
        guard let result = try? await transcriber.transcribe(slice + silencePad, timeOffset: offset)
        else { return nil }

        guard !result.words.isEmpty else {
            return result.text.isEmpty ? nil : result.text
        }

        let agreement = engine.process(words: result.words, passConfidence: result.confidence)
        if !agreement.newlyConfirmedText.isEmpty {
            confirmedSegments += 1
            trimConfirmedAudio()
        }
        return agreement.fullText
    }

    /// Produces the authoritative text. Falls back to a clean batch pass when
    /// agreement never settled — the preview must never degrade the result.
    func finish() async throws -> String {
        guard confirmedSegments >= config.minConfirmedSegmentsToTrustStreaming else {
            // The real recording, not the trimmed buffer. Trimming has usually
            // already run once or twice by the time we land here, and padding
            // that region with silence would transcribe the opening of the
            // recording as nothing at all.
            let result = try await transcriber.transcribe(
                wholeRecording + silencePad, timeOffset: 0)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let seekTime = engine.hypothesisStartTime > 0
            ? engine.hypothesisStartTime
            : engine.confirmedEndTime
        let relative = max(0, Int(seekTime * reedSampleRate) - trimmedSamples)

        var tail = ""
        if relative < buffer.count {
            let slice = Array(buffer[relative...])
            let result = try await transcriber.transcribe(slice + silencePad, timeOffset: seekTime)
            tail = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return [engine.confirmedText, tail]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func trimConfirmedAudio() {
        let cut = max(0, Int(engine.hypothesisStartTime * reedSampleRate))
        let amount = min(cut - trimmedSamples, buffer.count)
        guard amount > 0 else { return }
        buffer.removeFirst(amount)
        trimmedSamples += amount
    }
}
