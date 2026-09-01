import Foundation

/// Where a permission stands. Mirrors `AVCaptureDevice`'s own authorization
/// status — not a literal use of it, for the same reason `ModelDownloadProgress`
/// mirrors FluidAudio's `DownloadProgress` in `Transcriber.swift`: this file,
/// and `OnboardingModelTests.swift`, never need to import AVFoundation.
enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// Where the one-time model download/compile stands.
enum ModelStepState: Equatable, Sendable {
    case notStarted
    case working(ModelDownloadProgress)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

enum OnboardingStep: Int, CaseIterable, Sendable {
    case permissions
    case model
    case hotkey
}

/// Drives Reed's three first-run screens (Task 14): live permission state,
/// the one-time model download/compile, and the hotkey step that ends
/// onboarding. Extracted out of `OnboardingView` — the same reasoning as
/// `PendingDeletionController` in Task 13 — so the step gating and the
/// model-readiness state machine can be unit tested without ever touching
/// AVFoundation, the Accessibility API, or FluidAudio/CoreML: every system
/// call is injected as a closure, and nothing in `OnboardingModelTests.swift`
/// links any of those frameworks.
///
/// Recording must be impossible until the model is ready (see the brief).
/// The model step is screen 2 of 3, before the hotkey is even chosen, so by
/// the time `completeOnboarding()` can run at all `modelState` is already
/// `.ready` — the screen order itself is the gate. `AppDelegate` separately
/// treats `Settings.hasCompletedOnboarding == false` as "not ready yet" for
/// any hotkey press that reaches it before onboarding finishes at all (a
/// shortcut left over from a previous run, say) — see its doc comment there.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .permissions
    @Published private(set) var microphoneStatus: PermissionStatus
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var modelState: ModelStepState = .notStarted

    private let requestMicrophoneAccess: () async -> Void
    private let currentMicrophoneStatus: () -> PermissionStatus
    private let currentAccessibilityGranted: () -> Bool
    private let requestAccessibility: () -> Void
    private let prepareModel: (@escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> Void
    private let suggestHotkeyDefault: () -> Void
    private let finish: () -> Void
    private let pollInterval: Duration

    /// Not `private` purely as a test seam — production never reads it,
    /// tests `await` it to know a scheduled poll tick actually ran instead
    /// of racing a real sleep. Same pattern as `PendingDeletionController
    /// .pendingCommitTask`.
    private(set) var pollTask: Task<Void, Never>?
    private(set) var downloadTask: Task<Void, Never>?

    init(
        requestMicrophoneAccess: @escaping () async -> Void,
        currentMicrophoneStatus: @escaping () -> PermissionStatus,
        currentAccessibilityGranted: @escaping () -> Bool,
        requestAccessibility: @escaping () -> Void,
        prepareModel: @escaping (@escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> Void,
        suggestHotkeyDefault: @escaping () -> Void,
        finish: @escaping () -> Void,
        pollInterval: Duration = .milliseconds(750)
    ) {
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.currentMicrophoneStatus = currentMicrophoneStatus
        self.currentAccessibilityGranted = currentAccessibilityGranted
        self.requestAccessibility = requestAccessibility
        self.prepareModel = prepareModel
        self.suggestHotkeyDefault = suggestHotkeyDefault
        self.finish = finish
        self.pollInterval = pollInterval
        self.microphoneStatus = currentMicrophoneStatus()
        self.accessibilityGranted = currentAccessibilityGranted()
    }

    deinit {
        pollTask?.cancel()
        downloadTask?.cancel()
    }

    // MARK: - Permissions step

    /// Triggers the system microphone prompt (a no-op if already decided —
    /// `AVCaptureDevice.requestAccess` doesn't re-prompt once denied) and
    /// then re-reads the live status, so `microphoneStatus` reflects
    /// whatever the user actually chose rather than assuming the request
    /// succeeded. Returns the task so tests can await the full round trip
    /// deterministically instead of polling or sleeping — the same pattern
    /// as `DictationSession.end()`.
    @discardableResult
    func requestMicrophone() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.requestMicrophoneAccess()
            self.refreshPermissions()
        }
    }

    /// Accessibility can't be granted in-app — this only opens the system
    /// prompt (which itself deep-links to System Settings). Detecting that
    /// the user actually flipped it happens separately, via polling.
    func openAccessibilitySettings() {
        requestAccessibility()
    }

    /// Starts polling both permissions' live state. Accessibility
    /// specifically cannot be granted without leaving the app, so this — not
    /// a one-shot check on appear — is what notices the user coming back
    /// from System Settings without requiring a restart.
    func beginObservingPermissions() {
        refreshPermissions()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                guard !Task.isCancelled else { return }
                self.refreshPermissions()
            }
        }
    }

    func stopObservingPermissions() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshPermissions() {
        microphoneStatus = currentMicrophoneStatus()
        accessibilityGranted = currentAccessibilityGranted()
    }

    func advanceToModelStep() {
        stopObservingPermissions()
        step = .model
    }

    // MARK: - Model step

    /// Kicks off the model download/compile (via the injected `prepareModel`
    /// — `ParakeetTranscriber.prepare(progressHandler:)` in production)
    /// exactly once. A repeat call while already working, or already ready,
    /// is a no-op rather than a second concurrent download; a repeat call
    /// after a failure retries from scratch.
    ///
    /// `prepareModel`'s progress handler is FluidAudio's own — `@Sendable`,
    /// called from an unspecified (background) queue, so it cannot touch
    /// `self.modelState` directly. It only feeds an `AsyncStream`; a
    /// separate loop below — running in this method's own, MainActor-
    /// inherited task — is what actually applies each update, in the order
    /// they were produced. Spawning a fresh `Task { @MainActor in … }` per
    /// callback instead would not have that ordering guarantee: two tasks
    /// created back to back from a background thread can still run on the
    /// main actor in either order.
    func startModelDownload() {
        guard !modelState.isReady, !modelState.isWorking else { return }
        modelState = .working(ModelDownloadProgress(fractionCompleted: 0, phase: .listing))

        downloadTask = Task { [weak self] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<ModelDownloadProgress>.makeStream()
            let observer = Task { [weak self] in
                for await progress in stream {
                    self?.modelState = .working(progress)
                }
            }

            do {
                try await self.prepareModel { progress in continuation.yield(progress) }
                continuation.finish()
                await observer.value
                guard !Task.isCancelled else { return }
                self.modelState = .ready
            } catch {
                continuation.finish()
                await observer.value
                guard !Task.isCancelled else { return }
                self.modelState = .failed(error.localizedDescription)
            }
        }
    }

    /// Only reachable once the model is actually ready — the gate the brief
    /// calls for lives here, not as a separately-checked flag: there is no
    /// path from `.permissions` to `.hotkey` that skips this guard.
    func advanceToHotkeyStep() {
        guard modelState.isReady else { return }
        suggestHotkeyDefault()
        step = .hotkey
    }

    // MARK: - Hotkey step

    func completeOnboarding() {
        finish()
    }
}
