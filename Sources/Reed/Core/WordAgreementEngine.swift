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

/// Thresholds governing when a word stops being a guess in the preview.
///
/// These only shape what the pill shows while you speak: the final
/// transcript comes from one pass over the whole recording
/// (`StreamingTranscriber.finish()`), so a word confirmed too eagerly here
/// costs at most a visible flicker, never a wrong word in the paste. That is
/// why the thresholds lean fast rather than safe.
struct AgreementConfig: Sendable {
    var transcribeInterval: Double = 1.0
    /// Two agreeing passes — the classic LocalAgreement-2. Three (what this
    /// used to be) held every word dim for an extra pass, which read as the
    /// preview being slow to make up its mind.
    var confirmationsNeeded: Int = 2
    /// Minimum agreeing-prefix length before a streak starts counting toward
    /// `confirmationsNeeded`. Does NOT bound how many words a confirmation
    /// contains — a confirmation can be as short as one word.
    var minWordsToConfirm: Int = 2
    /// Passes below this are displayed but excluded from agreement counting.
    var minPassConfidence: Float = 0.15
    /// Every word at the cut boundary must clear this bar.
    var minBoundaryWordConfidence: Float = 0.6
    var boundaryWordCount: Int = 3
    var trailingSilenceSeconds: Double = 1.0
    /// TDT's reported word `startTime` is an estimate carrying emission
    /// delay, not the true acoustic onset — the model can report a word as
    /// starting up to (roughly) this long after the sound of it actually
    /// began. Trimming or seeking to the reported start exactly risks
    /// permanently discarding that leading sliver of real audio, which the
    /// next pass then transcribes as a clipped word — and because
    /// confirmation is permanent, the clip compounds on every confirmation
    /// for the rest of the recording. Subtracted from every cut/seek point
    /// derived from a word's `startTime`, mirroring (at the opposite edge)
    /// the 1.0s `trailingSilenceSeconds` pad already protects against the
    /// same class of timing error.
    var leadingGuardBandSeconds: Double = 0.1
    /// Beyond this much unconfirmed audio, the oldest hypothesis words are
    /// confirmed without agreement so a pass never costs more than the tick
    /// interval. The final transcription is unaffected either way.
    var maxUnconfirmedTailSeconds: Double = 10.0
}

struct AgreementResult: Sendable, Equatable {
    /// Confirmed text plus the current hypothesis — what the overlay renders.
    let fullText: String
    /// Everything confirmed so far, accumulated across every prior pass.
    /// Renders at `Theme.textPrimary`.
    let confirmedText: String
    /// The current, still-revisable tail. Renders at `Theme.textDim`.
    let hypothesisText: String
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
    /// The current unconfirmed tail as text — what `result()` reports as
    /// hypothesis, exposed for callers that need it between passes.
    var hypothesisText: String { previousWords.map(\.text).joined(separator: " ") }

    /// Promotes hypothesis words ending at or before `time` to confirmed
    /// without waiting for agreement. Only for when the unconfirmed tail
    /// has outgrown the re-transcription budget: the preview keeps moving,
    /// and the caller must treat the streaming result as untrusted so the
    /// final transcript never inherits a word confirmed this way.
    func forceConfirm(before time: Double) {
        let moved = Array(previousWords.prefix { $0.endTime <= time })
        guard !moved.isEmpty else { return }
        confirmedWords.append(contentsOf: moved)
        previousWords.removeFirst(moved.count)
        confirmedEndTime = moved.last!.endTime
        hypothesisStartTime = previousWords.first?.startTime ?? confirmedEndTime
        if previousWords.isEmpty {
            consecutiveAgreements = 0
            isFirstPass = true
        }
    }

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

    /// Cut at the most recent sentence ender in the agreed prefix, ignoring
    /// one on the prefix's final word: every pass ends in appended silence,
    /// and the model tends to close whatever word meets that silence with a
    /// period that disappears once more speech arrives.
    ///
    /// This used to cut only at the third-from-last ender, holding the two
    /// most recent sentences open because the model re-punctuates them as
    /// it hears more. That caution guarded the final transcript, which no
    /// longer inherits anything confirmed here — so it only delayed the
    /// preview by two whole sentences.
    private func punctuationCut(_ words: [TimedWord]) -> Int {
        let enders: Set<Character> = [".", "!", "?", ";"]
        let last = words.dropLast().lastIndex { $0.text.last.map(enders.contains) ?? false }
        return last.map { $0 + 1 } ?? 0
    }

    private func result(hypothesis: [TimedWord], newlyConfirmed: [TimedWord]) -> AgreementResult {
        let confirmed = confirmedWords.map(\.text).joined(separator: " ")
        let hypothesisText = hypothesis.map(\.text).joined(separator: " ")
        // Unchanged from before the confirmed/hypothesis split existed —
        // existing tests assert on this exact value.
        let fullText = [confirmed, hypothesisText].filter { !$0.isEmpty }.joined(separator: " ")

        return AgreementResult(
            fullText: fullText,
            confirmedText: confirmed,
            hypothesisText: hypothesisText,
            newlyConfirmedText: newlyConfirmed.map(\.text).joined(separator: " ")
        )
    }
}
