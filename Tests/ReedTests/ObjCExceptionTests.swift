import AVFoundation
import Foundation
import Testing
@testable import Reed

// The seam that lets `Recorder` survive an Objective-C exception raised
// from inside AVFAudio. AVFAudio reports several classes of failure by
// raising rather than by returning an error — `installTap`'s
// "required condition is false…" among them — and Swift's `catch` cannot
// see those. Without this, one raise leaves the app running but
// permanently broken; with it, the raise arrives at `DictationSession` as
// an ordinary `Error`, which it already knows how to explain and unwind.

@Test func aBlockThatRaisesComesBackAsAThrownError() {
    #expect(throws: ObjCException.Raised.self) {
        try ObjCException.catching {
            NSException(name: .invalidArgumentException, reason: "boom", userInfo: nil).raise()
        }
    }
}

@Test func theRaisedNameAndReasonSurviveTheCrossing() throws {
    // The reason string is the only thing that says *what* went wrong —
    // "required condition is false: format.sampleRate ==
    // inputHWFormat.sampleRate" is a diagnosis; a bare "something raised"
    // is not. It has to reach the log intact.
    do {
        try ObjCException.catching {
            NSException(
                name: .internalInconsistencyException,
                reason: "required condition is false: format.sampleRate == inputHWFormat.sampleRate",
                userInfo: nil
            ).raise()
        }
        Issue.record("expected the raise to surface as a thrown error")
    } catch let raised as ObjCException.Raised {
        #expect(raised.name == NSExceptionName.internalInconsistencyException.rawValue)
        #expect(raised.reason.contains("inputHWFormat.sampleRate"))
    }
}

@Test func aBlockThatDoesNotRaiseRunsAndThrowsNothing() throws {
    var ran = false
    try ObjCException.catching { ran = true }
    #expect(ran)
}

@Test func aThrownSwiftErrorInsideTheBlockIsNotSwallowed() {
    // The block is non-throwing by signature, so a Swift error has to be
    // carried out by the caller. This pins the pattern `Recorder.start()`
    // uses around `engine.start()`, which reports some failures by throwing
    // and others by raising.
    struct Boom: Error {}
    var thrown: Error?
    #expect(throws: Never.self) {
        try ObjCException.catching {
            do { throw Boom() } catch { thrown = error }
        }
    }
    #expect(thrown is Boom)
}

// MARK: - A real AVFAudio raise, not a synthetic one

/// The synthetic `NSException` tests above prove the plumbing. This proves
/// the thing the plumbing exists for: AVFAudio really does raise, really is
/// invisible to a Swift `catch`, and really is caught by the shim.
///
/// Deliberately the *main mixer* node and a duplicate tap, rather than the
/// input node and a mismatched sample rate: `installTap` raises for both,
/// from the same place and by the same mechanism, but this one needs no
/// microphone, no permission prompt, and no dependence on whatever
/// authorization state the machine running `swift test` happens to be in.
///
/// The duplicate install is not hypothetical either. It is the second half
/// of the original failure: once a raise had escaped `Recorder.start()`
/// mid-way, the tap it had already installed was never removed, so every
/// later attempt raised here instead — which is why the app stayed broken
/// until it was relaunched rather than recovering on the next press.
@Test func aRealAVFAudioRaiseIsCaught() throws {
    let engine = AVAudioEngine()
    let mixer = engine.mainMixerNode
    try #require(mixer.outputFormat(forBus: 0).sampleRate > 0, "no usable output device")

    mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
    defer { mixer.removeTap(onBus: 0) }

    #expect(throws: ObjCException.Raised.self) {
        try ObjCException.catching {
            mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
        }
    }
}
