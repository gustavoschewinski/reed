import Combine
import CoreAudio
import Foundation
import MeetingLog

/// Whether the system tap has delivered any non-zero sample since the last
/// look. Written from the tap's IOProc queue on every buffer, read by the
/// controller's 2 s poll — a lock, not a main-actor hop per buffer.
private final class TapActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false

    func record(_ samples: [Float]) {
        guard samples.contains(where: { $0 != 0 }) else { return }
        lock.lock()
        heard = true
        lock.unlock()
    }

    /// True if anything non-silent arrived since the previous call.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let result = heard
        heard = false
        return result
    }
}

/// Lets a channel's output closure name the channel it came from; set right
/// after the channel is created. Read and written only on the main actor.
private final class ChannelRef: @unchecked Sendable {
    var id: ObjectIdentifier?
}

/// Meeting mode's integration point: polls what the Mac is doing, asks
/// `MeetingPlanner` what to capture, starts/stops the two channels, and
/// funnels their lines through `SessionTracker` into `MeetingWriter`.
///
/// Concurrency: every start and stop of capture hardware happens
/// synchronously on the main actor inside `reconcile`, so two refreshes can
/// never interleave a start and a stop of the same channel. Only a retired
/// channel's `finish()` (transcribing its last open speech) runs in the
/// background; it is tracked in `finishing` so `shutdown()` can wait for it.
@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var manualOn = false
    @Published private(set) var isCapturing = false
    @Published private(set) var problem: String?

    /// Output must have been reported this recently to count as "playing",
    /// so a pause between two videos doesn't stop and restart the tap.
    private static let playingDebounce: TimeInterval = 10
    /// After a capture fails to start, wait this long before trying again
    /// instead of rebuilding an aggregate device every poll.
    private static let retryDelay: TimeInterval = 60

    private let settings: Settings
    private let transcriber: any Transcriber
    private let writer: MeetingWriter
    private let library: MeetingLibrary
    private var tracker = SessionTracker(mode: .auto)

    private static let silenceProblem =
        "Reed is hearing only silence from your Mac's audio. If that's wrong, allow it under System Settings > Privacy & Security > Screen & System Audio Recording."

    private var tap: SystemAudioTap?
    private var mic: Recorder?
    private var micConfigObserver: NSObjectProtocol?
    private var systemChannel: MeetingChannel?
    private var micChannel: MeetingChannel?
    private var finishing: [UUID: Task<Void, Never>] = [:]
    private let tapActivity = TapActivity()
    /// Default output/input device listeners, installed by `start()`.
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private var sources = ResolvedSources(output: nil, call: nil)
    /// The label a retired channel's last lines get, fixed when it stopped:
    /// by the time they are transcribed `sources` may already be reset.
    private var retiredSources: [ObjectIdentifier: MeetingSource] = [:]
    private var lastPlaying: Date?
    private var lastLoggedPlan: CapturePlan?
    private var lastOutput: MeetingSource?
    private var watchdog = SilenceWatchdog()
    private var tapRetryAfter = Date.distantPast
    private var micRetryAfter = Date.distantPast
    private var dictating = false
    private var warmedDetector = false
    private var started = false
    private var stopped = false
    /// Bumped on every manual toggle, so a stale "manual off" task never
    /// closes a session started by a later toggle.
    private var manualGeneration = 0
    /// Runs only while manual or auto mode is on.
    private var poll: Timer?
    private var purgeTimer: Timer?
    private var autoModeObservation: AnyCancellable?

    init(settings: Settings, transcriber: any Transcriber, directory: URL = MeetingPaths.defaultDirectory) {
        self.settings = settings
        self.transcriber = transcriber
        self.writer = MeetingWriter(directory: directory)
        self.library = MeetingLibrary(directory: directory)
        // Switching auto on is, like turning manual on, the user's way to
        // retry after granting the permission a problem asked for.
        // Delivered on the next main-queue turn: `@Published` emits before
        // the property changes, and `updatePolling()` reads the setting.
        autoModeObservation = settings.$meetingAutoMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated { self?.autoModeChanged(on) }
            }
    }

    /// Starts housekeeping and, if a mode is on, polling. Idempotent.
    func start() {
        guard !started, !stopped else { return }
        started = true
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
        listenForDefaultDeviceChanges()
        purge()
        updatePolling()
        if poll != nil { refresh() }
    }

    func toggleManual() {
        guard started, !stopped else { return }
        manualOn.toggle()
        manualGeneration += 1
        if manualOn {
            // Turning it on is also the user's way to retry after a problem.
            clearProblems()
            apply(tracker.finish())
            tracker.mode = .manual
            updatePolling()
            refresh()
        } else {
            updatePolling()
            refresh()
            // Close the manual session only once the retired channels have
            // delivered their last lines, so those don't open a new session.
            closeSessionAfterRetiredChannels { _ in true }
        }
    }

    private func autoModeChanged(_ on: Bool) {
        guard started, !stopped else { return }
        // Switching auto on is, like turning manual on, the user's way to
        // retry after granting the permission a problem asked for.
        if on { clearProblems() }
        updatePolling()
        refresh()
        // Auto turned off with manual off: nothing will tick the tracker
        // any more, so close its session once the last lines are in.
        if !on, !manualOn {
            closeSessionAfterRetiredChannels { !$0.manualOn && !$0.settings.meetingAutoMode }
        }
    }

    /// Finishes the open session once every channel retired so far has
    /// delivered its last lines, unless a later manual toggle or `stillWanted`
    /// says otherwise. Returns the tracker to auto mode.
    private func closeSessionAfterRetiredChannels(_ stillWanted: @escaping @MainActor (MeetingController) -> Bool) {
        let pending = Array(finishing.values)
        let generation = manualGeneration
        Task {
            for task in pending { await task.value }
            guard self.manualGeneration == generation, !self.stopped, stillWanted(self) else { return }
            self.apply(self.tracker.finish())
            self.tracker.mode = .auto
        }
    }

    /// Polls every 2 s while manual or auto mode is on, and not at all with
    /// both off. Only manages the timer: callers `refresh()` right after,
    /// which also stops capture once both modes are off.
    private func updatePolling() {
        guard started, !stopped else { return }
        if manualOn || settings.meetingAutoMode {
            guard poll == nil else { return }
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else {
            poll?.invalidate()
            poll = nil
        }
    }

    private func clearProblems() {
        problem = nil
        watchdog.dismiss()
        tapRetryAfter = .distantPast
        micRetryAfter = .distantPast
    }

    /// Dictation started or stopped. Re-plans immediately (without
    /// re-reading audio processes or window titles) so the meeting mic is
    /// released before dictation's own recorder needs it.
    func dictationChanged(isDictating: Bool) {
        guard dictating != isDictating else { return }
        dictating = isDictating
        if poll != nil { reconcile(now: Date()) }
    }

    /// Stops capture, waits for the channels' last lines and closes the
    /// open session. Nothing restarts afterwards.
    func shutdown() async {
        stopped = true
        poll?.invalidate()
        poll = nil
        purgeTimer?.invalidate()
        purgeTimer = nil
        removeDefaultDeviceListeners()
        stopSystem()
        stopMic()
        isCapturing = false
        for task in Array(finishing.values) { await task.value }
        apply(tracker.finish())
    }

    private func refresh() {
        guard !stopped else { return }
        let now = Date()
        let wanted = manualOn || settings.meetingAutoMode
        if wanted {
            warmDetectorOnce()
            sources = SourceResolver.resolve(
                AudioProcesses.current(), ownPID: getpid(),
                appName: AppInfo.name(bundleID:), windowTitle: AppInfo.focusedWindowTitle(bundleID:),
                isUserApp: AppInfo.isUserApp(bundleID:))
            if let output = sources.output {
                lastPlaying = now
                lastOutput = output
            } else if isPlaying(now) {
                // The tap outlives the app's output by the debounce window;
                // keep labelling what it hears with the app that played it.
                sources.output = lastOutput
            }
        } else {
            // Nobody asked for meeting mode: skip the Core Audio and
            // Accessibility queries entirely. `sources` is reset only after
            // `reconcile`, so the channels it retires keep their label.
            lastPlaying = nil
        }

        if tap != nil {
            switch watchdog.observe(samplesAreSilent: !tapActivity.take(), someoneIsPlaying: isPlaying(now), now: now) {
            case .show?:
                // Only a hint: the tap keeps running, and the notice clears
                // itself as soon as real audio arrives.
                problem = Self.silenceProblem
                NSLog("Reed meeting: system audio tap delivered only silence while audio was playing; permission may be denied")
            case .clear?:
                if problem == Self.silenceProblem { problem = nil }
            case nil:
                break
            }
        }

        reconcile(now: now)
        if !wanted { sources = ResolvedSources(output: nil, call: nil) }
        apply(tracker.tick(now: now))
    }

    private func isPlaying(_ now: Date) -> Bool {
        lastPlaying.map { now.timeIntervalSince($0) < Self.playingDebounce } ?? false
    }

    /// Brings capture in line with the plan. Synchronous: see the type's doc comment.
    private func reconcile(now: Date) {
        guard !stopped else { return }
        var available = false
        if #available(macOS 14.2, *) { available = true }
        let plan = MeetingPlanner.plan(CaptureInputs(
            manualOn: manualOn, autoEnabled: settings.meetingAutoMode, systemAudioAvailable: available,
            somethingPlaying: isPlaying(now), micInUseElsewhere: sources.micInUseElsewhere, dictating: dictating
        ))
        if plan != lastLoggedPlan {
            DebugLog.log("Meeting plan tap=\(plan.systemTap) mic=\(plan.mic) auto=\(settings.meetingAutoMode) manual=\(manualOn) playing=\(isPlaying(now)) call=\(sources.micInUseElsewhere) source=\(sources.current.app)")
            lastLoggedPlan = plan
        }
        if plan.systemTap { startSystem(now: now) } else { stopSystem() }
        if plan.mic { startMic(now: now) } else { stopMic() }
        isCapturing = tap != nil || mic != nil
    }

    private func startSystem(now: Date) {
        guard tap == nil, now >= tapRetryAfter else { return }
        let channel = makeChannel(.others)
        let activity = tapActivity
        _ = activity.take()
        let newTap = SystemAudioTap()
        newTap.onSamples = { samples in
            channel.feed(samples)
            activity.record(samples)
        }
        do {
            try newTap.start()
            tap = newTap
            systemChannel = channel
            DebugLog.log("Meeting system tap started")
            watchdog.tapStarted()
        } catch {
            NSLog("Reed meeting: system audio tap failed to start: %@", String(describing: error))
            DebugLog.log("Meeting system tap failed: \(error)")
            problem = "Meeting mode couldn't capture your Mac's audio (\(error))."
            tapRetryAfter = now.addingTimeInterval(Self.retryDelay)
            retire(channel)
        }
    }

    private func stopSystem() {
        tap?.stop()
        tap = nil
        if let systemChannel { retire(systemChannel) }
        systemChannel = nil
    }

    /// Hardware changed under a running capture: drop it and let the next
    /// reconcile start it again on the new device. The session goes on.
    private func audioDeviceChanged(system: Bool, mic changedMic: Bool) {
        guard !stopped else { return }
        if system, tap != nil {
            NSLog("Reed meeting: output device changed; rebuilding the system audio tap")
            stopSystem()
        }
        if changedMic, mic != nil {
            NSLog("Reed meeting: input device changed; reopening the microphone")
            stopMic()
        }
        isCapturing = tap != nil || mic != nil
    }

    private func listenForDefaultDeviceChanges() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = CoreAudioProperty.address(selector)
            let isOutput = selector == kAudioHardwarePropertyDefaultOutputDevice
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // An explicitly chosen microphone is unaffected by the default.
                    let micAffected = !isOutput && self.settings.inputDeviceID == nil
                    self.audioDeviceChanged(system: isOutput, mic: micAffected)
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            if status == noErr {
                deviceListeners.append((address, block))
            } else {
                NSLog("Reed meeting: couldn't watch default device changes (%d)", status)
            }
        }
    }

    private func removeDefaultDeviceListeners() {
        for (address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
        deviceListeners = []
    }

    private func startMic(now: Date) {
        guard mic == nil, now >= micRetryAfter else { return }
        let channel = makeChannel(.me)
        // No voice processing: on a real Mac it delivered only zeros while
        // flooding the log with downlink I/O faults (the engine has no output
        // to cancel against). Without it, speakers without headphones can
        // leak the other side into the "Me" channel.
        let recorder = Recorder(keepsRecording: false, voiceProcessing: false)
        recorder.onSamples = { channel.feed($0) }
        do {
            try recorder.start(deviceID: settings.inputDeviceID)
            mic = recorder
            micChannel = channel
            DebugLog.log("Meeting mic started")
            micConfigObserver = recorder.observeConfigurationChange { [weak self] in
                self?.audioDeviceChanged(system: false, mic: true)
            }
        } catch {
            NSLog("Reed meeting: microphone failed to start: %@", String(describing: error))
            DebugLog.log("Meeting mic failed: \(error)")
            problem = "Meeting mode couldn't open the microphone."
            micRetryAfter = now.addingTimeInterval(Self.retryDelay)
            retire(channel)
        }
    }

    private func stopMic() {
        if let micConfigObserver { NotificationCenter.default.removeObserver(micConfigObserver) }
        micConfigObserver = nil
        mic?.stop()
        mic = nil
        if let micChannel { retire(micChannel) }
        micChannel = nil
    }

    /// A channel must be `finish()`ed before release (its drain task retains
    /// it). Runs in the background so stopping capture never waits on
    /// transcription.
    private func retire(_ channel: MeetingChannel) {
        let id = UUID()
        let key = ObjectIdentifier(channel)
        retiredSources[key] = sources.current
        finishing[id] = Task {
            await channel.finish()
            self.finishing[id] = nil
            self.retiredSources[key] = nil
        }
    }

    private func makeChannel(_ speaker: Speaker) -> MeetingChannel {
        // The channel's own identity tells `ingest` whether it was retired.
        let box = ChannelRef()
        let channel = MeetingChannel(speaker: speaker, detector: SileroSpeechDetector(), transcriber: transcriber) { [weak self] output in
            await MainActor.run { self?.ingest(output, from: box.id) }
        }
        box.id = ObjectIdentifier(channel)
        return channel
    }

    private func ingest(_ output: ChannelOutput, from channel: ObjectIdentifier?) {
        let source = channel.flatMap { retiredSources[$0] } ?? sources.current
        let chunk = MeetingChunk(source: source, start: output.start, end: output.end, lines: [output.line])
        DebugLog.log("Meeting ingest speaker=\(output.speaker) source=\(source.app) seconds=\(Int(output.end.timeIntervalSince(output.start)))")
        apply(tracker.ingest(chunk))
    }

    private func apply(_ actions: [SessionAction]) {
        guard !actions.isEmpty else { return }
        DebugLog.log("Meeting apply \(actions.count) action(s), file=\(writer.currentFile?.lastPathComponent ?? "none")")
        do {
            try writer.apply(actions)
        } catch {
            NSLog("Reed meeting: couldn't write transcript: %@", String(describing: error))
            problem = "Couldn't save the meeting transcript: \(error.localizedDescription)"
        }
    }

    /// Silero downloads its small model on first use; fetch it as soon as a
    /// meeting mode is on rather than on the first spoken frame.
    private func warmDetectorOnce() {
        guard !warmedDetector else { return }
        warmedDetector = true
        Task {
            do { _ = try await SileroModel.shared.manager() } catch {
                // Not retried here: each detector loads lazily on its own.
                NSLog("Reed meeting: failed to load the speech detector: %@", String(describing: error))
            }
        }
    }

    private func purge() {
        let days = settings.meetingRetentionDays
        guard days > 0 else { return }
        _ = library.purge(endedBefore: Date().addingTimeInterval(-Double(days) * 86_400))
    }
}
