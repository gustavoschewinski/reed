import CoreAudio
import Foundation

enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case delivering
}

/// The slice of `Recorder` that `DictationSession` needs. A seam so tests
/// drive the state machine without ever opening a real microphone —
/// `Recorder` needs live audio and is verified by hand, not unit-testable.
@MainActor
protocol AudioRecording: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    func start(deviceID: AudioDeviceID?) throws
    @discardableResult
    func stop() -> [Float]
}

extension Recorder: AudioRecording {}

/// The slice of `SystemAudio` that `DictationSession` needs. A seam so tests
/// never touch the real output volume.
@MainActor
protocol VolumeControl: AnyObject {
    func mute()
    func restore()
}

extension SystemAudio: VolumeControl {}

/// Turns a hotkey gesture into text in the focused app: records, streams the
/// transcription live, and delivers the final result.
///
/// This is the integration point for every other piece in `Core`/`System`/
/// `Data` — but it never touches AppKit windows or views. It only publishes
/// `state`, `previewText`, and `level`; `AppDelegate` observes those and
/// shows or hides the overlay. Nothing below `UI/` may know the UI exists.
@MainActor
final class DictationSession: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var previewText: String = ""
    @Published private(set) var level: Float = 0

    private let recorder: any AudioRecording
    private let transcriber: StreamingTranscriber
    private let volumeControl: any VolumeControl
    private let mediaControl: any MediaControl
    private let store: TranscriptStore
    private let settings: Settings
    private let clipboard: any ClipboardStore
    private let canPaste: Bool?
    private let paste: (() -> Void)?
    private let passInterval: Duration

    /// Drives `StreamingTranscriber.runPassIfDue()`. Exactly one pass is ever
    /// in flight: the loop awaits each pass to completion before deciding
    /// whether to sleep, rather than firing on a bare repeating timer.
    private var passLoopTask: Task<Void, Never>?

    /// Samples handed to us by `Recorder.onSamples` since the last time they
    /// were flushed into `transcriber`. `onSamples` is a synchronous,
    /// MainActor-isolated callback, so buffering here — rather than spawning
    /// a `Task` per chunk to call the `StreamingTranscriber` actor — is what
    /// keeps delivery order intact; a fresh `Task` per chunk would race other
    /// chunks' `Task`s for the actor with no FIFO guarantee.
    private var pendingSamples: [Float] = []
    /// How many samples (in order, from the start of the recording) have
    /// already been handed to `transcriber.append`. Lets `completeEnd`
    /// reconcile against `Recorder.stop()`'s authoritative return value:
    /// `onSamples` notifies asynchronously, so the last chunk or two captured
    /// right before `stop()` may not have reached `pendingSamples` yet.
    private var appendedSampleCount = 0

    private var recordingStartedAt: Date?
    /// Snapshot of the settings that were actually acted on at `begin()`, so
    /// `teardown()` reverses exactly what was done even if the user changes
    /// a setting mid-recording.
    private var didMute = false
    private var didPauseMedia = false
    /// Guards `teardown()` so its three actions — stop the recorder, resume
    /// media, restore volume — run exactly once no matter how many exit
    /// paths call it.
    private var teardownRan = true

    init(
        recorder: any AudioRecording,
        transcriber: StreamingTranscriber,
        volumeControl: any VolumeControl,
        mediaControl: any MediaControl,
        store: TranscriptStore,
        settings: Settings,
        clipboard: any ClipboardStore = SystemClipboard(),
        canPaste: Bool? = nil,
        paste: (() -> Void)? = nil,
        passInterval: Duration = .seconds(1)
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.volumeControl = volumeControl
        self.mediaControl = mediaControl
        self.store = store
        self.settings = settings
        self.clipboard = clipboard
        self.canPaste = canPaste
        self.paste = paste
        self.passInterval = passInterval

        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onSamples = { [weak self] samples in
            self?.pendingSamples.append(contentsOf: samples)
        }
    }

    // MARK: - Gestures

    /// `.tap`: begin if idle, end if recording. Ignored while transcribing
    /// or delivering — `begin()`/`end()` are no-ops outside their expected
    /// starting state, so there is nothing to queue and nothing to crash.
    func toggle() {
        switch state {
        case .idle: begin()
        case .recording: end()
        case .transcribing, .delivering: break
        }
    }

    /// `.holdStart` (and `.tap` from idle, via `toggle()`): idle → recording.
    func begin() {
        guard state == .idle else { return }

        pendingSamples = []
        appendedSampleCount = 0
        previewText = ""
        level = 0
        teardownRan = false
        recordingStartedAt = .now

        didMute = settings.muteWhileRecording
        didPauseMedia = settings.pauseMediaWhileRecording
        if didMute { volumeControl.mute() }
        if didPauseMedia { mediaControl.pause() }

        do {
            try recorder.start(deviceID: settings.inputDeviceID)
        } catch {
            NSLog("Reed: failed to start recording: %@", String(describing: error))
            teardown()
            return
        }

        if settings.playSounds { Cues.start() }
        state = .recording

        passLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.transcriber.begin()
            await self.runPassLoop()
        }
    }

    /// Recording → idle immediately. Delivers nothing, stores nothing.
    func cancel() {
        guard state == .recording else { return }
        defer { teardown() }

        passLoopTask?.cancel()
        passLoopTask = nil
        pendingSamples = []
        previewText = ""
        if settings.playSounds { Cues.cancel() }
        state = .idle
    }

    /// `.holdEnd` (and `.tap` from recording, via `toggle()`): recording →
    /// transcribing → delivering → idle. The returned task lets a caller
    /// (namely tests) await the full path deterministically instead of
    /// polling or sleeping; production callers are free to discard it.
    @discardableResult
    func end() -> Task<Void, Never>? {
        guard state == .recording else { return nil }
        state = .transcribing
        return Task { [weak self] in
            await self?.completeEnd()
        }
    }

    // MARK: - Recording lifecycle

    private func completeEnd() async {
        defer { teardown() }

        // Serialize with the pass loop: cancelling it only sets a flag, it
        // does not abort a pass already in flight, so wait for it to
        // actually finish before touching the actor again. Otherwise
        // `transcriber.finish()` could run concurrently with a stale
        // `runPassIfDue()`, corrupting the agreement engine's bookkeeping.
        passLoopTask?.cancel()
        await passLoopTask?.value
        passLoopTask = nil

        // Stops the recorder (among other things) and hands back everything
        // it ever captured — the authoritative complete recording.
        let recorded = teardown()

        if !pendingSamples.isEmpty {
            await transcriber.append(pendingSamples)
            appendedSampleCount += pendingSamples.count
            pendingSamples = []
        }
        // `onSamples` notifies asynchronously; the last chunk or two the mic
        // captured may not have reached `pendingSamples` before `stop()`
        // returned. Without this, the final transcript would silently lose
        // the last words of every recording.
        if recorded.count > appendedSampleCount {
            await transcriber.append(Array(recorded[appendedSampleCount...]))
            appendedSampleCount = recorded.count
        }

        do {
            let text = try await transcriber.finish()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                previewText = ""
                state = .idle
                return
            }

            state = .delivering
            await TextDelivery.deliver(trimmed, clipboard: clipboard, canPaste: canPaste, paste: paste)

            let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            store.add(text: trimmed, duration: duration)

            if settings.playSounds { Cues.stop() }
        } catch {
            NSLog("Reed: transcription failed: %@", String(describing: error))
        }

        previewText = ""
        state = .idle
    }

    /// The single teardown path every exit from `.recording` — normal,
    /// cancelled, or a thrown transcriber error — passes through. Resumes
    /// media, restores volume, and stops the recorder, exactly once: a
    /// second call (from a redundant `defer`, say) is a guarded no-op.
    @discardableResult
    private func teardown() -> [Float] {
        guard !teardownRan else { return [] }
        teardownRan = true

        let recorded = recorder.stop()
        if didPauseMedia { mediaControl.resume() }
        if didMute { volumeControl.restore() }
        return recorded
    }

    // MARK: - Pass loop

    /// Drives `StreamingTranscriber` for the live preview. Never fires on a
    /// bare repeating timer: each iteration awaits the previous pass to
    /// completion, then sleeps only whatever remains of `passInterval` — so
    /// two passes can never be in flight at once, even when a pass runs
    /// longer than the interval.
    private func runPassLoop() async {
        while !Task.isCancelled {
            let iterationStart = ContinuousClock.now

            if !pendingSamples.isEmpty {
                let samples = pendingSamples
                pendingSamples = []
                await transcriber.append(samples)
                appendedSampleCount += samples.count
            }

            if let text = await transcriber.runPassIfDue() {
                previewText = text
            }

            guard !Task.isCancelled else { return }

            let elapsed = ContinuousClock.now - iterationStart
            let remaining = passInterval - elapsed
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
    }
}
