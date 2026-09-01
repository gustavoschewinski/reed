import CoreAudio
import Foundation

/// User-facing preferences, persisted to `UserDefaults`.
///
/// The hotkey itself is not stored here — KeyboardShortcuts persists its own
/// shortcut under the name `dictate`.
@MainActor
final class Settings: ObservableObject {
    private enum Keys {
        static let inputDeviceID = "inputDeviceID"
        static let playSounds = "playSounds"
        static let muteWhileRecording = "muteWhileRecording"
        static let pauseMediaWhileRecording = "pauseMediaWhileRecording"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    /// The input device to record from. `nil` means "use the system default".
    @Published var inputDeviceID: AudioDeviceID? {
        didSet {
            if let inputDeviceID {
                defaults.set(Int(inputDeviceID), forKey: Keys.inputDeviceID)
            } else {
                defaults.removeObject(forKey: Keys.inputDeviceID)
            }
        }
    }

    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.playSounds) }
    }

    @Published var muteWhileRecording: Bool {
        didSet { defaults.set(muteWhileRecording, forKey: Keys.muteWhileRecording) }
    }

    @Published var pauseMediaWhileRecording: Bool {
        didSet { defaults.set(pauseMediaWhileRecording, forKey: Keys.pauseMediaWhileRecording) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.playSounds: true,
            Keys.muteWhileRecording: true,
            Keys.pauseMediaWhileRecording: true,
            Keys.hasCompletedOnboarding: false,
        ])

        if defaults.object(forKey: Keys.inputDeviceID) != nil {
            inputDeviceID = AudioDeviceID(defaults.integer(forKey: Keys.inputDeviceID))
        } else {
            inputDeviceID = nil
        }
        playSounds = defaults.bool(forKey: Keys.playSounds)
        muteWhileRecording = defaults.bool(forKey: Keys.muteWhileRecording)
        pauseMediaWhileRecording = defaults.bool(forKey: Keys.pauseMediaWhileRecording)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }
}
