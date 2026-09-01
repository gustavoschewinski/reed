import FluidAudio
import Foundation

/// One token with its time span — mirrors FluidAudio's timing type so the
/// merger can be tested without constructing library types.
struct TokenSpan: Sendable {
    let token: String
    let startTime: Double
    let endTime: Double
    let confidence: Float
}

enum TokenMerger {
    /// The model emits SentencePiece subword tokens; a leading "▁" opens a new
    /// word and everything else continues the current one.
    static func merge(_ tokens: [TokenSpan], timeOffset: Double) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var confidences: [Float] = []

        func flush() {
            guard !text.isEmpty else { return }
            let mean = confidences.isEmpty
                ? Float(1) : confidences.reduce(0, +) / Float(confidences.count)
            words.append(
                TimedWord(
                    text: text,
                    startTime: start + timeOffset,
                    endTime: end + timeOffset,
                    confidence: mean
                ))
        }

        for token in tokens {
            if token.token.hasPrefix("▁") || token.token.hasPrefix(" ") {
                flush()
                text = token.token.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "▁", with: "")
                start = token.startTime
                end = token.endTime
                confidences = [token.confidence]
            } else {
                if text.isEmpty { start = token.startTime }
                text += token.token
                end = token.endTime
                confidences.append(token.confidence)
            }
        }
        flush()
        return words
    }
}

struct TranscriptionPass: Sendable {
    let text: String
    let words: [TimedWord]
    let confidence: Float

    static let empty = TranscriptionPass(text: "", words: [], confidence: 0)
}

protocol Transcriber: Sendable {
    /// Downloads and loads the model. Safe to call more than once.
    func prepare() async throws
    /// `timeOffset` is where `samples` begins within the whole recording, so
    /// returned word timings are absolute.
    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass
}

/// Parakeet TDT v3 running on the Neural Engine.
actor ParakeetTranscriber: Transcriber {
    private var manager: AsrManager?
    private var decoderLayers = 0

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.decoderLayers = await manager.decoderLayerCount
        self.manager = manager
    }

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        try await prepare()
        guard let manager else { return .empty }
        guard !samples.isEmpty else { return .empty }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)

        let spans = (result.tokenTimings ?? []).map {
            TokenSpan(
                token: $0.token, startTime: $0.startTime,
                endTime: $0.endTime, confidence: $0.confidence
            )
        }

        return TranscriptionPass(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: TokenMerger.merge(spans, timeOffset: timeOffset),
            confidence: result.confidence
        )
    }
}
