import Combine
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

    private var tap: SystemAudioTap?
    private var mic: Recorder?
    private var systemChannel: MeetingChannel?
    private var micChannel: MeetingChannel?
    private var finishing: [UUID: Task<Void, Never>] = [:]
    private let tapActivity = TapActivity()

    private var sources = ResolvedSources(output: nil, call: nil)
    private var lastPlaying: Date?
    private var watchdog = SilenceWatchdog()
    private var tapBlocked = false
    private var tapRetryAfter = Date.distantPast
    private var micRetryAfter = Date.distantPast
    private var dictating = false
    private var warmedDetector = false
    private var stopped = false
    /// Bumped on every manual toggle, so a stale "manual off" task never
    /// closes a session started by a later toggle.
    private var manualGeneration = 0
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
        autoModeObservation = settings.$meetingAutoMode
            .dropFirst()
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.clearProblems() }
    }

    /// Begins polling. Idempotent.
    func start() {
        guard poll == nil, !stopped else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
        purge()
        refresh()
    }

    func toggleManual() {
        guard !stopped else { return }
        manualOn.toggle()
        manualGeneration += 1
        if manualOn {
            // Turning it on is also the user's way to retry after a problem.
            clearProblems()
            apply(tracker.finish())
            tracker.mode = .manual
            refresh()
        } else {
            refresh()
            // Close the manual session only once the retired channels have
            // delivered their last lines, so those don't open a new session.
            let pending = Array(finishing.values)
            let generation = manualGeneration
            Task {
                for task in pending { await task.value }
                guard self.manualGeneration == generation, !self.stopped else { return }
                self.apply(self.tracker.finish())
                self.tracker.mode = .auto
            }
        }
    }

    private func clearProblems() {
        problem = nil
        tapBlocked = false
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
        stopSystem()
        stopMic()
        isCapturing = false
        for task in Array(finishing.values) { await task.value }
        apply(tracker.finish())
    }

    private func refresh() {
        guard !stopped else { return }
        let now = Date()
        if manualOn || settings.meetingAutoMode {
            warmDetectorOnce()
            sources = SourceResolver.resolve(
                AudioProcesses.current(), ownPID: getpid(),
                appName: AppInfo.name(bundleID:), windowTitle: AppInfo.focusedWindowTitle(bundleID:))
            if sources.output != nil { lastPlaying = now }
        } else {
            // Nobody asked for meeting mode: skip the Core Audio and
            // Accessibility queries entirely.
            sources = ResolvedSources(output: nil, call: nil)
            lastPlaying = nil
        }

        if tap != nil, watchdog.observe(samplesAreSilent: !tapActivity.take(), someoneIsPlaying: isPlaying(now), now: now) {
            tapBlocked = true
            problem = "Reed can't hear your Mac's audio. Allow it under System Settings → Privacy & Security → Screen & System Audio Recording."
            NSLog("Reed meeting: system audio tap delivered only silence while audio was playing; assuming permission is denied")
        }

        reconcile(now: now)
        apply(tracker.tick(now: now))
    }

    private func isPlaying(_ now: Date) -> Bool {
        lastPlaying.map { now.timeIntervalSince($0) < Self.playingDebounce } ?? false
    }

    /// Brings capture in line with the plan. Synchronous: see the type's doc comment.
    private func reconcile(now: Date) {
        guard !stopped else { return }
        var available = false
        if #available(macOS 14.2, *) { available = !tapBlocked }
        let plan = MeetingPlanner.plan(CaptureInputs(
            manualOn: manualOn, autoEnabled: settings.meetingAutoMode, systemAudioAvailable: available,
            somethingPlaying: isPlaying(now), micInUseElsewhere: sources.micInUseElsewhere, dictating: dictating
        ))
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
            watchdog = SilenceWatchdog()
        } catch {
            NSLog("Reed meeting: system audio tap failed to start: %@", String(describing: error))
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

    private func startMic(now: Date) {
        guard mic == nil, now >= micRetryAfter else { return }
        let channel = makeChannel(.me)
        let recorder = Recorder(keepsRecording: false, voiceProcessing: true)
        recorder.onSamples = { channel.feed($0) }
        do {
            try recorder.start(deviceID: settings.inputDeviceID)
            mic = recorder
            micChannel = channel
        } catch {
            NSLog("Reed meeting: microphone failed to start: %@", String(describing: error))
            problem = "Meeting mode couldn't open the microphone."
            micRetryAfter = now.addingTimeInterval(Self.retryDelay)
            retire(channel)
        }
    }

    private func stopMic() {
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
        finishing[id] = Task {
            await channel.finish()
            self.finishing[id] = nil
        }
    }

    private func makeChannel(_ speaker: Speaker) -> MeetingChannel {
        MeetingChannel(speaker: speaker, detector: SileroSpeechDetector(), transcriber: transcriber) { [weak self] output in
            await MainActor.run { self?.ingest(output) }
        }
    }

    private func ingest(_ output: ChannelOutput) {
        let chunk = MeetingChunk(source: sources.current, start: output.start, end: output.end, lines: [output.line])
        apply(tracker.ingest(chunk))
    }

    private func apply(_ actions: [SessionAction]) {
        guard !actions.isEmpty else { return }
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
