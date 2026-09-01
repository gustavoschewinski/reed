import AppKit
import CoreAudio

protocol MediaControl: Sendable {
    func pause()
    func resume()
}

/// Used when media control is disabled. Dictation must work regardless, so this
/// is also the fallback whenever anything goes wrong.
struct NoOpMediaControl: MediaControl {
    func pause() {}
    func resume() {}
}

/// Pauses whatever is playing by posting the system play/pause key, the same
/// event the key on the keyboard sends.
///
/// The key is a toggle and carries no state, so pressing it when nothing is
/// playing would *start* playback. Guarding on whether the output device is
/// actually running, and only resuming what we ourselves paused, means the worst
/// case is a track left paused — never one that starts unbidden.
final class MediaKeyControl: MediaControl, @unchecked Sendable {
    private let lock = NSLock()
    private var didPause = false

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard !didPause, Self.isAudioPlaying else { return }
        Self.postPlayPause()
        didPause = true
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard didPause else { return }
        Self.postPlayPause()
        didPause = false
    }

    /// True when any process is playing through the default output device.
    static var isAudioPlaying: Bool {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &device
        ) == noErr else { return false }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device, &runningAddress, 0, nil, &runningSize, &running
        ) == noErr else { return false }

        return running == 1
    }

    /// NX_KEYTYPE_PLAY is 16; the system-defined event subtype for a media key
    /// is 8. `data1` packs the key code and the down/up flag together.
    private static func postPlayPause() {
        for isDown in [true, false] {
            let flags = (isDown ? 0xA : 0xB) << 8
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (16 << 16) | flags, data2: -1
            )?.cgEvent else { continue }
            event.post(tap: .cghidEventTap)
        }
    }
}
