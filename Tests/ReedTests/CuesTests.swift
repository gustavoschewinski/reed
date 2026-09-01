import AppKit
import Testing
@testable import Reed

/// Regression coverage for the crash where AppKit called
/// `Cues.PlaybackRetainer.sound(_:didFinishPlaying:)` from a non-main thread
/// (`__NSThreadPerformPerform`, per the crash trace) while the method was
/// still `@MainActor`-isolated. Swift's executor check
/// (`_checkExpectedExecutor`) dereferenced a bad address and the whole
/// process died with `EXC_BAD_ACCESS`.
///
/// These tests never call `NSSound.play()` — they only exercise
/// `PlaybackRetainer`'s lock-protected bookkeeping, never real audio
/// playback, per the project's "swift test never plays audio" rule. Test
/// `NSSound` instances are loaded from macOS's own bundled system sounds via
/// `NSSound(contentsOf:byReference:)` — the same initializer `Cues.play`
/// uses — rather than the bare `NSSound()`, which produces objects that
/// misbehave under `Set` (this was confirmed by hand while writing this
/// test: a `Set<NSSound>` populated with `NSSound()` instances silently ends
/// up empty).
@Suite struct PlaybackRetainerTests {
    /// One real, distinct `NSSound` per call — loaded, never played.
    private static func loadSystemSound() throws -> NSSound {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
        return try #require(NSSound(contentsOf: url, byReference: true))
    }

    @Test func retainFromBackgroundQueuePopulatesTheSet() throws {
        let retainer = Cues.PlaybackRetainer()
        let sounds = try (0..<50).map { _ in try Self.loadSystemSound() }

        let group = DispatchGroup()
        for sound in sounds {
            group.enter()
            DispatchQueue.global().async {
                retainer.retain(sound)
                group.leave()
            }
        }
        group.wait()

        #expect(retainer.count == sounds.count)
    }

    /// Calls the delegate method the same way AppKit does: through the
    /// `NSSoundDelegate` existential (dynamic/@objc dispatch), synchronously
    /// on a background thread — not via an `async` hop, which would mask the
    /// original bug by never actually landing off-main in a way the old
    /// `@MainActor` annotation's runtime check would object to. Against the
    /// old annotation, this reliably crashed the process (verified by hand:
    /// reverting `nonisolated` and running this test alone traps the test
    /// process); against `nonisolated`, it completes normally and drains
    /// the set. The compiler warns at the call site below ("call to main
    /// actor-isolated function in a synchronous nonisolated context")
    /// because `NSSoundDelegate`'s requirement is itself `@MainActor` in
    /// the SDK — that gap between the protocol's declared isolation and
    /// AppKit's actual off-main delivery is the root cause this whole test
    /// exists to guard against, so the warning is expected, not a mistake.
    @Test func delegateCallbackFromBackgroundThreadDoesNotTrapAndDrainsTheSet() throws {
        let retainer = Cues.PlaybackRetainer()
        let delegate: NSSoundDelegate = retainer
        let sounds = try (0..<50).map { _ in try Self.loadSystemSound() }

        for sound in sounds {
            retainer.retain(sound)
        }
        #expect(retainer.count == sounds.count)

        let group = DispatchGroup()
        for sound in sounds {
            group.enter()
            DispatchQueue.global().async {
                delegate.sound?(sound, didFinishPlaying: true)
                group.leave()
            }
        }
        group.wait()

        #expect(retainer.count == 0)
    }

    @Test func releasingASoundThatWasNeverRetainedIsANoOp() throws {
        let retainer = Cues.PlaybackRetainer()
        let sound = try Self.loadSystemSound()

        retainer.release(sound)

        #expect(retainer.count == 0)
    }
}
