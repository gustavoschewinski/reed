import Testing
@testable import Reed

@Test func resumeWithoutAPauseDoesNothing() {
    // The dangerous case: resuming when we never paused would start playback.
    let control = MediaKeyControl()
    control.resume()  // must be a no-op, not a key press
    control.resume()
}

@Test func audioPlayingQueryDoesNotThrowOrHang() {
    _ = MediaKeyControl.isAudioPlaying
}

@Test func noOpControlIsSafeToCallInAnyOrder() {
    let control = NoOpMediaControl()
    control.resume()
    control.pause()
    control.pause()
    control.resume()
}
