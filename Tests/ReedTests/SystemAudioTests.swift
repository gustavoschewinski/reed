import CoreAudio
import Foundation
import Testing
@testable import Reed

/// `SystemAudio` itself is not broadly unit-testable — `mute()`/`restore()`
/// touch real CoreAudio output volume, exactly what `swift test` must never
/// do (see the project's own testing constraints). These two tests cover
/// only `restoreLeftoverMuteIfNeeded()`'s two branches that provably never
/// reach `setVolume()`, so they can run safely: nothing persisted (an
/// immediate no-op), and a persisted device ID that no longer exists (the
/// `deviceExists` guard returns before any volume call). The
/// "device still exists, volume actually gets restored" branch is the same
/// class of not-unit-testable-without-touching-hardware as `mute()`/
/// `restore()` themselves, and is left to manual verification — see the
/// final report.
///
/// `FakeUserDefaults` (Item 6) rather than a real, suite-named
/// `UserDefaults`: nothing here touches disk, so there is nothing to clean
/// up and nothing that could leak a stray plist into the user's real
/// `~/Library/Preferences`.
struct SystemAudioTests {
    @Test func restoreLeftoverMuteIfNeededIsANoOpWhenNothingWasLeftMuted() {
        let defaults = FakeUserDefaults()

        // Must return without touching CoreAudio at all when there is
        // nothing to restore — the absence of a crash/hang here, under the
        // harness's own "never touch real audio" constraint, is the point.
        SystemAudio.restoreLeftoverMuteIfNeeded(defaults: defaults)

        #expect(defaults.object(forKey: SystemAudio.PersistKeys.device) == nil)
        #expect(defaults.object(forKey: SystemAudio.PersistKeys.volume) == nil)
    }

    @Test func restoreLeftoverMuteIfNeededClearsStateForADeviceThatNoLongerExists() {
        let defaults = FakeUserDefaults()

        // Real CoreAudio device IDs are small, session-assigned integers.
        // This one is implausibly large specifically so it can never
        // collide with a real connected device — the "device no longer
        // exists" branch this exercises returns before ever calling
        // `setVolume`, so this cannot touch the machine's real output
        // volume.
        let bogusDeviceID: AudioDeviceID = 0xFFFF_FFF0
        defaults.set(Int(bogusDeviceID), forKey: SystemAudio.PersistKeys.device)
        defaults.set(Float(0.42), forKey: SystemAudio.PersistKeys.volume)

        SystemAudio.restoreLeftoverMuteIfNeeded(defaults: defaults)

        // Cleared either way — Item 1's whole point is that a leftover
        // record left behind by a crashed previous run must not linger
        // forever once this run has looked at it, even when there was
        // nothing left to actually restore.
        #expect(defaults.object(forKey: SystemAudio.PersistKeys.device) == nil)
        #expect(defaults.object(forKey: SystemAudio.PersistKeys.volume) == nil)
    }
}
