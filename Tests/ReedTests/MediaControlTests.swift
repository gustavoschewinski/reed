import Foundation
import Testing
@testable import Reed

/// Records how many times `MediaKeyControl` asked to post the toggle, without
/// ever posting a real media key event. `result` controls what the fake report
/// back as success/failure, letting tests script both outcomes.
private final class ToggleSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var result = true

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func post() -> Bool {
        lock.lock()
        _count += 1
        lock.unlock()
        return result
    }
}

@Test func resumeWithoutAPauseDoesNothing() {
    // The dangerous case: resuming when we never paused would start playback.
    let spy = ToggleSpy()
    let control = MediaKeyControl(postToggle: spy.post, isPlaying: { true })
    control.resume()  // must be a no-op, not a key press
    control.resume()
    #expect(spy.count == 0)
}

@Test func pauseWhileNothingIsPlayingPostsNothing() {
    let spy = ToggleSpy()
    let control = MediaKeyControl(postToggle: spy.post, isPlaying: { false })
    control.pause()
    #expect(spy.count == 0)
}

@Test func pauseThenResumeWhilePlayingTogglesOnceEach() {
    let spy = ToggleSpy()
    let control = MediaKeyControl(postToggle: spy.post, isPlaying: { true })
    control.pause()
    #expect(spy.count == 1)
    control.resume()
    #expect(spy.count == 2)
}

@Test func repeatedPauseWhilePlayingPostsOnlyOnce() {
    let spy = ToggleSpy()
    let control = MediaKeyControl(postToggle: spy.post, isPlaying: { true })
    control.pause()
    control.pause()
    #expect(spy.count == 1)
}

@Test func repeatedResumeAfterOnePausePostsOnlyOnce() {
    let spy = ToggleSpy()
    let control = MediaKeyControl(postToggle: spy.post, isPlaying: { true })
    control.pause()
    #expect(spy.count == 1)
    control.resume()
    #expect(spy.count == 2)
    control.resume()
    #expect(spy.count == 2)  // the second resume must not post again
}

@Test func pauseDoesNotMarkAsPausedWhenTheKeyPostFails() {
    // If the key event can't even be constructed, didPause must stay false —
    // otherwise the next resume() would fire the first *successful* toggle at
    // media nobody actually paused.
    let spy = ToggleSpy()
    spy.result = false
    let control = MediaKeyControl(postToggle: spy.post, isPlaying: { true })
    control.pause()
    #expect(spy.count == 1)
    control.resume()
    #expect(spy.count == 1)  // resume must see didPause == false and skip
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
