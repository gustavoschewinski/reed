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
