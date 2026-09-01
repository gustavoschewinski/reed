import Testing
@testable import Reed

@Test func aQuickPressAndReleaseIsATap() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0) == nil)
    #expect(interp.keyUp(at: 0.2) == .tap)
}

@Test func holdingPastTheThresholdStartsPushToTalk() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    // The monitor polls once the threshold has elapsed.
    #expect(interp.elapsedCheck(at: 0.5) == .holdStart)
}

@Test func releasingAfterAHoldEndsIt() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    _ = interp.elapsedCheck(at: 0.5)
    #expect(interp.keyUp(at: 2.0) == .holdEnd)
}

@Test func releaseAfterAHoldIsNotAlsoReportedAsATap() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    _ = interp.elapsedCheck(at: 0.5)
    #expect(interp.keyUp(at: 2.0) == .holdEnd)
    #expect(interp.keyUp(at: 2.1) == nil)  // no duplicate
}

@Test func exactlyAtTheThresholdCountsAsAHold() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    #expect(interp.elapsedCheck(at: 0.4) == .holdStart)
}

@Test func elapsedCheckOnlyFiresOncePerPress() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    #expect(interp.elapsedCheck(at: 0.5) == .holdStart)
    #expect(interp.elapsedCheck(at: 0.6) == nil)
}

@Test func releaseWithoutPressIsIgnored() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyUp(at: 1.0) == nil)
}

@Test func aSlowReleaseWithoutAnElapsedCheckStillCountsAsAHold() {
    // The timer may not have fired; the release itself must still classify.
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    #expect(interp.keyUp(at: 1.5) == .holdEnd)
}

@Test func twoTapsInSequenceBothRegister() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    _ = interp.keyDown(at: 0)
    #expect(interp.keyUp(at: 0.1) == .tap)
    _ = interp.keyDown(at: 5.0)
    #expect(interp.keyUp(at: 5.1) == .tap)
}

// This test deliberately omits an explicit `holdThreshold:` argument, unlike
// the nine above — it exercises the default, which HotkeyMonitor also relies
// on indirectly by sleeping for `HotkeyInterpreter.holdThreshold`. If the two
// ever diverge back into separate literals, this is the test that would
// silently stop meaning what it says.
@Test func defaultInterpreterUsesTheSharedHoldThresholdConstant() {
    var interp = HotkeyInterpreter()
    _ = interp.keyDown(at: 0)
    #expect(interp.elapsedCheck(at: 0.39) == nil)
    #expect(interp.elapsedCheck(at: 0.40) == .holdStart)
}
