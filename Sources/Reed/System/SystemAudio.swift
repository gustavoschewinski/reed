import AudioToolbox
import CoreAudio
import Foundation

/// Silences system output while recording so playing audio is not transcribed,
/// and puts the volume back exactly where it was.
final class SystemAudio {
    /// Where `mute()` persists the device/volume pair — deliberately not
    /// under `Settings`' `reed.settings.*` keys, since this isn't a user
    /// preference. Item 1: this is what makes the mute survive the process
    /// dying, which is exactly the case that needs surviving — see
    /// `restoreLeftoverMuteIfNeeded()`.
    /// `internal` (not `private`), deliberately: `SystemAudioTests`
    /// references these directly rather than duplicating the literals.
    enum PersistKeys {
        static let device = "reed.systemAudio.mutedDeviceID"
        static let volume = "reed.systemAudio.mutedVolume"
    }

    /// The device that was muted and the volume it had, captured together so
    /// `restore()` always writes back to the device that was actually silenced
    /// — not whatever happens to be the default output when it's called.
    private var muted: (device: AudioDeviceID, volume: Float32)?
    private let defaults: any UserDefaultsLike

    init(defaults: any UserDefaultsLike = UserDefaults.standard) {
        self.defaults = defaults
    }

    func mute() {
        guard muted == nil, let device = Self.defaultOutput() else { return }
        guard let currentVolume = Self.volume(of: device) else {
            // Many aggregate/HDMI devices don't support VirtualMainVolume at
            // all. Without a real reading there is nothing safe to restore
            // later, so mute() must not record any state — fully succeed or
            // leave no trace.
            NSLog("Reed: could not read output volume; skipping mute")
            return
        }
        // Write-ahead, deliberately in this order — persist before the
        // volume is actually changed, not after. `synchronize()` is
        // deprecated, but its old, blocking behavior is exactly what's
        // wanted here: force the write to happen now rather than racing an
        // async flush against a crash that could land first.
        //
        // If the process dies between this write and the `setVolume` call
        // below, the worst case is a persisted record of a mute that never
        // actually happened — `restoreLeftoverMuteIfNeeded()` at the next
        // launch just writes `currentVolume` back onto `device`, a value
        // that's already correct since nothing was ever changed. Harmless.
        // The reverse order (mute first, persist second — what this used
        // to be) left a window where a kill after the real mute but before
        // the write stranded the user: volume at 0, with no record left
        // anywhere to recover it. Do not swap these back for tidiness —
        // the order is deliberate, even though muting first reads more
        // naturally.
        defaults.set(Int(device), forKey: PersistKeys.device)
        defaults.set(currentVolume, forKey: PersistKeys.volume)
        defaults.synchronize()

        guard Self.setVolume(0, on: device) else {
            NSLog("Reed: failed to mute output volume")
            return
        }
        muted = (device: device, volume: currentVolume)
    }

    func restore() {
        guard let muted else { return }
        self.muted = nil

        guard Self.deviceExists(muted.device) else {
            // The default output changed after mute() (headphones plugged in
            // mid-dictation, say). Writing the captured volume to whatever is
            // current now would silence a device that was never muted, and
            // leave the one we did mute silent forever. Drop the restore
            // instead of guessing.
            NSLog("Reed: output device changed since mute; dropping the restore")
            return
        }

        // Write-ahead, mirrored from `mute()` above: the persisted record
        // is cleared only *after* the volume is actually written back, not
        // before. If the process dies between the two steps below, the
        // worst case is a stale record outliving a restore that already
        // succeeded — the next launch's `restoreLeftoverMuteIfNeeded()`
        // just writes the same, already-correct volume back again, a
        // harmless no-op. The reverse order (clear first, restore
        // second — what this used to be) left a window where a kill after
        // the clear but before `setVolume` erased the only record of a
        // mute that was still in effect, with nothing left to recover it.
        // Do not swap these back for tidiness — the order is deliberate.
        // (On the failure path below, the record is deliberately left in
        // place too, rather than cleared: that gives the next launch
        // another chance to actually fix the volume instead of silently
        // giving up on it.)
        guard Self.setVolume(muted.volume, on: muted.device) else {
            NSLog("Reed: failed to restore output volume")
            return
        }
        Self.clearPersistedMute(defaults)
    }

    /// Launch-time safety net (Item 1): if the previous run died — crash,
    /// force-quit, logout — after `mute()` recorded a device/volume pair
    /// but before `restore()` ever cleared it, `applicationWillTerminate`
    /// never ran to catch it either. This is what does, before this run's
    /// own `SystemAudio` instance (owned by a fresh `DictationSession`) can
    /// mute anything of its own — called once, from `AppDelegate.init()`.
    static func restoreLeftoverMuteIfNeeded(defaults: any UserDefaultsLike = UserDefaults.standard) {
        guard defaults.object(forKey: PersistKeys.device) != nil else { return }
        let device = AudioDeviceID(defaults.integer(forKey: PersistKeys.device))
        let volume = defaults.float(forKey: PersistKeys.volume)
        clearPersistedMute(defaults)

        guard deviceExists(device) else {
            NSLog("Reed: a previous run left the output muted, but its device is gone; nothing to restore")
            return
        }
        guard setVolume(volume, on: device) else {
            NSLog("Reed: failed to restore output volume left muted by a previous run")
            return
        }
        NSLog("Reed: restored output volume left muted by a previous run that didn't exit cleanly")
    }

    private static func clearPersistedMute(_ defaults: any UserDefaultsLike) {
        defaults.removeObject(forKey: PersistKeys.device)
        defaults.removeObject(forKey: PersistKeys.volume)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return nil }
        return id
    }

    /// Whether `id` is still a live device, so `restore()` can refuse to write
    /// to a device that has since disappeared rather than silently targeting
    /// whatever the system now considers default.
    private static func deviceExists(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return false }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return false }

        return ids.contains(id)
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    @discardableResult
    private static func setVolume(_ value: Float32, on device: AudioDeviceID) -> Bool {
        var address = volumeAddress()
        var v = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
        ) == noErr
    }
}
