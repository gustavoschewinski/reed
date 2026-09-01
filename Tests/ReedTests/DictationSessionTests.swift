import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Reed

// MARK: - Fakes

private final class FakeMediaControl: MediaControl, @unchecked Sendable {
    var pauses = 0
    var resumes = 0
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
}

@MainActor
private final class FakeVolumeControl: VolumeControl {
    var mutes = 0
    var restores = 0
    func mute() { mutes += 1 }
    func restore() { restores += 1 }
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

// MARK: - Helper

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
    canPaste: Bool = true,
    paste: (() -> Void)? = nil,
    passInterval: Duration = .milliseconds(5)
) throws -> DictationSession {
    let store = try store ?? TranscriptStore(inMemory: true)
    let settings = settings ?? Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let backing = transcriber ?? ScriptedTranscriber(passes: passes)
    let streaming = StreamingTranscriber(transcriber: backing)

    return DictationSession(
        recorder: recorder,
        transcriber: streaming,
        volumeControl: volume,
        mediaControl: media,
        store: store,
        settings: settings,
        clipboard: clipboard,
        canPaste: canPaste,
        paste: paste ?? {},
        passInterval: passInterval
    )
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

    #expect(volume.mutes == 1)
    #expect(recorder.startCount == 1)
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
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
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

    try await Task.sleep(for: .milliseconds(100))

    // Checked before cancel() — which, correctly, clears previewText as
    // part of its own cleanup.
    #expect(session.previewText == "live preview text")

    session.cancel()
    #expect(session.previewText.isEmpty)
}
