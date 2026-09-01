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

/// Mirrors FluidAudio's `DownloadProgress`/`DownloadPhase` — same reasoning
/// as `TokenSpan` above: `OnboardingModel` (Task 14) and its tests report and
/// assert on this instead of the library's own type, so they never need to
/// import FluidAudio or link CoreML.
///
/// `fractionCompleted` is real, monotonic progress across the whole prepare
/// operation — download and Neural Engine compile combined — straight from
/// FluidAudio; nothing here is synthesized or interpolated.
struct ModelDownloadProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case listing
        case downloading(completedFiles: Int, totalFiles: Int)
        case compiling
    }

    let fractionCompleted: Double
    let phase: Phase

    init(fractionCompleted: Double, phase: Phase) {
        self.fractionCompleted = fractionCompleted
        self.phase = phase
    }

    init(_ progress: DownloadProgress) {
        fractionCompleted = progress.fractionCompleted
        switch progress.phase {
        case .listing:
            phase = .listing
        case .downloading(let completedFiles, let totalFiles):
            phase = .downloading(completedFiles: completedFiles, totalFiles: totalFiles)
        case .compiling:
            phase = .compiling
        }
    }
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
    /// The in-flight model load, if one is running. Concurrent callers await
    /// this same task instead of each starting their own download-and-compile —
    /// actors are reentrant at suspension points, so without this, two calls
    /// to `prepare()` arriving before the first completes would both see
    /// `manager == nil` and duplicate the ~17s download-and-load.
    private var loadTask: Task<Void, Error>?

    /// Downloads and loads the model. Safe to call repeatedly AND
    /// concurrently: the model is loaded exactly once even if multiple
    /// callers race this before the first load finishes — later callers
    /// await the same in-flight load rather than starting a new one. If the
    /// load fails, `loadTask` is cleared so the next call retries from
    /// scratch instead of being stuck re-awaiting an already-failed task.
    func prepare() async throws {
        try await prepare(progressHandler: nil)
    }

    /// Same as `prepare()`, but reports progress for onboarding's model
    /// screen (`OnboardingModel`, Task 14). `progressHandler` is FluidAudio's
    /// own — called on an unspecified queue, not this actor and not the main
    /// actor — so a caller that touches UI state must hop back itself;
    /// `OnboardingModel` does exactly that.
    ///
    /// If a load is already in flight when this is called (a concurrent
    /// `prepare()` from an actual transcription, say), this caller just
    /// awaits that same task and gets none of its own progress callbacks —
    /// the download isn't happening twice, so there's nothing new to report.
    func prepare(progressHandler: (@Sendable (ModelDownloadProgress) -> Void)?) async throws {
        guard manager == nil else { return }

        if let loadTask {
            try await loadTask.value
            return
        }

        // Created from this actor-isolated method, this unstructured task
        // inherits the actor's isolation, so mutating `self.manager` /
        // `self.decoderLayers` inside it is actor-isolated, not a race.
        let task = Task<Void, Error> {
            let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                progressHandler?(ModelDownloadProgress(progress))
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.decoderLayers = await manager.decoderLayerCount
            self.manager = manager
        }
        // Assigned synchronously, before the first suspension point below —
        // so any caller that runs on this actor after this line (which can
        // only happen once we actually suspend at `await task.value`) is
        // guaranteed to see this task rather than starting its own.
        loadTask = task

        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
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
