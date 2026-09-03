import Testing
@testable import Reed

/// The play/pause media key is a blind toggle, and macOS exposes no
/// reliable way to know whether anything is playing — browsers hold the
/// output device open while silent, so "is audio running" reads true on an
/// idle Mac and pressing the key *starts* paused music. Muting, which is on
/// by default, already silences playback while recording.
@MainActor
@Test func mediaPauseIsOffByDefault() {
    let settings = Settings(defaults: FakeUserDefaults())
    #expect(settings.pauseMediaWhileRecording == false)
    #expect(settings.muteWhileRecording == true)
}

// MARK: - Proofreading

/// The proofreading shortcut is gated on both halves being present, and
/// `AppDelegate` refuses to record without them — so a fresh install must
/// read as unconfigured even though a model is pre-filled.
@MainActor
@Test func proofreadingIsUnconfiguredUntilAKeyIsSaved() {
    let settings = Settings(defaults: FakeUserDefaults(), secrets: FakeSecretStore())

    #expect(settings.openAIAPIKey.isEmpty)
    #expect(settings.proofreadModel == Settings.defaultProofreadModel)
    #expect(settings.proofreadStyle == .correct)
    #expect(settings.isProofreadConfigured == false)

    settings.openAIAPIKey = "sk-test"
    #expect(settings.isProofreadConfigured)
}

/// Whitespace is not a key, and is exactly what a half-finished paste into
/// the `SecureField` leaves behind.
@MainActor
@Test func whitespaceIsNotAConfiguredProofreader() {
    let settings = Settings(defaults: FakeUserDefaults(), secrets: FakeSecretStore())

    settings.openAIAPIKey = "   \n "
    #expect(settings.isProofreadConfigured == false)

    settings.openAIAPIKey = "sk-test"
    settings.proofreadModel = " "
    #expect(settings.isProofreadConfigured == false)
}

/// The key belongs in the Keychain and nowhere else: anything that can read
/// `~/Library/Preferences` would otherwise be able to spend the user's
/// money with it.
@MainActor
@Test func theAPIKeyGoesToTheKeychainAndNeverToUserDefaults() {
    let defaults = FakeUserDefaults()
    let secrets = FakeSecretStore()
    let settings = Settings(defaults: defaults, secrets: secrets)

    settings.openAIAPIKey = "sk-secret"

    #expect(secrets.secret(forKey: "openai.apiKey") == "sk-secret")
    #expect(secrets.secret(forKey: "openai.apiKey") == settings.openAIAPIKey)
    // Nothing anywhere in the preferences store holds it.
    for key in ["openai.apiKey", "reed.settings.openAIAPIKey", "reed.settings.apiKey"] {
        #expect(defaults.object(forKey: key) == nil)
    }
}

/// Clearing the field must remove the credential, not store a blank one —
/// otherwise "I deleted my key" leaves it sitting in the Keychain.
@MainActor
@Test func clearingTheKeyDeletesItFromTheKeychain() {
    let secrets = FakeSecretStore()
    let settings = Settings(defaults: FakeUserDefaults(), secrets: secrets)

    settings.openAIAPIKey = "sk-secret"
    settings.openAIAPIKey = ""

    #expect(secrets.secret(forKey: "openai.apiKey") == nil)
}

@MainActor
@Test func proofreadingPreferencesSurviveARelaunch() {
    let defaults = FakeUserDefaults()
    let secrets = FakeSecretStore()

    let first = Settings(defaults: defaults, secrets: secrets)
    first.openAIAPIKey = "sk-saved"
    first.proofreadModel = "gpt-4.1-mini"
    first.proofreadStyle = .polish

    let second = Settings(defaults: defaults, secrets: secrets)
    #expect(second.openAIAPIKey == "sk-saved")
    #expect(second.proofreadModel == "gpt-4.1-mini")
    #expect(second.proofreadStyle == .polish)
    #expect(second.isProofreadConfigured)
}
