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
        static let proofreadModel = "reed.settings.proofreadModel"
        static let proofreadStyle = "reed.settings.proofreadStyle"
    }

    /// The Keychain account the OpenAI key is stored under — see
    /// `SecretStore`. Not a `UserDefaults` key, and deliberately not in
    /// `Keys` above, so the two can never be confused for one another.
    private enum Secrets {
        static let openAIAPIKey = "openai.apiKey"
    }

    /// What every chat model in an OpenAI account can be measured against:
    /// fast enough that the pause between speaking and pasting stays under
    /// a second, and cheap enough to run on every dictation. The user can
    /// pick anything else in Settings; this is only what they start with.
    static let defaultProofreadModel = "gpt-5.4-mini"

    private let defaults: any UserDefaultsLike
    private let secrets: any SecretStore

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

    /// The OpenAI key used for proofreading. Backed by the Keychain, not
    /// `UserDefaults` — see `SecretStore`. Published like every other
    /// preference so Settings' picker can enable itself the moment a key
    /// is typed, and blank (never nil) so the `SecureField` bound to it
    /// needs no unwrapping.
    @Published var openAIAPIKey: String {
        didSet {
            guard oldValue != openAIAPIKey else { return }
            secrets.setSecret(openAIAPIKey, forKey: Secrets.openAIAPIKey)
        }
    }

    /// Which OpenAI model proofreads. A stored string rather than an enum:
    /// the list is fetched live from the user's own account (see
    /// `OpenAIModelCatalog`), so a model that ships next month has to be
    /// selectable without Reed shipping again.
    @Published var proofreadModel: String {
        didSet { defaults.set(proofreadModel, forKey: Keys.proofreadModel) }
    }

    @Published var proofreadStyle: ProofreadStyle {
        didSet { defaults.set(proofreadStyle.rawValue, forKey: Keys.proofreadStyle) }
    }

    /// Whether the proofreading shortcut can do anything at all. Both
    /// halves are required, and neither has a usable fallback: without a
    /// key there is nothing to authenticate with, and without a model
    /// there is nothing to ask. `AppDelegate` checks this before the
    /// shortcut is allowed to start a recording, so an unconfigured press
    /// explains itself instead of dictating and then failing at the end.
    var isProofreadConfigured: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !proofreadModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        defaults: any UserDefaultsLike = UserDefaults.standard,
        secrets: any SecretStore = Keychain()
    ) {
        self.defaults = defaults
        self.secrets = secrets
        defaults.register(defaults: [
            Keys.playSounds: true,
            Keys.muteWhileRecording: true,
            // Off by default: the play/pause media key is a blind toggle,
            // and macOS exposes no reliable way to know whether anything
            // is actually playing — apps like browsers hold the output
            // device open indefinitely while silent, so "is audio
            // running" reads true on an idle Mac. Pressing the key then
            // *starts* music the user had paused. Muting (on by default)
            // already silences playback while recording.
            Keys.pauseMediaWhileRecording: false,
            Keys.hasCompletedOnboarding: false,
            Keys.dictationMode: DictationMode.toggle.rawValue,
            Keys.proofreadModel: Self.defaultProofreadModel,
            Keys.proofreadStyle: ProofreadStyle.correct.rawValue,
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
        proofreadModel =
            (defaults.object(forKey: Keys.proofreadModel) as? String) ?? Self.defaultProofreadModel
        if let raw = defaults.object(forKey: Keys.proofreadStyle) as? String,
            let style = ProofreadStyle(rawValue: raw) {
            proofreadStyle = style
        } else {
            proofreadStyle = .correct
        }
        // Read once at construction, not on every access: `SecItemCopyMatching`
        // is a synchronous XPC round trip to `securityd`, and `isProofreadConfigured`
        // is read from a hotkey handler.
        openAIAPIKey = secrets.secret(forKey: Secrets.openAIAPIKey) ?? ""
    }
}
