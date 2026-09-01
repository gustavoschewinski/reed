import AVFoundation
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

/// One of the three short cue sounds `DictationSession` plays. A seam so
/// tests can verify the `playSounds` gate without ever invoking `NSSound`.
enum DictationCue: Sendable, Equatable {
    case start
    case stop
    case cancel
}

/// Turns a hotkey gesture into text in the focused app: records, streams the
/// transcription live, and delivers the final result.
///
/// This is the integration point for every other piece in `Core`/`System`/
/// `Data` — but it never touches AppKit windows or views. It only publishes
/// `state`, `previewText` (and its `confirmedText`/`hypothesisText` split),
/// and `level`; `AppDelegate` observes those and shows or hides the overlay.
/// Nothing below `UI/` may know the UI exists.
@MainActor
final class DictationSession: ObservableObject {
    @Published private(set) var state: DictationState = .idle {
        didSet {
            guard oldValue != state else { return }
            DebugLog.log("DictationSession.state \(oldValue) -> \(state)")
        }
    }
    /// The combined confirmed + hypothesis text, kept for callers that only
    /// need the whole preview. `confirmedText`/`hypothesisText` below are the
    /// same content split, for a renderer that wants to style them
    /// differently — see `OverlayView`.
    @Published private(set) var previewText: String = ""
    /// Settled text the agreement engine will not revise further. Renders at
    /// `Theme.textPrimary`.
    @Published private(set) var confirmedText: String = ""
    /// The current, still-revisable tail. Renders at `Theme.textDim`.
    @Published private(set) var hypothesisText: String = ""
    @Published private(set) var level: Float = 0
    /// What went wrong with the *last* dictation attempt, in plain language
    /// — or nil if it (or the current one) hasn't hit any trouble. Every
    /// failure path Reed has looks the same from the outside: the pill
    /// appears, the waveform idles, nothing gets pasted or stored. This is
    /// what tells the difference apart — a denied microphone, a model that
    /// hasn't finished loading, a transcription that came back empty, or
    /// Accessibility being missing (so the text landed on the clipboard
    /// instead of being typed in). `AppDelegate` renders it in the
    /// overlay's control row; nothing here references AppKit, SwiftUI, or
    /// any `UI/` type — this only ever publishes a `String?`, same as
    /// `previewText` above.
    @Published private(set) var problem: String? {
        didSet {
            guard oldValue != problem else { return }
            DebugLog.log("DictationSession.problem = \(problem.map { "\"\($0)\"" } ?? "nil")")
        }
    }

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
    /// How long to let the start cue sound before muting the output. The
    /// cue is ~0.27s; muting the instant it starts (what this used to do)
    /// silenced it outright, which is why the stop cue was audible and the
    /// start cue never was.
    private let startCueDuration: Duration
    /// The pending delayed mute, so `teardown()` can cancel it when a
    /// recording ends inside that window.
    private var muteTask: Task<Void, Never>?
    private let playCue: (DictationCue) -> Void
    /// Test seam for the microphone-authorization check `begin()` runs
    /// before it ever touches the recorder: nil means "ask the real
    /// system" (`AVCaptureDevice`'s cached authorization status — a read,
    /// not a request, so this never triggers a permission prompt),
    /// matching the `canPaste: Bool?` pattern already used above for
    /// `TextDelivery`.
    private let microphoneAuthorizationOverride: AVAuthorizationStatus?
    /// Test seam for the actual permission *request* `begin()` now makes
    /// when it finds `.notDetermined` — same pattern as the override above,
    /// just for the write side instead of the read side. The real default
    /// calls `AVCaptureDevice.requestAccess`, which is AVFoundation, not
    /// AppKit or SwiftUI, so this keeps `DictationSession` free of any UI
    /// reference exactly as before.
    private let requestMicrophoneAccess: () async -> Bool

    /// Drives `StreamingTranscriber.runPassIfDue()`. Exactly one pass is ever
    /// in flight: the loop awaits each pass to completion before deciding
    /// whether to sleep, rather than firing on a bare repeating timer.
    ///
    /// Also doubles as the handle a fresh `begin()` awaits before it lets a
    /// new pass loop touch the transcriber — see `begin()`.
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

    /// When the current (or last) recording began. `private(set)` so the
    /// overlay's elapsed clock can read the authoritative start time
    /// instead of trying to reconstruct it from state transitions it may
    /// render too late to observe.
    private(set) var recordingStartedAt: Date?
    /// Snapshot of the settings that were actually acted on at `begin()`, so
    /// `teardown()` reverses exactly what was done even if the user changes
    /// a setting mid-recording.
    private var didMute = false
    private var didPauseMedia = false
    /// Guards `teardown()` so its three actions — stop the recorder, resume
    /// media, restore volume — run exactly once no matter how many exit
    /// paths call it.
    private var teardownRan = true
    /// Set by `cancel()` when it lands during `.transcribing`. Checked once,
    /// right before `completeEnd()` would deliver or store — not a new
    /// state, just a discard flag on the result that's already in flight.
    private var discardResult = false

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
        // 0.6s, not 1s: a pass costs roughly 43ms per second of unconfirmed
        // tail, and the tail is capped at 10s, so even the worst pass fits
        // inside this interval with room to spare. The loop awaits each pass
        // before sleeping the remainder, so a slower machine simply runs
        // fewer passes rather than piling them up.
        passInterval: Duration = .milliseconds(600),
        startCueDuration: Duration = .milliseconds(300),
        playCue: @escaping (DictationCue) -> Void = { cue in
            switch cue {
            case .start: Cues.start()
            case .stop: Cues.stop()
            case .cancel: Cues.cancel()
            }
        },
        microphoneAuthorizationOverride: AVAuthorizationStatus? = nil,
        requestMicrophoneAccess: @escaping () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
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
        self.startCueDuration = startCueDuration
        self.playCue = playCue
        self.microphoneAuthorizationOverride = microphoneAuthorizationOverride
        self.requestMicrophoneAccess = requestMicrophoneAccess

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
    ///
    /// Returns a `Task` only on the `.notDetermined` path, where starting
    /// has to wait on an actual system permission prompt — production
    /// callers are free to discard it, same as `end()`'s; tests that need
    /// to observe the outcome of that prompt await it.
    @discardableResult
    func begin() -> Task<Void, Never>? {
        DebugLog.log("DictationSession.begin() entry, state=\(state)")
        guard state == .idle else { return nil }

        // Checked first, before anything else here touches audio: a
        // microphone that isn't authorized can't record, and attempting it
        // anyway is exactly the "try and recover" pattern that let a
        // degenerate, zero-rate input format reach `AVAudioEngine.
        // installTap` and crash the app with an uncatchable SIGTRAP. A user
        // who has never been asked needs a different sentence from one who
        // said no, so the two cases are told apart here rather than
        // collapsed into one generic message.
        switch microphoneAuthorizationStatus() {
        case .authorized:
            startRecording()
            return nil
        case .notDetermined:
            // This is the natural moment to ask — the user just pressed
            // the shortcut, so a system prompt here is unsurprising. Only
            // `.notDetermined` can ever trigger `requestAccess`: macOS
            // itself refuses to prompt again for `.denied`, and asking
            // when already `.authorized` would be pointless.
            return Task { [weak self] in
                guard let self else { return }
                let granted = await self.requestMicrophoneAccess()
                if granted {
                    self.startRecording()
                } else {
                    self.problem = "Reed needs microphone access to dictate. "
                        + "Open Settings to grant it."
                }
            }
        case .denied, .restricted:
            problem = "Reed can't hear you — microphone access is off. "
                + "Open Settings to turn it back on."
            return nil
        @unknown default:
            problem = "Reed can't hear you — microphone access is off. "
                + "Open Settings to turn it back on."
            return nil
        }
    }

    /// The rest of what `begin()` used to do unconditionally, once
    /// authorization is actually in hand — split out so both the
    /// synchronous `.authorized` path and the async, post-request path
    /// (`.notDetermined` → granted) can reach it identically.
    ///
    /// The `.notDetermined` path's own outer guard only runs before the
    /// request is made, not after it resolves — a second `begin()` landing
    /// while the first is still awaiting the system prompt would otherwise
    /// find `state` still `.idle` and race this. Re-checked here so only
    /// the first of two such calls actually starts anything.
    private func startRecording() {
        guard state == .idle else { return }

        pendingSamples = []
        appendedSampleCount = 0
        previewText = ""
        confirmedText = ""
        hypothesisText = ""
        level = 0
        teardownRan = false
        discardResult = false
        problem = nil
        recordingStartedAt = .now

        // Order matters (Item 4): the start cue must play before the mute
        // takes effect, or it is inaudible under `muteWhileRecording`'s
        // default of on — the one moment confirmation matters most. It
        // must also start before capture begins: with muting off, a cue
        // played into a live microphone risks being transcribed as speech,
        // and starting it first (rather than after capture opens) is what
        // keeps as much of it as possible outside the recording window.
        // Media pause must come before the start cue: `MediaKeyControl`
        // decides whether anything is playing by asking whether the output
        // device is running, and the cue itself runs it — sampled after,
        // Reed's own beep read as "music playing", the play/pause toggle
        // fired against silence, and *started* the user's paused music.
        didMute = settings.muteWhileRecording
        didPauseMedia = settings.pauseMediaWhileRecording
        if didPauseMedia { mediaControl.pause() }
        DebugLog.log("DictationSession.begin() after media pause, didPauseMedia=\(didPauseMedia)")

        let playedCue = settings.playSounds
        if playedCue { playCue(.start) }
        DebugLog.log("DictationSession.begin() after cue, played=\(playedCue)")

        // Muting waits out the cue rather than cutting it off — recording
        // starts immediately either way, so the only cost is that other
        // audio stays audible for that fraction of a second.
        muteTask?.cancel()
        muteTask = nil
        if didMute {
            if playedCue {
                muteTask = Task { [weak self] in
                    try? await Task.sleep(for: self?.startCueDuration ?? .zero)
                    guard let self, !Task.isCancelled else { return }
                    // No suspension between this check and the mute, so a
                    // teardown can never interleave and leave the output
                    // silenced with nothing left to restore it.
                    guard !self.teardownRan else { return }
                    self.volumeControl.mute()
                    DebugLog.log("DictationSession delayed mute applied")
                }
            } else {
                volumeControl.mute()
            }
        }
        DebugLog.log("DictationSession.begin() after mute, didMute=\(didMute)")

        do {
            try recorder.start(deviceID: settings.inputDeviceID)
        } catch {
            NSLog("Reed: failed to start recording: %@", String(describing: error))
            // Authorization was already confirmed above, so a throw here
            // is something else — no microphone attached, another app
            // holding the device exclusively, or the input format was
            // rejected by `Recorder`'s own validation — not a permission
            // problem, so the message doesn't claim it's one.
            problem = "Reed couldn't start recording. Check that a microphone is connected and try again."
            teardown()
            return
        }
        DebugLog.log("DictationSession.begin() after recorder.start()")

        // Logged generically by `state`'s own `didSet` below — this is the
        // "at the moment state becomes .recording" checkpoint.
        state = .recording

        // A pass from the just-ended previous recording can still be in
        // flight on `transcriber` (cancelling `passLoopTask` only sets a
        // flag; it doesn't abort a suspended call). Awaiting it here, before
        // ever calling `transcriber.begin()`, guarantees that reset — and
        // everything after it — never races a stale call still touching the
        // actor. `completeEnd()` already awaits its own pass loop before
        // touching the actor further, so the only carry-over case is a
        // recording ended via `cancel()`, which does not await.
        let previousLoop = passLoopTask
        passLoopTask = Task { [weak self] in
            guard let self else { return }
            await previousLoop?.value
            await self.transcriber.begin()
            await self.runPassLoop()
        }
    }

    /// The microphone's current authorization, checked before `begin()`
    /// ever calls `recorder.start()` — a read of the cached status, not a
    /// request, so this never itself triggers a permission prompt.
    private func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        microphoneAuthorizationOverride ?? AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// `.recording` → idle immediately: delivers nothing, stores nothing.
    /// `.transcribing` → still walks to idle once `completeEnd()` finishes,
    /// but discards whatever it produces rather than delivering or storing
    /// it — pressing escape during a slow `finish()` must not paste anyway.
    func cancel() {
        switch state {
        case .recording:
            passLoopTask?.cancel()
            pendingSamples = []
            previewText = ""
            confirmedText = ""
            hypothesisText = ""
            // Cue before teardown (Item 4, same reasoning as `begin()`):
            // played explicitly here, before the call that restores volume
            // and resumes media, rather than via a `defer` whose ordering
            // relative to these statements is easy to misread at a glance.
            if settings.playSounds { playCue(.cancel) }
            state = .idle
            teardown()

        case .transcribing:
            guard !discardResult else { return }
            discardResult = true
            if settings.playSounds { playCue(.cancel) }

        case .idle, .delivering:
            break
        }
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

    /// Called from `AppDelegate.applicationWillTerminate` (Item 1) — the
    /// process is moments from exiting, on a normal Quit. Unlike `cancel()`
    /// or `end()`, this makes no attempt to finish a pass, deliver text, or
    /// play a cue: there is no time left, and none of that is what a
    /// terminating app owes the user. It only runs `teardown()`, whose
    /// `guard !teardownRan` makes this a safe no-op if nothing was ever
    /// started (idle) or it already ran (a normal `end()`/`cancel()` got
    /// there first) — restoring the output volume and resuming media is
    /// the one thing that matters here, since leaving either broken is
    /// silent and outlives the app.
    func prepareForTermination() {
        passLoopTask?.cancel()
        teardown()
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

        let text: String
        do {
            text = try await transcriber.finish()
        } catch {
            NSLog("Reed: transcription failed: %@", String(describing: error))
            // Covers both causes the review calls out together: the model
            // never finished loading (a genuine `prepare()` failure) and
            // "still loading" cases severe enough to throw rather than
            // just run slow — a dictation that succeeds despite a slow
            // load never reaches this branch at all.
            problem = "Reed's speech model wasn't ready — try dictating again in a moment."
            previewText = ""
            confirmedText = ""
            hypothesisText = ""
            state = .idle
            DebugLog.log("DictationSession.completeEnd() textLength=0 delivered=false stored=false (finish() threw)")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A deliberate cancel (Item 3) is not a failure — nothing to
        // explain, so `problem` stays whatever `begin()` last reset it to.
        guard !discardResult else {
            previewText = ""
            confirmedText = ""
            hypothesisText = ""
            state = .idle
            DebugLog.log(
                "DictationSession.completeEnd() textLength=\(trimmed.count) delivered=false stored=false (discarded)")
            return
        }

        guard !trimmed.isEmpty else {
            problem = "Reed didn't catch any words — try speaking a bit louder or closer to the mic."
            previewText = ""
            confirmedText = ""
            hypothesisText = ""
            state = .idle
            DebugLog.log("DictationSession.completeEnd() textLength=0 delivered=false stored=false (empty)")
            return
        }

        state = .delivering
        // Resolved once, here, rather than left for `TextDelivery.deliver`
        // to decide internally — this is the same fallback it would apply
        // on its own (`canPaste ?? accessibilityGranted`), just surfaced so
        // Item 2 can tell whether pasting actually happened.
        let effectiveCanPaste = canPaste ?? TextDelivery.accessibilityGranted
        await TextDelivery.deliver(trimmed, clipboard: clipboard, canPaste: effectiveCanPaste, paste: paste)
        if !effectiveCanPaste {
            problem = "Accessibility isn't granted, so that text was copied instead of typed in. "
                + "Paste it with ⌘V, or open Settings to fix this for next time."
        }

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        store.add(text: trimmed, duration: duration)

        if settings.playSounds { playCue(.stop) }

        // Item 11: the overlay's last visible frame must show exactly what
        // was delivered, not whatever the live preview last happened to
        // hold. On the batch-fallback path — the normal path for short
        // dictations, where streaming never confirmed enough to be
        // trusted — `finish()`'s authoritative text comes from a clean
        // batch pass and can differ from the running hypothesis's last
        // guess, so without this the pill's final frame could show text
        // that was never actually pasted.
        previewText = trimmed
        confirmedText = trimmed
        hypothesisText = ""
        state = .idle
        DebugLog.log(
            "DictationSession.completeEnd() textLength=\(trimmed.count) delivered=\(effectiveCanPaste) stored=true")
    }

    /// The single teardown path every exit from `.recording` — normal,
    /// cancelled, or a thrown transcriber error — passes through. Resumes
    /// media, restores volume, stops the recorder, and resets `level` back
    /// to 0 (nothing else would: `Recorder.stop()` removes the tap, so no
    /// further `onLevel` calls will ever arrive to do it), exactly once: a
    /// second call (from a redundant `defer`, say) is a guarded no-op.
    @discardableResult
    private func teardown() -> [Float] {
        guard !teardownRan else { return [] }
        teardownRan = true
        muteTask?.cancel()
        muteTask = nil

        let recorded = recorder.stop()
        if didPauseMedia { mediaControl.resume() }
        if didMute { volumeControl.restore() }
        level = 0
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

            let update = await transcriber.runPassIfDue()
            // Checked before publishing: `cancel()` clears `previewText`
            // (and the confirmed/hypothesis split) synchronously but does
            // not await this loop, so a pass that was already in flight at
            // that moment must not resurrect stale text into a session that
            // is now idle (or, worse, already recording something new) once
            // it finally resumes.
            guard !Task.isCancelled else { return }
            if let update {
                previewText = update.fullText
                confirmedText = update.confirmedText
                hypothesisText = update.hypothesisText
            }

            let elapsed = ContinuousClock.now - iterationStart
            let remaining = passInterval - elapsed
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
    }
}
