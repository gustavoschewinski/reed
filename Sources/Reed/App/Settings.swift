import CoreAudio
import Foundation

/// How a press of the dictation shortcut is turned into a recording
/// gesture. See `HotkeyInterpreter` for how each case is actually
/// interpreted from raw key-down/key-up timestamps.
enum DictationMode: String, Sendable, Equatable, CaseIterable {
    /// Press to start, press again to stop. Hold does nothing different —
    /// the default, and the one that matches what "click to start, click
    /// to stop" means to someone who has never used Reed before.
    case toggle
    /// Records only while the shortcut is held down; releasing it stops.
    case holdToTalk
    /// A quick press toggles; holding past the threshold instead starts
    /// push-to-talk. Reed's original behavior. A press landing just over
    /// the threshold reads, from the outside, as "it made a sound but
    /// didn't start" — which is why this is no longer the default.
    case automatic
}

/// User-facing preferences, persisted to `UserDefaults`.
///
/// The hotkey itself is not stored here — KeyboardShortcuts persists its own
/// shortcut under the name `dictate`.
@MainActor
final class Settings: ObservableObject {
    private enum Keys {
        static let inputDeviceID = "reed.settings.inputDeviceID"
        static let playSounds = "reed.settings.playSounds"
        static let muteWhileRecording = "reed.settings.muteWhileRecording"
        static let pauseMediaWhileRecording = "reed.settings.pauseMediaWhileRecording"
        static let hasCompletedOnboarding = "reed.settings.hasCompletedOnboarding"
        static let dictationMode = "reed.settings.dictationMode"
    }

    private let defaults: any UserDefaultsLike

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

    /// Defaults to `.toggle` — click to start, click to stop. Not
    /// `.automatic`: a press landing over the 400ms tap/hold threshold used
    /// to silently become a fraction-of-a-second push-to-talk, which reads
    /// as "it made a sound but didn't start."
    @Published var dictationMode: DictationMode {
        didSet { defaults.set(dictationMode.rawValue, forKey: Keys.dictationMode) }
    }

    init(defaults: any UserDefaultsLike = UserDefaults.standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.playSounds: true,
            Keys.muteWhileRecording: true,
            Keys.pauseMediaWhileRecording: true,
            Keys.hasCompletedOnboarding: false,
            Keys.dictationMode: DictationMode.toggle.rawValue,
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
        if let raw = defaults.object(forKey: Keys.dictationMode) as? String, let mode = DictationMode(rawValue: raw) {
            dictationMode = mode
        } else {
            dictationMode = .toggle
        }
    }
}
