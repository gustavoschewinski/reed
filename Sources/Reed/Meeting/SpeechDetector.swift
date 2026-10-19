import FluidAudio
import Foundation

protocol SpeechDetector: AnyObject, Sendable {
    /// `frame` is exactly `VadManager.chunkSize` samples at 16 kHz.
    func isSpeech(_ frame: [Float]) async throws -> Bool
}

/// Loads Silero once for the whole app; each channel keeps its own stream state.
actor SileroModel {
    static let shared = SileroModel()
    private var loading: Task<VadManager, Error>?

    func manager() async throws -> VadManager {
        if let loading { return try await loading.value }
        let task = Task { try await VadManager() }
        loading = task
        do { return try await task.value } catch { loading = nil; throw error }
    }
}

/// Detects speech using the Silero VAD model.
/// Calls must be serial per instance (actor reentrancy across awaits is not safe for VAD state).
actor SileroSpeechDetector: SpeechDetector {
    private var state: VadStreamState?

    func isSpeech(_ frame: [Float]) async throws -> Bool {
        let vad = try await SileroModel.shared.manager()
        let current: VadStreamState
        if let state { current = state } else { current = await vad.makeStreamState() }
        let result = try await vad.processStreamingChunk(frame, state: current)
        state = result.state
        return result.state.triggered
    }
}
