import Combine
import Foundation
import Testing
@testable import Reed

/// Tracks every call `OnboardingModel` makes into its injected dependencies,
/// and lets a test script what those dependencies report back — all on
/// `@MainActor`, same as the model itself, so nothing here needs to touch
/// AVFoundation, the Accessibility API, or FluidAudio/CoreML.
@MainActor
private final class Environment {
    var microphoneStatus: PermissionStatus = .notDetermined
    var accessibilityGranted = false
    var microphoneRequests = 0
    var accessibilityRequests = 0
    var hotkeySuggestions = 0
    var finishes = 0

    /// What the next `prepareModel` call does: emits these progress values
    /// in order, then either succeeds or throws.
    var progressToEmit: [ModelDownloadProgress] = []
    var prepareShouldThrow: (any Error)?
    var prepareCalls = 0

    func makeModel(pollInterval: Duration = .milliseconds(5)) -> OnboardingModel {
        OnboardingModel(
            requestMicrophoneAccess: { [self] in
                microphoneRequests += 1
                microphoneStatus = .granted
            },
            currentMicrophoneStatus: { [self] in microphoneStatus },
            currentAccessibilityGranted: { [self] in accessibilityGranted },
            requestAccessibility: { [self] in accessibilityRequests += 1 },
            prepareModel: { [self] progressHandler in
                prepareCalls += 1
                for progress in progressToEmit {
                    progressHandler(progress)
                }
                if let prepareShouldThrow {
                    throw prepareShouldThrow
                }
            },
            suggestHotkeyDefault: { [self] in hotkeySuggestions += 1 },
            finish: { [self] in finishes += 1 },
            pollInterval: pollInterval
        )
    }
}

private struct TestError: Error, LocalizedError {
    var errorDescription: String? { "network unreachable" }
}

// MARK: - Initial state

@MainActor
@Test func initialStateReflectsWhateverThePermissionsAlreadyAre() {
    let env = Environment()
    env.microphoneStatus = .denied
    env.accessibilityGranted = true

    let model = env.makeModel()

    #expect(model.step == .permissions)
    #expect(model.microphoneStatus == .denied)
    #expect(model.accessibilityGranted == true)
    #expect(model.modelState == .notStarted)
}

// MARK: - Permissions step

@MainActor
@Test func requestingMicrophoneUpdatesStatusOnceTheRequestCompletes() async {
    let env = Environment()
    env.microphoneStatus = .notDetermined
    let model = env.makeModel()

    await model.requestMicrophone().value

    #expect(env.microphoneRequests == 1)
    #expect(model.microphoneStatus == .granted)
}

@MainActor
@Test func openingAccessibilitySettingsCallsThroughWithoutChangingStateItself() {
    let env = Environment()
    let model = env.makeModel()

    model.openAccessibilitySettings()

    #expect(env.accessibilityRequests == 1)
    // Accessibility can't be granted in-app — this call alone must not
    // pretend it was.
    #expect(model.accessibilityGranted == false)
}

@MainActor
@Test func observingPermissionsNoticesAChangeMadeOutsideTheAppWithoutARestart() async throws {
    let env = Environment()
    env.accessibilityGranted = false
    let model = env.makeModel(pollInterval: .milliseconds(5))

    model.beginObservingPermissions()
    #expect(model.accessibilityGranted == false)

    // Simulate the user granting it in System Settings and coming back —
    // nothing in the app calls `refreshPermissions()` directly for this.
    env.accessibilityGranted = true

    // Poll for the change to land rather than sleeping a fixed, possibly
    // flaky duration — under a loaded test run the poll loop's own ticks
    // can be delayed well past `pollInterval` (5ms here) without the
    // production behavior being broken.
    var noticed = false
    for _ in 0..<200 {
        if model.accessibilityGranted {
            noticed = true
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    model.stopObservingPermissions()

    #expect(noticed)
}

@MainActor
@Test func advancingToTheModelStepStopsObservingPermissions() {
    let env = Environment()
    let model = env.makeModel()

    model.beginObservingPermissions()
    #expect(model.pollTask != nil)

    model.advanceToModelStep()

    #expect(model.step == .model)
    #expect(model.pollTask == nil)
}

// MARK: - Model step

/// Guards the ordering guarantee `startModelDownload()`'s doc comment
/// argues for: FluidAudio's progress handler only feeds an `AsyncStream`,
/// consumed by a single loop, specifically so two updates can never be
/// applied out of the order they were actually produced in (which spawning
/// a fresh `Task { @MainActor in … }` per callback would not guarantee).
/// This subscribes to `$modelState` directly and asserts the *sequence* of
/// `.working` values `OnboardingModel` actually published, not just the
/// final state — a version that dropped or reordered every intermediate
/// update would still finish at `.ready` and pass a test that only checked
/// that.
///
/// Verified this discriminates, not just executes: temporarily reversing
/// the emitted array before comparison (and, separately, dropping the
/// stream's middle element before it's consumed) each made this test fail;
/// both were reverted immediately after confirming the failure. Not left in
/// the suite — a permanently-broken assertion isn't a regression guard.
@MainActor
@Test func startingTheModelDownloadAppliesEveryProgressUpdateInOrder() async throws {
    let env = Environment()
    let fromFluidAudio = [
        ModelDownloadProgress(fractionCompleted: 0.1, phase: .listing),
        ModelDownloadProgress(fractionCompleted: 0.4, phase: .downloading(completedFiles: 1, totalFiles: 2)),
        ModelDownloadProgress(fractionCompleted: 0.75, phase: .downloading(completedFiles: 2, totalFiles: 2)),
        ModelDownloadProgress(fractionCompleted: 0.9, phase: .compiling),
    ]
    env.progressToEmit = fromFluidAudio
    let model = env.makeModel()

    var observed: [ModelDownloadProgress] = []
    let subscription = model.$modelState.sink { state in
        if case .working(let progress) = state {
            observed.append(progress)
        }
    }

    model.startModelDownload()
    await model.downloadTask?.value
    subscription.cancel()

    #expect(env.prepareCalls == 1)
    // `startModelDownload()` itself publishes one synthetic placeholder
    // (0%, `.listing`) synchronously, before `prepareModel` — the fake
    // standing in for FluidAudio — reports anything at all; every update
    // after that must be exactly what `fromFluidAudio` produced, none
    // dropped, none duplicated, in the order it was produced in.
    let placeholder = ModelDownloadProgress(fractionCompleted: 0, phase: .listing)
    #expect(observed == [placeholder] + fromFluidAudio)
    // fractionCompleted must never regress, matching `ProgressReporter`'s
    // own documented monotonic invariant on the FluidAudio side.
    let fractions = observed.map(\.fractionCompleted)
    #expect(fractions == fractions.sorted())
    #expect(model.modelState == .ready)
}

@MainActor
@Test func aFailedDownloadSurfacesTheErrorAndCanBeRetried() async throws {
    let env = Environment()
    env.prepareShouldThrow = TestError()
    let model = env.makeModel()

    model.startModelDownload()
    await model.downloadTask?.value

    guard case .failed(let message) = model.modelState else {
        Issue.record("expected .failed, got \(model.modelState)")
        return
    }
    #expect(message == "network unreachable")

    // Retrying re-runs prepareModel rather than being stuck on the old
    // failure.
    env.prepareShouldThrow = nil
    model.startModelDownload()
    await model.downloadTask?.value

    #expect(env.prepareCalls == 2)
    #expect(model.modelState == .ready)
}

@MainActor
@Test func startingTheDownloadTwiceWhileOneIsAlreadyInFlightDoesNotStartASecondOne() async throws {
    let env = Environment()
    // A slow first call: nothing has thrown or emitted anything yet when
    // the second `startModelDownload()` arrives below.
    let model = env.makeModel()

    model.startModelDownload()
    model.startModelDownload()
    await model.downloadTask?.value

    #expect(env.prepareCalls == 1)
}

@MainActor
@Test func theHotkeyStepIsUnreachableUntilTheModelIsReady() {
    let env = Environment()
    let model = env.makeModel()
    model.advanceToModelStep()

    // Nothing has downloaded yet.
    model.advanceToHotkeyStep()
    #expect(model.step == .model)
    #expect(env.hotkeySuggestions == 0)
}

@MainActor
@Test func theHotkeyStepIsReachableOnceTheModelIsReadyAndSuggestsADefault() async throws {
    let env = Environment()
    let model = env.makeModel()

    model.startModelDownload()
    await model.downloadTask?.value
    #expect(model.modelState == .ready)

    model.advanceToHotkeyStep()

    #expect(model.step == .hotkey)
    #expect(env.hotkeySuggestions == 1)
}

// MARK: - Completion

@MainActor
@Test func completingOnboardingCallsFinishExactlyOnce() {
    let env = Environment()
    let model = env.makeModel()

    model.completeOnboarding()

    #expect(env.finishes == 1)
}
