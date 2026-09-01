import AudioToolbox
import CoreAudio
import Foundation

/// Silences system output while recording so playing audio is not transcribed,
/// and puts the volume back exactly where it was.
final class SystemAudio {
    private var previousVolume: Float32?

    func mute() {
        guard previousVolume == nil, let device = defaultOutput() else { return }
        previousVolume = volume(of: device)
        setVolume(0, on: device)
    }

    func restore() {
        guard let previous = previousVolume, let device = defaultOutput() else { return }
        setVolume(previous, on: device)
        previousVolume = nil
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

    private func setVolume(_ value: Float32, on device: AudioDeviceID) {
        var address = volumeAddress()
        var v = value
        _ = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
        )
    }
}
