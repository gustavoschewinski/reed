import AVFoundation
import CoreAudio
import Foundation

enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    /// The transcription is done and is being proofread by an LLM before
    /// delivery. Only ever entered by a recording started with the
    /// proofreading shortcut — a plain dictation goes straight from
    /// `.transcribing` to `.delivering`, exactly as it always has.
    case proofreading
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
    private let proofreader: any ProofreadService
    private let clipboard: any ClipboardStore
    private let canPaste: Bool?
    private let paste: (() -> Void)?
    private let passInterval: Duration
    /// How long to let the start cue sound before muting the output. The
    /// cue is ~0.27s; muting the instant it starts (what this used to do)
    /// silenced it outright, which is why the stop cue was audible and the
    /// start cue never was.
    private let startCueDuration: Duration
    /// See the `resultTimeout` initializer parameter.
    private let resultTimeout: Duration
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
    /// Which dictation the session is currently on. Bumped by every
    /// `startRecording()` and by every `abandon()`, and captured by
    /// `completeEnd()` at entry: a run whose number no longer matches has
    /// been abandoned, and must publish nothing, deliver nothing, store
    /// nothing, and change no state.
    ///
    /// This replaces what used to be a single `discardResult` flag. A flag
    /// could say "throw this result away", which was enough while the state
    /// machine could only leave `.transcribing` by finishing; it cannot say
    /// "and by the way a *different* dictation owns `state` and
    /// `previewText` now", which is exactly what became possible once
    /// escape and the stall watchdog were allowed to return to `.idle`
    /// without waiting for the in-flight result.
    private var runID = 0
    /// The in-flight `completeEnd()`, if any. Held so a fresh
    /// `startRecording()` can wait for it before letting a new pass loop
    /// touch the transcriber actor — an abandoned run is still running, and
    /// still holds calls out to that actor.
    private var completionTask: Task<Void, Never>?
    /// The watchdog armed by `end()`, cancelled the moment the run it
    /// belongs to leaves the post-recording states by any other route.
    private var stallTask: Task<Void, Never>?
    /// Whether this recording was started by the proofreading shortcut.
    /// Decided once, at `begin()`, and not re-read afterwards: a recording
    /// started with one shortcut and stopped with the other keeps the
    /// intent it was started with, which is the only reading that doesn't
    /// depend on which key the user happened to release.
    private var proofreadThisRecording = false

    init(
        recorder: any AudioRecording,
        transcriber: StreamingTranscriber,
        volumeControl: any VolumeControl,
        mediaControl: any MediaControl,
        store: TranscriptStore,
        settings: Settings,
        proofreader: any ProofreadService = OpenAIProofreader(),
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
        // How long everything after the recording — transcribe, proofread,
        // deliver — may take before the session gives up and returns to
        // `.idle`. Generous on purpose: the batch pass over the whole
        // recording costs about 10ms per second of audio, so even a long
        // dictation is seconds, but a first call that has to wait out a
        // cold model load can legitimately take tens of them. This is a
        // backstop against a stall that would otherwise never end, not a
        // performance budget — losing one dictation to it is bad, and being
        // unable to dictate at all until Reed is relaunched is worse.
        resultTimeout: Duration = .seconds(45),
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
        self.proofreader = proofreader
        self.clipboard = clipboard
        self.canPaste = canPaste
        self.paste = paste
        self.passInterval = passInterval
        self.startCueDuration = startCueDuration
        self.resultTimeout = resultTimeout
        self.playCue = playCue
        self.microphoneAuthorizationOverride = microphoneAuthorizationOverride
        self.requestMicrophoneAccess = requestMicrophoneAccess

        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onSamples = { [weak self] samples in
            self?.pendingSamples.append(contentsOf: samples)
        }
    }

    // MARK: - Gestures

    /// `.tap`: begin if idle, end if recording. Ignored while transcribing,
    /// proofreading or delivering — `begin()`/`end()` are no-ops outside
    /// their expected starting state, so there is nothing to queue and
    /// nothing to crash.
    ///
    /// `proofread` only ever matters on the `.idle` branch, where a
    /// recording is actually started. Stopping is stopping: a recording
    /// begun with the dictation shortcut and ended with the proofreading
    /// one is still a plain dictation, and vice versa.
    func toggle(proofread: Bool = false) {
        switch state {
        case .idle: begin(proofread: proofread)
        case .recording: end()
        case .transcribing, .proofreading, .delivering: break
        }
    }

    /// `.holdStart` (and `.tap` from idle, via `toggle()`): idle → recording.
    ///
    /// Returns a `Task` only on the `.notDetermined` path, where starting
    /// has to wait on an actual system permission prompt — production
    /// callers are free to discard it, same as `end()`'s; tests that need
    /// to observe the outcome of that prompt await it.
    @discardableResult
    func begin(proofread: Bool = false) -> Task<Void, Never>? {
        DebugLog.log("DictationSession.begin() entry, state=\(state), proofread=\(proofread)")
        guard state == .idle else { return nil }

        // Recorded before the authorization branches below, so the
        // `.notDetermined` path — which reaches `startRecording()` only
        // after awaiting a system prompt — carries the same intent as the
        // synchronous one.
        proofreadThisRecording = proofread

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

        // A new run: anything still in flight from the previous one — an
        // abandoned `completeEnd()`, most of all — now belongs to a number
        // that no longer matches, and can no longer publish into this one.
        runID &+= 1
        stallTask?.cancel()
        stallTask = nil

        pendingSamples = []
        appendedSampleCount = 0
        previewText = ""
        confirmedText = ""
        hypothesisText = ""
        level = 0
        teardownRan = false
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
        // actor.
        //
        // The abandoned `completeEnd()` is awaited for the same reason and
        // is the more dangerous of the two: it calls `append` and `finish`
        // on that same actor, so letting `begin()` reset the transcriber
        // underneath it would interleave two recordings' audio. Its own
        // `runID` guard stops it publishing anything, but only waiting stops
        // it *transcribing* anything. If it is genuinely stuck, this
        // recording's preview waits with it — and this recording's own
        // watchdog is what ends that, rather than nothing at all, which is
        // what used to end it.
        let previousLoop = passLoopTask
        let previousCompletion = completionTask
        passLoopTask = Task { [weak self] in
            guard let self else { return }
            await previousLoop?.value
            await previousCompletion?.value
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
        case .recording, .transcribing, .proofreading:
            // The same thing in both cases, which is the point: escape means
            // "give me my app back", and it used to mean that only while
            // recording. During `.transcribing` it merely marked the result
            // for discard and left the state alone, so the pill stayed up and
            // the shortcut stayed dead until the transcription finished —
            // which, when the transcription was what had gone wrong, could be
            // never. Whatever is in flight is not itself cancellable (an
            // `await` on the transcriber actor, or the proofreading request,
            // runs to completion regardless); abandoning it is.
            abandon(explaining: nil)

        case .idle, .delivering:
            // `.delivering` is the pasting itself, measured in milliseconds
            // and already past the point where discarding would help.
            break
        }
    }

    /// Returns to `.idle` from anywhere, now, without waiting for whatever
    /// is in flight — the single path both escape and the stall watchdog
    /// take.
    ///
    /// Bumping `runID` is what makes this safe: the in-flight
    /// `completeEnd()` keeps running (nothing here can stop it) but its
    /// number no longer matches, so every mutation it would make is skipped
    /// and its result is dropped.
    ///
    /// `explaining` is nil for a deliberate cancel — the user knows why the
    /// pill went away — and carries a sentence when the watchdog fired,
    /// where they do not.
    private func abandon(explaining message: String?) {
        DebugLog.log("DictationSession.abandon() from state=\(state), explained=\(message != nil)")
        runID &+= 1
        stallTask?.cancel()
        stallTask = nil
        passLoopTask?.cancel()
        pendingSamples = []
        previewText = ""
        confirmedText = ""
        hypothesisText = ""

        // Cue before teardown (Item 4, same reasoning as `begin()`): played
        // explicitly here, before the call that restores volume and resumes
        // media, rather than via a `defer` whose ordering relative to these
        // statements is easy to misread at a glance.
        if settings.playSounds { playCue(.cancel) }

        // Before `state`, not after: `teardown()` is what stops the
        // recorder, restores the volume and resumes media, and `AppDelegate`
        // observes `state` synchronously — so by the time anything reacts to
        // `.idle`, the machine is already back the way it was found. Setting
        // `problem` first, for the same reason: `state` and `problem` are
        // observed together, and a nil-then-set `problem` would flash the
        // overlay away and straight back.
        teardown()
        problem = message
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
        armStallWatchdog()

        // Both captured here, synchronously, and handed to `completeEnd()`
        // rather than read inside it. Between this line and that task's first
        // instruction the user can abandon this run and start another one,
        // and each of these would read as the *replacement* recording's:
        //
        // `run` is the whole basis of the gating in `completeEnd()`. Read
        // there, it would be read after any abandonment that happened in the
        // meantime, and so always match — a guard that can never fire.
        //
        // `loop` would by then name the new recording's pass loop, which this
        // run must neither cancel nor wait for. Waiting for it deadlocks
        // outright: that loop's own first act is to wait for this task.
        let run = runID
        let loop = passLoopTask
        let task = Task<Void, Never> { [weak self] in
            await self?.completeEnd(run: run, passLoop: loop)
        }
        completionTask = task
        return task
    }

    /// The backstop for everything after the recording. `completeEnd()` is
    /// a chain of awaits — the pass loop, the transcriber actor, the
    /// proofreading request — and not one of them can be cancelled from
    /// here: cancelling a `Task` sets a flag, it does not abort a call
    /// already suspended inside an actor. So the only way to guarantee the
    /// session comes back is to stop waiting for it.
    ///
    /// Fires against `runID`, not against `state`, so a watchdog left over
    /// from a run that has already finished (or been abandoned) can never
    /// end the one that replaced it.
    private func armStallWatchdog() {
        stallTask?.cancel()
        let run = runID
        let timeout = resultTimeout
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.runID == run else { return }
            switch self.state {
            case .transcribing, .proofreading, .delivering:
                NSLog("Reed: giving up on a dictation that never finished transcribing.")
                self.abandon(
                    explaining: "Reed took too long to finish that one and gave up. "
                        + "The next dictation should work — try again.")
            case .idle, .recording:
                break
            }
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
        stallTask?.cancel()
        stallTask = nil
        teardown()
    }

    // MARK: - Recording lifecycle

    /// `run` is the value `runID` had when `end()` was called — passed in
    /// rather than read here, because this body first executes some time
    /// after that, by which point the run may already have been abandoned
    /// and replaced. Every mutation below is gated on it still being the
    /// current one: escape and the stall watchdog both return the session to
    /// `.idle` without being able to stop this call, so from here on "am I
    /// still the dictation the user is waiting for?" has to be asked at
    /// every suspension point rather than assumed.
    private func completeEnd(run: Int, passLoop: Task<Void, Never>?) async {
        var isCurrent: Bool { runID == run }

        defer {
            // However this run leaves — delivered, empty, thrown — it is no
            // longer at risk of stalling, so the watchdog it armed has
            // nothing left to guard. Skipped entirely by an abandoned run,
            // whose watchdog and teardown belong to whatever replaced it.
            if isCurrent {
                stallTask?.cancel()
                stallTask = nil
                teardown()
            }
        }

        // Serialize with this run's own pass loop: cancelling it only sets a
        // flag, it does not abort a pass already in flight, so wait for it to
        // actually finish before touching the actor again. Otherwise
        // `transcriber.finish()` could run concurrently with a stale
        // `runPassIfDue()`, corrupting the agreement engine's bookkeeping.
        passLoop?.cancel()
        await passLoop?.value

        // The first and widest of the gates. Everything below this line
        // reads or writes state a *replacement* recording may already own:
        // `pendingSamples` is its audio, `teardown()` would stop its
        // recorder. An abandoned run has no business touching any of it, and
        // nothing left to deliver either.
        guard isCurrent else {
            DebugLog.log(
                "DictationSession.completeEnd() run \(run) was abandoned; "
                    + "delivered=false stored=false")
            return
        }
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
            guard isCurrent else { return }
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

        // `finish()` is the longest wait before the network call below, and
        // both escape and the watchdog can land inside it. `abandon()` has
        // already cleared the preview and returned to `.idle` — there is
        // nothing to undo here, only a result to drop.
        guard isCurrent else {
            DebugLog.log(
                "DictationSession.completeEnd() textLength=\(trimmed.count) "
                    + "delivered=false stored=false (abandoned during transcription)")
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

        // The proofreading step (and the only thing that separates the two
        // shortcuts). Everything above this point is identical for both;
        // everything below delivers whatever `outgoing` ends up holding.
        var outgoing = trimmed
        var proofreadProblem: String?

        if proofreadThisRecording {
            state = .proofreading
            // Show the raw transcription while the network call is out.
            // The pill would otherwise sit on the live preview's last
            // guess for a second or so — text that is about to be replaced
            // and was never what got pasted.
            previewText = trimmed
            confirmedText = trimmed
            hypothesisText = ""

            do {
                outgoing = try await proofread(trimmed)
            } catch let error as ProofreadError {
                proofreadProblem = error.deliveryProblem
            } catch {
                proofreadProblem = ProofreadError.unreachable.deliveryProblem
            }
            if let proofreadProblem {
                NSLog("Reed: proofreading failed: %@", proofreadProblem)
            }

            // Escape can land during the call, which is the longest
            // suspension in the whole pipeline — re-checked here rather
            // than trusting the check above, which happened before any of
            // it. The request itself is not cancelled: it is cheap and about
            // to finish either way, and what escape means here is that its
            // answer is thrown away rather than pasted.
            guard isCurrent else {
                DebugLog.log(
                    "DictationSession.completeEnd() textLength=\(trimmed.count) "
                        + "delivered=false stored=false (abandoned during proofreading)")
                return
            }
        }

        state = .delivering
        // Resolved once, here, rather than left for `TextDelivery.deliver`
        // to decide internally — this is the same fallback it would apply
        // on its own (`canPaste ?? accessibilityGranted`), just surfaced so
        // Item 2 can tell whether pasting actually happened.
        let effectiveCanPaste = canPaste ?? TextDelivery.accessibilityGranted
        await TextDelivery.deliver(outgoing, clipboard: clipboard, canPaste: effectiveCanPaste, paste: paste)

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        // What was actually pasted, not what was heard: History is the
        // record of what Reed put into the other app, and a proofread
        // message that can't be found there by the words it contains is
        // not much of a record.
        //
        // Stored before the gate below, and so even by a run the watchdog
        // gave up on while the paste itself was in flight: the text did
        // reach the other app, and History would be lying if it left that
        // out. What an abandoned run must not do is take the screen back.
        store.add(text: outgoing, duration: duration)

        guard isCurrent else {
            DebugLog.log(
                "DictationSession.completeEnd() textLength=\(outgoing.count) "
                    + "delivered=\(effectiveCanPaste) stored=true (abandoned during delivery)")
            return
        }

        // A proofread that failed still delivered something — the raw
        // transcription — so its explanation is set first and then
        // deliberately overwritten by the Accessibility one when both
        // apply. Between "your text wasn't proofread" and "your text isn't
        // in the app at all, press ⌘V", only the second needs an action
        // from the user right now.
        problem = proofreadProblem
        if !effectiveCanPaste {
            problem = "Accessibility isn't granted, so that text was copied instead of typed in. "
                + "Paste it with ⌘V, or open Settings to fix this for next time."
        }

        if settings.playSounds { playCue(.stop) }

        // Item 11: the overlay's last visible frame must show exactly what
        // was delivered, not whatever the live preview last happened to
        // hold. `finish()`'s authoritative text comes from one pass over
        // the whole recording and routinely differs from the preview's
        // last guess, so without this the pill's final frame could show
        // text that was never actually pasted.
        previewText = outgoing
        confirmedText = outgoing
        hypothesisText = ""
        state = .idle
        DebugLog.log(
            "DictationSession.completeEnd() textLength=\(outgoing.count) "
                + "delivered=\(effectiveCanPaste) stored=true "
                + "proofread=\(proofreadThisRecording) proofreadFailed=\(proofreadProblem != nil)")
    }

    /// Builds the request from whatever is in Settings *right now* and
    /// runs it. Nothing is cached: a key pasted or a model changed while
    /// the recording was still running takes effect on this very
    /// dictation.
    ///
    /// The `notConfigured` throw is a backstop, not the main gate —
    /// `AppDelegate` refuses to start a proofreading recording at all
    /// without a key and a model, so that the user finds out before
    /// speaking rather than after. This covers the narrow case of a key
    /// being cleared mid-recording.
    private func proofread(_ text: String) async throws -> String {
        let key = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.proofreadModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty else { throw ProofreadError.notConfigured }

        return try await proofreader.proofread(
            ProofreadRequest(text: text, style: settings.proofreadStyle, model: model, apiKey: key)
        )
    }

    /// Surfaces a problem that happened *before* any dictation could
    /// start, so it reaches the overlay the same way every in-flight
    /// failure already does. `AppDelegate` uses it for a proofreading
    /// shortcut pressed with no OpenAI key saved: the alternative — start
    /// recording, transcribe, then explain at the end — makes the user
    /// speak a whole message to be told the feature was never set up.
    ///
    /// Guarded on `.idle` so it can never overwrite the explanation of a
    /// failure that is actually in flight.
    func reportProblem(_ message: String) {
        guard state == .idle else { return }
        problem = message
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
