import AudioToolbox
import CoreAudio
import Foundation

/// Silences system output while recording so playing audio is not transcribed,
/// and puts the volume back exactly where it was.
final class SystemAudio {
    /// The device that was muted and the volume it had, captured together so
    /// `restore()` always writes back to the device that was actually silenced
    /// — not whatever happens to be the default output when it's called.
    private var muted: (device: AudioDeviceID, volume: Float32)?

    func mute() {
        guard muted == nil, let device = defaultOutput() else { return }
        guard let currentVolume = volume(of: device) else {
            // Many aggregate/HDMI devices don't support VirtualMainVolume at
            // all. Without a real reading there is nothing safe to restore
            // later, so mute() must not record any state — fully succeed or
            // leave no trace.
            NSLog("Reed: could not read output volume; skipping mute")
            return
        }
        guard setVolume(0, on: device) else {
            NSLog("Reed: failed to mute output volume")
            return
        }
        muted = (device: device, volume: currentVolume)
    }

    func restore() {
        guard let muted else { return }
        self.muted = nil

        guard deviceExists(muted.device) else {
            // The default output changed after mute() (headphones plugged in
            // mid-dictation, say). Writing the captured volume to whatever is
            // current now would silence a device that was never muted, and
            // leave the one we did mute silent forever. Drop the restore
            // instead of guessing.
            NSLog("Reed: output device changed since mute; dropping the restore")
            return
        }
        guard setVolume(muted.volume, on: muted.device) else {
            NSLog("Reed: failed to restore output volume")
            return
        }
    }

    private func defaultOutput() -> AudioDeviceID? {
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
    private func deviceExists(_ id: AudioDeviceID) -> Bool {
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

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func volume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    @discardableResult
    private func setVolume(_ value: Float32, on device: AudioDeviceID) -> Bool {
        var address = volumeAddress()
        var v = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
        ) == noErr
    }
}
