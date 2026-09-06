import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Reed

// MARK: - Fakes

/// One event any of the fakes below can log into a shared `EventLog` (Item
/// 4) — the ordering between, say, a cue and a mute is invisible to any one
/// fake's own counters, since each only knows about itself.
private enum RecordedEvent: Equatable {
    case cue(DictationCue)
    case mute
    case restore
    case pause
    case resume
}

/// Shared by `FakeCuePlayer`, `FakeVolumeControl`, and `FakeMediaControl`
/// so a test can assert their combined, relative order — not just each
/// one's own count. `NSLock`-protected: `FakeMediaControl` isn't
/// `@MainActor`, so a record could in principle arrive from off the main
/// actor even though, in practice, `DictationSession` only ever calls these
/// fakes from itself (`@MainActor`).
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RecordedEvent] = []
    var events: [RecordedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
    func record(_ event: RecordedEvent) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }
}

private final class FakeMediaControl: MediaControl, @unchecked Sendable {
    var pauses = 0
    var resumes = 0
    private let log: EventLog?
    init(log: EventLog? = nil) { self.log = log }
    func pause() { pauses += 1; log?.record(.pause) }
    func resume() { resumes += 1; log?.record(.resume) }
}

@MainActor
private final class FakeVolumeControl: VolumeControl {
    var mutes = 0
    var restores = 0
    private let log: EventLog?
    init(log: EventLog? = nil) { self.log = log }
    func mute() { mutes += 1; log?.record(.mute) }
    func restore() { restores += 1; log?.record(.restore) }
}

@MainActor
private final class FakeRecorder: AudioRecording {
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?

    var startCount = 0
    var stopCount = 0
    var startError: Error?
    /// What `stop()` hands back — the "authoritative complete recording"
    /// `DictationSession` reconciles its buffered samples against.
    var samplesOnStop: [Float] = []

    func start(deviceID: AudioDeviceID?) throws {
        startCount += 1
        if let startError { throw startError }
    }

    @discardableResult
    func stop() -> [Float] {
        stopCount += 1
        return samplesOnStop
    }
}

private final class FakeClipboard: ClipboardStore, @unchecked Sendable {
    var string: String?
    func snapshot() -> [NSPasteboardItem] { [] }
    func restore(_ items: [NSPasteboardItem]) {}
}

@MainActor
private final class FakeCuePlayer {
    var played: [DictationCue] = []
    private let log: EventLog?
    init(log: EventLog? = nil) { self.log = log }
    func play(_ cue: DictationCue) { played.append(cue); log?.record(.cue(cue)) }
}

/// Returns scripted passes in order — the pattern from
/// `StreamingTranscriberTests.swift`. Content doesn't need to be realistic:
/// `finish()`'s fallback path calls `transcribe` regardless of how much
/// audio was actually appended, so these tests never need to feed real
/// samples through `Recorder.onSamples` to get a deterministic result.
private actor ScriptedTranscriber: Transcriber {
    private var passes: [TranscriptionPass]
    private(set) var callCount = 0

    init(passes: [TranscriptionPass]) { self.passes = passes }

    func prepare() async throws {}

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        callCount += 1
        return passes.isEmpty ? .empty : passes.removeFirst()
    }
}

private func pass(_ text: String) -> TranscriptionPass {
    TranscriptionPass(text: text, words: [], confidence: 1.0)
}

private struct BoomError: Error {}

private actor ThrowingTranscriber: Transcriber {
    func prepare() async throws {}
    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        throw BoomError()
    }
}

/// Verifies no two `transcribe` calls ever overlap in time — the load-bearing
/// property of the driving loop. Sleeps a fraction of the test's short
/// `passInterval` so an implementation that fires on a bare repeating timer
/// (rather than awaiting each pass before scheduling the next) would let two
/// calls run concurrently and this would catch it.
private actor OverlapDetectingTranscriber: Transcriber {
    private(set) var callCount = 0
    private(set) var maxConcurrent = 0
    private var current = 0

    func prepare() async throws {}

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        callCount += 1
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        try? await Task.sleep(for: .milliseconds(15))
        current -= 1
        return TranscriptionPass(text: "hypothesis word", words: [], confidence: 1.0)
    }
}

/// A delay that keeps a `transcribe` call genuinely in flight regardless of
/// whether the *caller's* Task gets cancelled mid-wait. A bare `try? await
/// Task.sleep(...)` is itself cancellation-aware and is invoked as part of
/// the calling Task's chain — so once that Task is cancelled (as
/// `cancel()` cancels the pass loop), the sleep throws almost immediately
/// and `try?` swallows it, resolving this call far sooner than `duration`
/// and collapsing the very race window these tests need to hold open. A
/// freshly spawned `Task` has its own, independent cancellation state, so
/// awaiting its `.value` genuinely waits out the full duration.
private func uncancellableDelay(_ duration: Duration) async {
    let sleeper = Task { try? await Task.sleep(for: duration) }
    await sleeper.value
}

/// Delays before returning, so a caller can assert something about the
/// world while this call is still in flight — even across a `cancel()` of
/// whichever Task issued it.
private actor DelayedTranscriber: Transcriber {
    private let delay: Duration
    private let text: String

    init(delay: Duration, text: String = "stale preview text") {
        self.delay = delay
        self.text = text
    }

    func prepare() async throws {}

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        await uncancellableDelay(delay)
        return TranscriptionPass(text: text, words: [], confidence: 1.0)
    }
}

/// Records the order in which calls *finish* (not the order they start),
/// with the first call held open by `firstCallDelay` — immune to the
/// issuing Task's cancellation, see `uncancellableDelay` — so a caller can
/// arrange for a second call to be issued while it's still in flight, and
/// confirm whether the second call was actually issued before the first
/// completed.
private actor OrderingTranscriber: Transcriber {
    private(set) var completionOrder: [Int] = []
    private var callIndex = 0
    private let firstCallDelay: Duration

    init(firstCallDelay: Duration) { self.firstCallDelay = firstCallDelay }

    func prepare() async throws {}

    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        callIndex += 1
        let myIndex = callIndex
        if myIndex == 1 {
            await uncancellableDelay(firstCallDelay)
        }
        completionOrder.append(myIndex)
        return TranscriptionPass(text: "pass \(myIndex)", words: [], confidence: 1.0)
    }
}

// MARK: - Ephemeral UserDefaults

// MARK: - Helper

/// Stands in for OpenAI. Records what it was asked and answers with
/// whatever the test scripted — a corrected string, or a failure.
private final class FakeProofreader: ProofreadService, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ProofreadRequest] = []
    var requests: [ProofreadRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    private let result: Result<String, ProofreadError>
    /// Held open long enough for a test to press escape while the call is
    /// still out — the one suspension in the pipeline a user can act
    /// during.
    private let delay: Duration

    init(result: Result<String, ProofreadError>, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    private func record(_ request: ProofreadRequest) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
    }

    func proofread(_ request: ProofreadRequest) async throws -> String {
        record(request)
        if delay != .zero { try? await Task.sleep(for: delay) }
        return try result.get()
    }
}

@MainActor
private func makeSession(
    media: MediaControl = FakeMediaControl(),
    volume: FakeVolumeControl = FakeVolumeControl(),
    recorder: FakeRecorder = FakeRecorder(),
    store: TranscriptStore? = nil,
    settings: Settings? = nil,
    passes: [TranscriptionPass] = [],
    transcriber: (any Transcriber)? = nil,
    clipboard: FakeClipboard = FakeClipboard(),
    proofreader: (any ProofreadService)? = nil,
    canPaste: Bool = true,
    paste: (() -> Void)? = nil,
    passInterval: Duration = .milliseconds(5),
    // Muting waits out the start cue in production. Tests default to no
    // wait; the ones that need the mute to *not* land pass a long value.
    startCueDuration: Duration = .zero,
    // Far longer than any test's own transcription, so the stall watchdog
    // stays out of the way of every test that isn't about it. The ones that
    // are pass a few milliseconds.
    resultTimeout: Duration = .seconds(120),
    cuePlayer: FakeCuePlayer? = nil,
    // Defaults to `.authorized` (not nil/"ask the real system") so every
    // test in this file that doesn't care about authorization gets a
    // session that behaves as if the mic were already granted — `swift
    // test` must never depend on (or be blocked by) the real, ambient
    // authorization state of whatever machine runs it.
    microphoneAuthorizationOverride: AVAuthorizationStatus? = .authorized,
    // Only ever consulted on the `.notDetermined` path; a test that
    // exercises it passes its own closure. `swift test` must never trigger
    // a real permission prompt, so there is no "ask the real system"
    // default here the way there is for the override above — every test
    // that reaches this closure supplies one explicitly.
    requestMicrophoneAccess: @escaping () async -> Bool = { true }
) throws -> DictationSession {
    let store = try store ?? TranscriptStore(inMemory: true)
    // Media pause ships off by default (macOS gives no reliable
    // "is anything playing" signal), but it is still a supported setting,
    // so the tests that exercise that path opt in here.
    let settings = settings ?? {
        let s = Settings(defaults: FakeUserDefaults())
        s.pauseMediaWhileRecording = true
        return s
    }()
    let backing = transcriber ?? ScriptedTranscriber(passes: passes)
    let streaming = StreamingTranscriber(transcriber: backing)
    let cuePlayer = cuePlayer ?? FakeCuePlayer()

    return DictationSession(
        recorder: recorder,
        transcriber: streaming,
        volumeControl: volume,
        mediaControl: media,
        store: store,
        settings: settings,
        // Never the real `OpenAIProofreader`: `swift test` must not be
        // able to make a network call, and a session whose proofreader is
        // never reached (every test but the proofreading ones) is better
        // served by one that would fail loudly than by one that would
        // quietly try to phone OpenAI.
        proofreader: proofreader ?? FakeProofreader(result: .failure(ProofreadError.unreachable)),
        clipboard: clipboard,
        canPaste: canPaste,
        paste: paste ?? {},
        passInterval: passInterval,
        startCueDuration: startCueDuration,
        resultTimeout: resultTimeout,
        playCue: cuePlayer.play,
        microphoneAuthorizationOverride: microphoneAuthorizationOverride,
        requestMicrophoneAccess: requestMicrophoneAccess
    )
}

/// Polls until `condition` holds, for work that now completes on a later
/// tick — the delayed mute. Returns false on timeout so the caller's
/// `#expect` reports a real failure rather than hanging the suite.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - begin

@MainActor
@Test func beginMovesToRecordingAndPausesMedia() async throws {
    let media = FakeMediaControl()
    let session = try makeSession(media: media)

    session.begin()

    #expect(session.state == .recording)
    #expect(media.pauses == 1)
}

@MainActor
@Test func beginMutesOutputAndStartsTheRecorder() async throws {
    let volume = FakeVolumeControl()
    let recorder = FakeRecorder()
    let session = try makeSession(volume: volume, recorder: recorder)

    session.begin()

    #expect(recorder.startCount == 1)
    // The mute lands a tick later: it waits out the start cue so the cue
    // is not silenced by the very mute it precedes.
    #expect(await waitUntil { volume.mutes == 1 })
}

@MainActor
@Test func beginTwiceInARowIsIgnored() async throws {
    let media = FakeMediaControl()
    let session = try makeSession(media: media)

    session.begin()
    session.begin()

    #expect(session.state == .recording)
    #expect(media.pauses == 1)  // not paused twice
}

@MainActor
@Test func settingsGateMutingAndMediaPause() async throws {
    let defaults = FakeUserDefaults()
    let settings = Settings(defaults: defaults)
    settings.muteWhileRecording = false
    settings.pauseMediaWhileRecording = false

    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume, settings: settings)

    session.begin()

    #expect(media.pauses == 0)
    #expect(volume.mutes == 0)

    session.cancel()

    // A user who turned these off must not have them touched on the way
    // back out either.
    #expect(media.resumes == 0)
    #expect(volume.restores == 0)
}

// MARK: - cancel

@MainActor
@Test func cancelStoresNothingAndRestoresEverything() async throws {
    let media = FakeMediaControl()
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(media: media, store: store)

    session.begin()
    session.cancel()

    #expect(session.state == .idle)
    #expect(media.resumes == 1)
    #expect(store.all().isEmpty)
}

@MainActor
@Test func cancelDeliversNothingToTheClipboard() async throws {
    let clipboard = FakeClipboard()
    clipboard.string = "untouched"
    let session = try makeSession(
        passes: [pass("this must never be delivered")], clipboard: clipboard)

    session.begin()
    session.cancel()

    #expect(clipboard.string == "untouched")
}

@MainActor
@Test func cancelWhileIdleIsANoOp() async throws {
    let media = FakeMediaControl()
    let session = try makeSession(media: media)

    session.cancel()

    #expect(session.state == .idle)
    #expect(media.resumes == 0)
}

// MARK: - end (the full path)

@MainActor
@Test func endWalksRecordingToTranscribingToIdleAndStoresOneTranscript() async throws {
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(store: store, passes: [pass("hello world")])

    session.begin()
    #expect(session.state == .recording)

    let task = session.end()
    // Synchronous up to this point: end() has not yet had a chance to run
    // its async continuation, since nothing has been awaited yet.
    #expect(session.state == .transcribing)

    await task?.value

    #expect(session.state == .idle)
    #expect(store.all().count == 1)
    #expect(store.all().first?.text == "hello world")
}

/// `paste()` (injected via `canPaste: true`) runs synchronously inside
/// `TextDelivery.deliver`, exactly while `completeEnd` has `state ==
/// .delivering` — the one point at which that intermediate state is
/// observable from outside. Proves the walk is recording → transcribing →
/// delivering → idle, not a shortcut straight from transcribing to idle.
@MainActor
final class StateBox {
    weak var session: DictationSession?
}

@MainActor
@Test func endReachesDeliveringBeforeIdle() async throws {
    let box = StateBox()
    var observedStateAtPaste: DictationState?
    let session = try makeSession(
        passes: [pass("deliver me")],
        paste: { observedStateAtPaste = box.session?.state }
    )
    box.session = session

    session.begin()
    await session.end()?.value

    #expect(observedStateAtPaste == .delivering)
    #expect(session.state == .idle)
}

@MainActor
@Test func endResumesMediaAndRestoresVolume() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume, passes: [pass("hi")])

    session.begin()
    await session.end()?.value

    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
}

@MainActor
@Test func endStopsTheRecorderExactlyOnce() async throws {
    let recorder = FakeRecorder()
    let session = try makeSession(recorder: recorder, passes: [pass("hi")])

    session.begin()
    await session.end()?.value

    #expect(recorder.stopCount == 1)
}

/// The recorder's last chunk can be captured on the audio thread but not yet
/// delivered through `onSamples` (an async dispatch) when the session calls
/// `stop()`. `Recorder.stop()`'s return value is authoritative, so the
/// session must reconcile against it rather than trust `onSamples` alone —
/// otherwise the final transcript silently loses the recording's last words.
@MainActor
@Test func endRecoversSamplesNeverDeliveredThroughOnSamples() async throws {
    let recorder = FakeRecorder()
    // Nothing is ever pushed through recorder.onSamples — simulating every
    // chunk still being in flight when stop() is called — but stop() itself
    // reports 20,000 real samples were captured.
    recorder.samplesOnStop = [Float](repeating: 0.1, count: 20_000)

    let transcriber = ScriptedTranscriber(passes: [pass("recovered")])
    let session = try makeSession(recorder: recorder, transcriber: transcriber)

    session.begin()
    await session.end()?.value

    // The fallback pass must have been asked to transcribe real, non-empty
    // audio — not an empty buffer, which is what a broken implementation
    // that only trusted onSamples would send.
    #expect(await transcriber.callCount == 1)
}

// MARK: - whitespace-only result

@MainActor
@Test func whitespaceOnlyResultStoresNothingAndDeliversNothing() async throws {
    let store = try TranscriptStore(inMemory: true)
    let clipboard = FakeClipboard()
    clipboard.string = "untouched"
    let session = try makeSession(store: store, passes: [pass("   ")], clipboard: clipboard)

    session.begin()
    await session.end()?.value

    #expect(session.state == .idle)
    #expect(store.all().isEmpty)
    #expect(clipboard.string == "untouched")
}

// MARK: - throwing transcriber

@MainActor
@Test func throwingTranscriberStillReturnsToIdleWithEverythingRestored() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let recorder = FakeRecorder()
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(
        media: media, volume: volume, recorder: recorder, store: store,
        transcriber: ThrowingTranscriber()
    )

    session.begin()
    await session.end()?.value

    #expect(session.state == .idle)
    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
    #expect(recorder.stopCount == 1)
    #expect(store.all().isEmpty)
}

// MARK: - teardown runs exactly once

@MainActor
@Test func teardownRunsExactlyOnceOnCancel() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume)

    session.begin()
    session.cancel()
    session.cancel()  // already idle — must not double-resume

    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
}

@MainActor
@Test func teardownRunsExactlyOnceOnEnd() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let recorder = FakeRecorder()
    let session = try makeSession(
        media: media, volume: volume, recorder: recorder, passes: [pass("hi")])

    session.begin()
    await session.end()?.value

    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
    #expect(recorder.stopCount == 1)
}

@MainActor
@Test func teardownRunsExactlyOnceEvenWhenTranscriberThrows() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume, transcriber: ThrowingTranscriber())

    session.begin()
    await session.end()?.value

    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
}

// MARK: - prepareForTermination (Item 1)

@MainActor
@Test func prepareForTerminationRestoresVolumeAndResumesMediaWhileRecording() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume)

    session.begin()
    session.prepareForTermination()

    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
}

@MainActor
@Test func prepareForTerminationIsANoOpWhenIdle() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume)

    session.prepareForTermination()

    #expect(media.resumes == 0)
    #expect(volume.restores == 0)
}

@MainActor
@Test func prepareForTerminationAfterANormalEndDoesNotDoubleRestore() async throws {
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let session = try makeSession(media: media, volume: volume, passes: [pass("done")])

    session.begin()
    await session.end()?.value
    session.prepareForTermination()

    #expect(media.resumes == 1)
    #expect(volume.restores == 1)
}

// MARK: - toggle

@MainActor
@Test func toggleFromIdleBegins() async throws {
    let session = try makeSession()
    session.toggle()
    #expect(session.state == .recording)
}

@MainActor
@Test func toggleFromRecordingEnds() async throws {
    let session = try makeSession(passes: [pass("toggled off")])
    session.toggle()
    #expect(session.state == .recording)
    session.toggle()
    #expect(session.state == .transcribing)
}

@MainActor
@Test func tapWhileTranscribingIsIgnored() async throws {
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(store: store, passes: [pass("finish me")])

    session.begin()
    let task = session.end()
    #expect(session.state == .transcribing)

    // A tap landing mid-transcription must not begin a new recording, must
    // not re-trigger end(), and must not crash.
    session.toggle()
    #expect(session.state == .transcribing)

    await task?.value

    #expect(session.state == .idle)
    #expect(store.all().count == 1)
}

// MARK: - pass serialization

/// Proves the core invariant of the driving loop: `runPassIfDue` (via
/// `Transcriber.transcribe`) is never called again before the previous call
/// has returned. A bare `Timer`-style implementation that fires every
/// `passInterval` regardless of whether the prior pass finished would let
/// `maxConcurrent` exceed 1 here, since each fake pass sleeps 15ms against a
/// 5ms interval.
@MainActor
@Test func passesNeverOverlap() async throws {
    let recorder = FakeRecorder()
    let detector = OverlapDetectingTranscriber()
    let session = try makeSession(recorder: recorder, transcriber: detector, passInterval: .milliseconds(5))

    session.begin()
    // Feed enough audio to clear StreamingTranscriber's minimum-sample floor
    // so runPassIfDue actually calls transcribe on every iteration.
    recorder.onSamples?([Float](repeating: 0.1, count: 20_000))

    try await Task.sleep(for: .milliseconds(200))
    session.cancel()

    let calls = await detector.callCount
    let maxConcurrent = await detector.maxConcurrent
    #expect(calls > 1)  // the loop actually ran multiple passes in this window
    #expect(maxConcurrent == 1)
}

@MainActor
@Test func previewTextUpdatesWhileRecording() async throws {
    let recorder = FakeRecorder()
    let transcriber = ScriptedTranscriber(passes: [pass("live preview text")])
    let session = try makeSession(recorder: recorder, transcriber: transcriber, passInterval: .milliseconds(5))

    session.begin()
    recorder.onSamples?([Float](repeating: 0.1, count: 20_000))

    // Waits for the pass to actually land rather than sleeping a fixed
    // 100ms and hoping it did. The whole suite runs in parallel, and under
    // that load a first pass could miss a fixed window — this test failed
    // roughly half the time before, for timing reasons and never for the
    // behaviour it is about.
    #expect(await waitUntil { session.previewText == "live preview text" })

    // Checked before cancel() — which, correctly, clears previewText as
    // part of its own cleanup.
    #expect(session.previewText == "live preview text")

    session.cancel()
    #expect(session.previewText.isEmpty)
}

// MARK: - level resets on every exit (Finding 1)

@MainActor
@Test func levelResetsToZeroAfterCancel() async throws {
    let recorder = FakeRecorder()
    let session = try makeSession(recorder: recorder)

    session.begin()
    recorder.onLevel?(0.75)
    #expect(session.level == 0.75)

    session.cancel()
    #expect(session.level == 0)
}

@MainActor
@Test func levelResetsToZeroAfterEnd() async throws {
    let recorder = FakeRecorder()
    let session = try makeSession(recorder: recorder, passes: [pass("hi")])

    session.begin()
    recorder.onLevel?(0.5)
    #expect(session.level == 0.5)

    await session.end()?.value
    #expect(session.level == 0)
}

// MARK: - a stale pass cannot repopulate previewText after cancel (Finding 2)

/// Starts a pass that is still in flight when `cancel()` runs, then lets it
/// actually complete, and confirms it never wrote its (now stale) result
/// into `previewText`. Fails against a `runPassLoop` that checks
/// `Task.isCancelled` only at the top of the loop (i.e. after the write),
/// since the pass here is already inside `transcribe` — past that check —
/// when `cancel()` runs.
@MainActor
@Test func cancelDoesNotLetAStalePassRepopulatePreviewText() async throws {
    let recorder = FakeRecorder()
    let transcriber = DelayedTranscriber(delay: .milliseconds(60))
    let session = try makeSession(recorder: recorder, transcriber: transcriber, passInterval: .milliseconds(5))

    session.begin()
    recorder.onSamples?([Float](repeating: 0.1, count: 20_000))

    // The loop's first pass should have started almost immediately and now
    // be asleep inside the 60ms delay.
    try await Task.sleep(for: .milliseconds(20))
    session.cancel()
    #expect(session.previewText.isEmpty)

    // Let the in-flight pass actually finish.
    try await Task.sleep(for: .milliseconds(100))
    #expect(session.previewText.isEmpty)
}

// MARK: - cancel-then-begin cannot let a stale pass touch the fresh recording (Finding 3)

/// `OrderingTranscriber`'s first call sleeps long enough to still be running
/// when `cancel()` fires and a new `begin()` follows immediately. Without
/// `begin()` awaiting the previous pass loop before calling
/// `transcriber.begin()`, the second recording's loop would issue its own
/// call while the first is still asleep — actor reentrancy lets the second,
/// non-sleeping call finish first, recording completion order `[2, 1]`. With
/// the fix, the second call can't even be issued until the first has fully
/// finished, so the order must be `[1, 2]`.
@MainActor
@Test func cancelThenImmediateBeginDoesNotLetAStalePassRace() async throws {
    let recorder = FakeRecorder()
    let transcriber = OrderingTranscriber(firstCallDelay: .milliseconds(80))
    let session = try makeSession(recorder: recorder, transcriber: transcriber, passInterval: .milliseconds(5))

    session.begin()
    recorder.onSamples?([Float](repeating: 0.1, count: 20_000))
    // Give the loop a moment to actually issue its first call and enter the
    // artificial delay, then cancel and immediately start a new recording.
    try await Task.sleep(for: .milliseconds(15))
    session.cancel()
    session.begin()
    recorder.onSamples?([Float](repeating: 0.1, count: 20_000))

    // Long enough for both calls to have completed either way.
    try await Task.sleep(for: .milliseconds(200))
    session.cancel()

    // Only the relative order of the first two calls is load-bearing here —
    // recording 2's loop keeps running for the rest of the 200ms window and
    // racks up further calls (3, 4, ...), which is expected and irrelevant.
    let order = await transcriber.completionOrder
    #expect(order.count >= 2)
    #expect(Array(order.prefix(2)) == [1, 2])
}

// MARK: - Cues get a seam, gated by playSounds (Finding 4)

@MainActor
@Test func playSoundsTrueFiresTheCuesOnBeginCancelAndEnd() async throws {
    let player = FakeCuePlayer()
    let session = try makeSession(passes: [pass("hi")], cuePlayer: player)

    session.begin()
    #expect(player.played == [.start])

    await session.end()?.value
    #expect(player.played == [.start, .stop])
}

@MainActor
@Test func playSoundsTrueFiresTheCancelCue() async throws {
    let player = FakeCuePlayer()
    let session = try makeSession(cuePlayer: player)

    session.begin()
    session.cancel()
    #expect(player.played == [.start, .cancel])
}

@MainActor
@Test func playSoundsFalseFiresNoCues() async throws {
    let defaults = FakeUserDefaults()
    let settings = Settings(defaults: defaults)
    settings.playSounds = false
    let player = FakeCuePlayer()
    let session = try makeSession(settings: settings, passes: [pass("hi")], cuePlayer: player)

    session.begin()
    await session.end()?.value
    #expect(player.played.isEmpty)
}

// MARK: - a throwing recorder.start() still tears down cleanly (Finding 5)

@MainActor
@Test func throwingRecorderStartLeavesStateIdleAndUnwindsMuteAndMediaPause() async throws {
    struct StartFailed: Error {}
    let media = FakeMediaControl()
    let volume = FakeVolumeControl()
    let recorder = FakeRecorder()
    recorder.startError = StartFailed()
    let session = try makeSession(media: media, volume: volume, recorder: recorder)

    session.begin()

    #expect(session.state == .idle)
    #expect(media.pauses == 1)
    #expect(media.resumes == 1)
    // The mute waits out the start cue, and this failure unwinds inside
    // that window: teardown cancels the pending mute, so the output volume
    // is never touched at all — the strongest form of "left as we found
    // it". `restore()` still runs, and is a no-op against nothing muted.
    #expect(volume.mutes == 0)
    #expect(volume.restores == 1)
}

// MARK: - cancel works during transcribing too (Ruling)

@MainActor
@Test func cancelDuringTranscribingDeliversNothingAndStoresNothing() async throws {
    let store = try TranscriptStore(inMemory: true)
    let clipboard = FakeClipboard()
    clipboard.string = "untouched"
    let transcriber = DelayedTranscriber(delay: .milliseconds(60), text: "should never land anywhere")
    let session = try makeSession(store: store, transcriber: transcriber, clipboard: clipboard)

    session.begin()
    let task = session.end()
    #expect(session.state == .transcribing)

    session.cancel()  // escape, mid-transcription
    await task?.value

    #expect(session.state == .idle)
    #expect(store.all().isEmpty)
    #expect(clipboard.string == "untouched")
}

@MainActor
@Test func cancelDuringTranscribingPlaysTheCancelCue() async throws {
    let player = FakeCuePlayer()
    let transcriber = DelayedTranscriber(delay: .milliseconds(60))
    let session = try makeSession(transcriber: transcriber, cuePlayer: player)

    session.begin()
    let task = session.end()
    session.cancel()
    await task?.value

    #expect(player.played == [.start, .cancel])
}

// MARK: - cue/mute/pause ordering (Item 4)

/// The start cue must be audible under `muteWhileRecording`'s default of
/// on, which means it has to play before the mute takes effect. Media
/// pause comes first of all: `MediaKeyControl` decides whether anything is
/// playing by asking if the output device is running, and the cue itself
/// runs it — sampled after the cue, Reed's own beep would read as "music
/// playing" and the play/pause toggle would *start* paused music.
@MainActor
@Test func startCuePlaysBeforeMutingAndPausingSoItIsAudible() async throws {
    let log = EventLog()
    let media = FakeMediaControl(log: log)
    let volume = FakeVolumeControl(log: log)
    let cuePlayer = FakeCuePlayer(log: log)
    let session = try makeSession(media: media, volume: volume, cuePlayer: cuePlayer)

    session.begin()

    #expect(await waitUntil { log.events.contains(.mute) })
    #expect(log.events == [.pause, .cue(.start), .mute])
}

/// Same reasoning as the start cue, for `cancel()`'s cue: it must play
/// before volume is restored and media resumed, not slip after teardown by
/// accident.
@MainActor
@Test func cancelCuePlaysBeforeVolumeIsRestoredAndMediaResumed() async throws {
    let log = EventLog()
    let media = FakeMediaControl(log: log)
    let volume = FakeVolumeControl(log: log)
    let cuePlayer = FakeCuePlayer(log: log)
    // A cue duration no test will outlast: the mute never lands, which is
    // itself the point — a recording cancelled inside the cue window must
    // leave the output volume untouched rather than muted-then-restored.
    let session = try makeSession(
        media: media, volume: volume, startCueDuration: .seconds(60), cuePlayer: cuePlayer
    )

    session.begin()
    session.cancel()

    #expect(log.events == [
        .pause, .cue(.start),
        .cue(.cancel), .resume, .restore,
    ])
    #expect(volume.mutes == 0)
}

// MARK: - notDetermined microphone requests access (Item: never asked, never stranded)

/// A small mutable box, same pattern as `StateBox` above: lets a
/// `requestMicrophoneAccess` fake record that it was actually called, from
/// inside a closure the compiler can't otherwise prove is `Sendable`.
@MainActor
private final class RequestedBox {
    var requested = false
}

// MARK: - problem (Item 2)

@MainActor
@Test func problemIsNilBeforeAnyDictation() async throws {
    let session = try makeSession()
    #expect(session.problem == nil)
}

/// A denied (or restricted) microphone must be caught *before* `begin()`
/// ever calls `recorder.start()` — not attempted-and-recovered. `startCount
/// == 0` is the assertion that actually discriminates this from the old
/// behaviour: comment out the authorization guard in `begin()` and this
/// still passes on `problem != nil` (the post-`start()` catch would still
/// set one) but fails on `startCount == 0`, because the fake would have
/// been asked to start and thrown.
@MainActor
@Test func deniedMicrophoneSetsAnExplanatoryProblemAndNeverCallsStart() async throws {
    let recorder = FakeRecorder()
    let session = try makeSession(recorder: recorder, microphoneAuthorizationOverride: .denied)

    session.begin()

    #expect(session.state == .idle)
    #expect(recorder.startCount == 0)
    #expect(session.problem != nil)
    #expect(session.problem?.contains("microphone") == true || session.problem?.contains("Microphone") == true)
}

/// `.notDetermined` (never asked) is not the same as `.denied` (said no):
/// `begin()` must actually ask, right there, rather than only report —
/// that's the fix for the "stranded" class of bug this project keeps
/// hitting (never asked, so macOS never lists the app, so there is no way
/// back in without this).
@MainActor
@Test func notDeterminedMicrophoneRequestsAccessBeforeDoingAnythingElse() async throws {
    let recorder = FakeRecorder()
    let requestedBox = RequestedBox()
    let session = try makeSession(
        recorder: recorder,
        microphoneAuthorizationOverride: .notDetermined,
        requestMicrophoneAccess: {
            requestedBox.requested = true
            return true
        }
    )

    await session.begin()?.value

    #expect(requestedBox.requested)
}

/// If the system prompt grants access, `begin()` must go on to do the
/// dictation the user just asked for — not stop at merely knowing the
/// answer.
@MainActor
@Test func aGrantedRequestProceedsToRecording() async throws {
    let recorder = FakeRecorder()
    let session = try makeSession(
        recorder: recorder,
        microphoneAuthorizationOverride: .notDetermined,
        requestMicrophoneAccess: { true }
    )

    await session.begin()?.value

    #expect(session.state == .recording)
    #expect(recorder.startCount == 1)
}

/// If the system prompt is refused, `begin()` must set `problem` — same as
/// the pre-existing denied-microphone path — and never touch the recorder:
/// asking and being told no is not licence to try anyway.
@MainActor
@Test func aRefusedRequestSetsAProblemAndNeverTouchesAudio() async throws {
    let recorder = FakeRecorder()
    let session = try makeSession(
        recorder: recorder,
        microphoneAuthorizationOverride: .notDetermined,
        requestMicrophoneAccess: { false }
    )

    await session.begin()?.value

    #expect(session.state == .idle)
    #expect(recorder.startCount == 0)
    #expect(session.problem != nil)
    // Distinct wording from the denied case: nothing has been turned off,
    // so the message must not say to turn it "back" on.
    #expect(session.problem?.contains("back on") != true)
}

@MainActor
@Test func recorderFailureForAReasonOtherThanPermissionStillSetsAProblem() async throws {
    struct StartFailed: Error {}
    let recorder = FakeRecorder()
    recorder.startError = StartFailed()
    let session = try makeSession(recorder: recorder, microphoneAuthorizationOverride: .authorized)

    session.begin()

    #expect(session.state == .idle)
    #expect(recorder.startCount == 1)
    #expect(session.problem != nil)
    // Distinct wording from the denied case: this message must not claim
    // the user needs to flip a permission switch when the real cause is
    // unknown (no mic attached, another app holding it exclusively, etc).
    #expect(session.problem?.contains("microphone access") != true)
}

@MainActor
@Test func aModelThatFailsToLoadSetsAProblem() async throws {
    let session = try makeSession(transcriber: ThrowingTranscriber())

    session.begin()
    await session.end()?.value

    #expect(session.state == .idle)
    #expect(session.problem != nil)
}

@MainActor
@Test func anEmptyTranscriptionSetsAProblem() async throws {
    let session = try makeSession(passes: [pass("   ")])

    session.begin()
    await session.end()?.value

    #expect(session.state == .idle)
    #expect(session.problem != nil)
}

@MainActor
@Test func missingAccessibilitySetsAProblemEvenThoughDeliverySucceeds() async throws {
    let clipboard = FakeClipboard()
    let session = try makeSession(passes: [pass("copied not typed")], clipboard: clipboard, canPaste: false)

    session.begin()
    await session.end()?.value

    #expect(session.state == .idle)
    #expect(session.problem != nil)
    // Delivery itself still succeeded — the text landed on the clipboard —
    // `problem` explains *how* it succeeded, it doesn't mean it failed.
    #expect(clipboard.string == "copied not typed")
}

@MainActor
@Test func aFullySuccessfulDictationNeverSetsAProblem() async throws {
    let session = try makeSession(passes: [pass("all good")], canPaste: true)

    session.begin()
    await session.end()?.value

    #expect(session.state == .idle)
    #expect(session.problem == nil)
}

@MainActor
@Test func cancellingIsNotAProblem() async throws {
    let session = try makeSession()

    session.begin()
    session.cancel()

    #expect(session.problem == nil)
}

@MainActor
@Test func problemClearsOnTheNextBegin() async throws {
    let recorder = FakeRecorder()
    recorder.startError = NSError(domain: "test", code: 1)
    // `.authorized` (the helper's default): this exercises the post-`start()`
    // failure path clearing on retry, not the authorization guard above it.
    let session = try makeSession(recorder: recorder)

    session.begin()
    #expect(session.problem != nil)

    recorder.startError = nil
    session.begin()

    #expect(session.problem == nil)
}

// MARK: - the overlay's final frame matches what was delivered (Item 11)

/// On the batch-fallback path (streaming never confirmed enough to be
/// trusted — the normal case for a short dictation), `finish()`'s
/// authoritative text can differ from whatever the live preview last
/// happened to show. The pill's last visible frame must reflect what was
/// actually delivered, not a stale hypothesis.
@MainActor
@Test func previewTextMatchesTheFinalDeliveredTextOnTheBatchFallbackPath() async throws {
    let session = try makeSession(passes: [pass("the real final transcript")])

    session.begin()
    await session.end()?.value

    #expect(session.previewText == "the real final transcript")
    #expect(session.confirmedText == "the real final transcript")
    #expect(session.hypothesisText.isEmpty)
}

// MARK: - Proofreading

/// Settings with a key and a model saved, so `DictationSession.proofread`
/// gets past its own configuration backstop.
@MainActor
private func proofreadableSettings() -> Settings {
    let settings = Settings(defaults: FakeUserDefaults(), secrets: FakeSecretStore())
    settings.openAIAPIKey = "sk-test"
    settings.proofreadModel = "gpt-5.4-mini"
    return settings
}

@MainActor
@Test func proofreadingPastesTheCorrectedTextRatherThanTheRawOne() async throws {
    let clipboard = FakeClipboard()
    let proofreader = FakeProofreader(result: .success("Você já fez o merge da branch?"))
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("vc ja fez o merge da branch")],
        clipboard: clipboard,
        proofreader: proofreader,
        canPaste: false
    )

    session.begin(proofread: true)
    await session.end()?.value

    #expect(clipboard.string == "Você já fez o merge da branch?")
    #expect(proofreader.requests.count == 1)
    #expect(proofreader.requests.first?.text == "vc ja fez o merge da branch")
}

@MainActor
@Test func plainDictationNeverCallsTheProofreader() async throws {
    let clipboard = FakeClipboard()
    let proofreader = FakeProofreader(result: .success("rewritten"))
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("hello there")],
        clipboard: clipboard,
        proofreader: proofreader,
        canPaste: false
    )

    session.begin()
    await session.end()?.value

    #expect(proofreader.requests.isEmpty)
    #expect(clipboard.string == "hello there")
}

@MainActor
@Test func proofreadingSendsTheSavedKeyModelAndStyle() async throws {
    let settings = proofreadableSettings()
    settings.proofreadModel = "gpt-4.1-mini"
    settings.proofreadStyle = .polish
    settings.openAIAPIKey = "sk-chosen"
    let proofreader = FakeProofreader(result: .success("ok"))
    let session = try makeSession(
        settings: settings,
        passes: [pass("texto")],
        proofreader: proofreader,
        canPaste: false
    )

    session.begin(proofread: true)
    await session.end()?.value

    let request = try #require(proofreader.requests.first)
    #expect(request.model == "gpt-4.1-mini")
    #expect(request.apiKey == "sk-chosen")
    #expect(request.style == .polish)
}

@MainActor
@Test func aFailedProofreadStillPastesTheRawTranscriptionAndSaysWhy() async throws {
    let clipboard = FakeClipboard()
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("vc ja fez o merge")],
        clipboard: clipboard,
        proofreader: FakeProofreader(result: .failure(.unauthorized)),
        canPaste: true
    )

    session.begin(proofread: true)
    await session.end()?.value

    // Pasting, not just copying: with Accessibility granted there is no
    // second problem competing for the pill, so the one the user sees is
    // the proofread failure — see
    // `missingAccessibilityOutranksAFailedProofreadInTheOverlay` for the
    // deliberate other half of that rule.
    //
    // The whole point: a proofread that fails must never cost the user
    // the words they actually spoke.
    #expect(clipboard.string == "vc ja fez o merge")
    #expect(session.problem == ProofreadError.unauthorized.deliveryProblem)
    #expect(session.state == .idle)
}

@MainActor
@Test func aFailedProofreadStillStoresWhatWasDelivered() async throws {
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(
        store: store,
        settings: proofreadableSettings(),
        passes: [pass("raw words")],
        proofreader: FakeProofreader(result: .failure(.unreachable)),
        canPaste: false
    )

    session.begin(proofread: true)
    await session.end()?.value

    #expect(store.all().map(\.text) == ["raw words"])
}

@MainActor
@Test func historyRecordsTheProofreadTextBecauseThatIsWhatWasPasted() async throws {
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(
        store: store,
        settings: proofreadableSettings(),
        passes: [pass("vc ja fez o merge")],
        proofreader: FakeProofreader(result: .success("Você já fez o merge?")),
        canPaste: false
    )

    session.begin(proofread: true)
    await session.end()?.value

    #expect(store.all().map(\.text) == ["Você já fez o merge?"])
}

@MainActor
@Test func theOverlayEntersProofreadingAndEndsShowingTheCorrectedText() async throws {
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("vc ja fez o merge")],
        proofreader: FakeProofreader(result: .success("Você já fez o merge?"), delay: .milliseconds(80)),
        canPaste: false
    )

    session.begin(proofread: true)
    let finished = session.end()

    #expect(await waitUntil { session.state == .proofreading })
    // The raw transcription shows while the call is out — never the live
    // preview's last guess, which is about to be replaced.
    #expect(session.previewText == "vc ja fez o merge")

    await finished?.value
    #expect(session.state == .idle)
    #expect(session.previewText == "Você já fez o merge?")
}

@MainActor
@Test func escapeDuringProofreadingDiscardsInsteadOfPasting() async throws {
    let clipboard = FakeClipboard()
    let store = try TranscriptStore(inMemory: true)
    let session = try makeSession(
        store: store,
        settings: proofreadableSettings(),
        passes: [pass("vc ja fez o merge")],
        clipboard: clipboard,
        proofreader: FakeProofreader(result: .success("Você já fez o merge?"), delay: .milliseconds(80)),
        canPaste: false
    )

    session.begin(proofread: true)
    let finished = session.end()
    #expect(await waitUntil { session.state == .proofreading })

    session.cancel()
    await finished?.value

    #expect(clipboard.string == nil)
    #expect(store.all().isEmpty)
    #expect(session.previewText.isEmpty)
    #expect(session.state == .idle)
}

@MainActor
@Test func aKeyClearedMidRecordingFallsBackRatherThanCallingOpenAI() async throws {
    let settings = proofreadableSettings()
    let clipboard = FakeClipboard()
    let proofreader = FakeProofreader(result: .success("never used"))
    let session = try makeSession(
        settings: settings,
        passes: [pass("raw words")],
        clipboard: clipboard,
        proofreader: proofreader,
        canPaste: true
    )

    session.begin(proofread: true)
    settings.openAIAPIKey = ""
    await session.end()?.value

    #expect(proofreader.requests.isEmpty)
    #expect(clipboard.string == "raw words")
    #expect(session.problem == ProofreadError.notConfigured.deliveryProblem)
}

@MainActor
@Test func aRecordingStartedForProofreadingKeepsThatIntentWhenStoppedByTheOtherShortcut() async throws {
    let proofreader = FakeProofreader(result: .success("corrected"))
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("raw")],
        proofreader: proofreader,
        canPaste: false
    )

    // Started with the proofreading shortcut, stopped with the plain one:
    // stopping is stopping, and the intent belongs to whoever started.
    session.begin(proofread: true)
    session.toggle(proofread: false)
    await waitUntilIdle(session)

    #expect(proofreader.requests.count == 1)
}

@MainActor
@Test func missingAccessibilityOutranksAFailedProofreadInTheOverlay() async throws {
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("raw words")],
        proofreader: FakeProofreader(result: .failure(.unreachable)),
        canPaste: false
    )

    session.begin(proofread: true)
    await session.end()?.value

    // Both went wrong. Only one of them needs the user to do something
    // right now, and it is the one that means the text isn't in the app.
    #expect(session.problem?.contains("⌘V") == true)
}

@MainActor
@Test func reportProblemSurfacesAnUnconfiguredShortcutWithoutRecording() async throws {
    let session = try makeSession(settings: proofreadableSettings())

    session.reportProblem("Proofreading isn't set up yet.")

    #expect(session.problem == "Proofreading isn't set up yet.")
    #expect(session.state == .idle)
}

@MainActor
@Test func reportProblemNeverOverwritesAFailureAlreadyInFlight() async throws {
    let session = try makeSession(
        settings: proofreadableSettings(),
        passes: [pass("raw")],
        proofreader: FakeProofreader(result: .success("ok"), delay: .milliseconds(80))
    )

    session.begin(proofread: true)
    let finished = session.end()
    #expect(await waitUntil { session.state == .proofreading })

    session.reportProblem("should not appear")
    #expect(session.problem != "should not appear")

    await finished?.value
}

/// Waits for a session driven through `toggle()` (which discards the task
/// `end()` returns) to come back to rest.
@MainActor
private func waitUntilIdle(_ session: DictationSession) async {
    _ = await waitUntil { session.state == DictationState.idle }
}

// MARK: - Getting out of `.transcribing` (the stall)
//
// Everything after `end()` used to be a one-way door. `toggle()` ignores
// `.transcribing`, `.proofreading` and `.delivering` — deliberately, so a
// late tap cannot kill a result that is about to land — and `cancel()` only
// marked the result for discard without leaving the state. The state itself
// was left only when `completeEnd()` got all the way through, and
// `completeEnd()` begins by awaiting the pass loop, which cancelling does
// not abort: a `transcribe` call already in flight runs to completion no
// matter what. A slow one — the speech model still compiling on the Neural
// Engine, say — left the pill on screen, the microphone open, the output
// muted, and no gesture that could end any of it.

/// A `transcribe` that never returns within the life of a test. Stands in
/// for the model load that took a minute rather than a moment.
private actor StalledTranscriber: Transcriber {
    func prepare() async throws {}
    func transcribe(_ samples: [Float], timeOffset: Double) async throws -> TranscriptionPass {
        await uncancellableDelay(.seconds(10))
        return TranscriptionPass(text: "far too late", words: [], confidence: 1.0)
    }
}

@MainActor
@Test func escapeDuringTranscribingReturnsToIdleWithoutWaitingForTheResult() async throws {
    let transcriber = DelayedTranscriber(delay: .milliseconds(400))
    let session = try makeSession(transcriber: transcriber)

    session.begin()
    let task = session.end()
    #expect(session.state == .transcribing)

    session.cancel()

    // Synchronously, not after awaiting `task`: the whole point is that the
    // user gets their app back the moment they press escape, rather than
    // whenever the transcription happens to finish.
    #expect(session.state == .idle)

    await task?.value
    #expect(session.state == .idle)
}

@MainActor
@Test func escapeDuringTranscribingLetsANewRecordingStartRightAway() async throws {
    let transcriber = DelayedTranscriber(delay: .milliseconds(400))
    let session = try makeSession(transcriber: transcriber)

    session.begin()
    let task = session.end()
    session.cancel()

    session.begin()
    #expect(session.state == .recording)

    await task?.value
}

@MainActor
@Test func aStalledTranscriptionTimesOutBackToIdleAndSaysSo() async throws {
    let session = try makeSession(transcriber: StalledTranscriber(), resultTimeout: .milliseconds(50))

    session.begin()
    session.end()
    #expect(session.state == .transcribing)

    #expect(await waitUntil { session.state == .idle })
    #expect(session.problem != nil)
}

@MainActor
@Test func aStalledTranscriptionStillGivesBackTheMicrophoneAndTheVolume() async throws {
    // The stall used to happen *before* `completeEnd()` reached its
    // teardown, so the recorder stayed running and the output stayed muted
    // for as long as it lasted. Timing out has to unwind both.
    let volume = FakeVolumeControl()
    let recorder = FakeRecorder()
    let session = try makeSession(
        volume: volume, recorder: recorder,
        transcriber: StalledTranscriber(), resultTimeout: .milliseconds(50))

    session.begin()
    session.end()

    #expect(await waitUntil { session.state == .idle })
    #expect(recorder.stopCount == 1)
    #expect(volume.restores == 1)
    #expect(session.level == 0)
}

@MainActor
@Test func aTimedOutTranscriptionDeliversNothingAndStoresNothingWhenItFinallyLands() async throws {
    let store = try TranscriptStore(inMemory: true)
    let clipboard = FakeClipboard()
    clipboard.string = "untouched"
    let transcriber = DelayedTranscriber(delay: .milliseconds(300), text: "arrived far too late")
    let session = try makeSession(
        store: store, transcriber: transcriber, clipboard: clipboard,
        resultTimeout: .milliseconds(30))

    session.begin()
    let task = session.end()
    #expect(await waitUntil { session.state == .idle })

    await task?.value

    #expect(store.all().isEmpty)
    #expect(clipboard.string == "untouched")
}

@MainActor
@Test func anAbandonedTranscriptionNeverTouchesTheRecordingThatReplacedIt() async throws {
    // The hazard the generation counter exists for: once a run can be
    // abandoned while its `completeEnd()` is still in flight, that orphan
    // can outlive the state it was working on — and must not publish text
    // into, or idle out, whatever the user started next.
    let store = try TranscriptStore(inMemory: true)
    let transcriber = DelayedTranscriber(delay: .milliseconds(200), text: "text from the abandoned run")
    let session = try makeSession(store: store, transcriber: transcriber)

    session.begin()
    let abandoned = session.end()
    session.cancel()

    session.begin()
    #expect(session.state == .recording)

    await abandoned?.value

    // Still recording, still empty: the orphan published nothing and ended
    // nothing.
    #expect(session.state == .recording)
    #expect(session.previewText == "")
    #expect(store.all().isEmpty)
}
