import Foundation

/// A single word with the time span it occupies in the recording.
struct TimedWord: Sendable, Equatable {
    let text: String
    let normalizedText: String
    let startTime: Double
    let endTime: Double
    let confidence: Float

    init(text: String, startTime: Double, endTime: Double, confidence: Float = 1.0) {
        self.text = text
        self.normalizedText = Self.normalize(text)
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    /// Two passes may punctuate or capitalise the same word differently. Compare
    /// on a stripped form so those differences do not read as disagreement.
    /// Apostrophes are normalized to a single ASCII form and KEPT — not
    /// stripped — because dropping them collides genuinely different words
    /// ("it's" vs "its", "we're" vs "were"), and confirmation is permanent.
    private static func normalize(_ text: String) -> String {
        let apostropheVariants: [Character] = ["\u{2019}", "\u{02BC}"]
        let unifiedApostrophes = String(
            text.lowercased().map { apostropheVariants.contains($0) ? "'" : $0 }
        )
        return String(
            unifiedApostrophes
                .replacingOccurrences(of: "-", with: " ")
                .filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "'" }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thresholds governing when a word stops being a guess. Every value is a
/// starting point to be tuned against real speech, not a proven constant.
struct AgreementConfig: Sendable {
    var transcribeInterval: Double = 1.0
    var confirmationsNeeded: Int = 3
    /// Minimum agreeing-prefix length before a streak starts counting toward
    /// `confirmationsNeeded`. Does NOT bound how many words a confirmation
    /// contains — a confirmation can be as short as one word.
    var minWordsToConfirm: Int = 5
    /// Passes below this are displayed but excluded from agreement counting.
    var minPassConfidence: Float = 0.15
    /// Every word at the cut boundary must clear this bar.
    var minBoundaryWordConfidence: Float = 0.6
    var boundaryWordCount: Int = 3
    var trailingSilenceSeconds: Double = 1.0
    var minConfirmedSegmentsToTrustStreaming: Int = 3
}

struct AgreementResult: Sendable, Equatable {
    /// Confirmed text plus the current hypothesis — what the overlay renders.
    let fullText: String
    /// Only what became final in this pass — empty on most passes.
    let newlyConfirmedText: String
}

/// Decides which words from a sequence of overlapping transcription passes are
/// stable enough to freeze. Pure: no audio, no clock, no I/O.
final class WordAgreementEngine {
    private let config: AgreementConfig

    private var confirmedWords: [TimedWord] = []
    private var previousWords: [TimedWord] = []
    private var consecutiveAgreements = 0
    private var isFirstPass = true

    /// End of the last confirmed word.
    private(set) var confirmedEndTime: Double = 0
    /// Start of the first unconfirmed word — where audio may safely be trimmed.
    private(set) var hypothesisStartTime: Double = 0

    var confirmedText: String { confirmedWords.map(\.text).joined(separator: " ") }

    init(config: AgreementConfig = AgreementConfig()) {
        self.config = config
    }

    func reset() {
        confirmedWords = []
        previousWords = []
        consecutiveAgreements = 0
        isFirstPass = true
        confirmedEndTime = 0
        hypothesisStartTime = 0
    }

    func process(words: [TimedWord], passConfidence: Float = 1.0) -> AgreementResult {
        guard !words.isEmpty else { return result(hypothesis: [], newlyConfirmed: []) }

        if isFirstPass {
            isFirstPass = false
            previousWords = words
            return result(hypothesis: words, newlyConfirmed: [])
        }

        // A pass the model itself is unsure of still deserves to be shown, but
        // agreeing with it would confirm noise.
        if passConfidence < config.minPassConfidence {
            consecutiveAgreements = 0
            previousWords = words
            return result(hypothesis: words, newlyConfirmed: [])
        }

        let prefixLength = commonPrefixLength(words, previousWords)
        previousWords = words

        guard prefixLength >= config.minWordsToConfirm else {
            consecutiveAgreements = 0
            return result(hypothesis: words, newlyConfirmed: [])
        }

        consecutiveAgreements += 1
        guard consecutiveAgreements >= config.confirmationsNeeded else {
            return result(hypothesis: words, newlyConfirmed: [])
        }

        let cut = punctuationCut(Array(words.prefix(prefixLength)))
        guard cut > 0 else { return result(hypothesis: words, newlyConfirmed: []) }

        let boundary = words.prefix(cut).suffix(config.boundaryWordCount)
        let weakest = boundary.map(\.confidence).min() ?? 1.0
        guard weakest >= config.minBoundaryWordConfidence else {
            return result(hypothesis: words, newlyConfirmed: [])
        }

        let newlyConfirmed = Array(words.prefix(cut))
        let hypothesis = Array(words.dropFirst(cut))

        confirmedWords.append(contentsOf: newlyConfirmed)
        confirmedEndTime = newlyConfirmed.last?.endTime ?? confirmedEndTime
        hypothesisStartTime = hypothesis.first?.startTime ?? confirmedEndTime

        // The surviving hypothesis words were seen in this pass, so they already
        // have one observation behind them.
        consecutiveAgreements = hypothesis.isEmpty ? 0 : 1
        previousWords = hypothesis
        isFirstPass = hypothesis.isEmpty

        return result(hypothesis: hypothesis, newlyConfirmed: newlyConfirmed)
    }

    private func commonPrefixLength(_ a: [TimedWord], _ b: [TimedWord]) -> Int {
        var length = 0
        for i in 0..<min(a.count, b.count) {
            guard a[i].normalizedText == b[i].normalizedText else { break }
            length = i + 1
        }
        return length
    }

    /// Cut only at a sentence ender, and only at the third from last: the model
    /// routinely re-punctuates the two most recent sentences as it hears more.
    private func punctuationCut(_ words: [TimedWord]) -> Int {
        let enders: Set<Character> = [".", "!", "?", ";"]
        let endings = words.indices.filter { i in
            words[i].text.last.map(enders.contains) ?? false
        }
        guard endings.count >= 3 else { return 0 }

        return endings[endings.count - 3] + 1
    }

    private func result(hypothesis: [TimedWord], newlyConfirmed: [TimedWord]) -> AgreementResult {
        let parts = [
            confirmedWords.map(\.text).joined(separator: " "),
            hypothesis.map(\.text).joined(separator: " "),
        ].filter { !$0.isEmpty }

        return AgreementResult(
            fullText: parts.joined(separator: " "),
            newlyConfirmedText: newlyConfirmed.map(\.text).joined(separator: " ")
        )
    }
}
