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

// MARK: - .toggle mode

/// The whole point of the mode: a press held well past what used to be the
/// tap/hold threshold must still be a single toggle, not a hold.
@Test func toggleModeATwoSecondPressStillYieldsExactlyOneToggleAndNoHoldEvents() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .toggle) == .tap)
    // Even if a timer somehow still fired mid-hold, .toggle must not turn
    // that into a .holdStart.
    #expect(interp.elapsedCheck(at: 0.5, mode: .toggle) == nil)
    #expect(interp.keyUp(at: 2.0, mode: .toggle) == nil)
}

@Test func toggleModeAQuickTapAlsoYieldsExactlyOneToggle() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .toggle) == .tap)
    #expect(interp.keyUp(at: 0.05, mode: .toggle) == nil)
}

@Test func toggleModeTwoPressesInSequenceBothToggle() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .toggle) == .tap)
    #expect(interp.keyUp(at: 0.1, mode: .toggle) == nil)
    #expect(interp.keyDown(at: 5, mode: .toggle) == .tap)
    #expect(interp.keyUp(at: 5.1, mode: .toggle) == nil)
}

// MARK: - .holdToTalk mode

/// The whole point of the mode: even a press well under the tap/hold
/// threshold must still start and stop, never toggle.
@Test func holdToTalkModeA100msPressStillStartsAndStops() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .holdToTalk) == .holdStart)
    #expect(interp.keyUp(at: 0.1, mode: .holdToTalk) == .holdEnd)
}

@Test func holdToTalkModeNeverToggles() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .holdToTalk) == .holdStart)
    #expect(interp.keyUp(at: 0.05, mode: .holdToTalk) == .holdEnd)
    #expect(interp.keyDown(at: 1, mode: .holdToTalk) == .holdStart)
    #expect(interp.keyUp(at: 1.05, mode: .holdToTalk) == .holdEnd)
}

@Test func holdToTalkModeDoesNotNeedAnElapsedCheckToStart() {
    // Unlike .automatic, .holdToTalk never relies on the timer-driven
    // elapsedCheck — the monitor should never even schedule it in this
    // mode, but the interpreter itself must not depend on that call either.
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .holdToTalk) == .holdStart)
    #expect(interp.elapsedCheck(at: 0.5, mode: .holdToTalk) == nil)
    #expect(interp.keyUp(at: 2.0, mode: .holdToTalk) == .holdEnd)
}

// MARK: - .automatic mode discriminates from the other two

/// Proves .automatic still behaves exactly as it always did: a quick tap
/// yields .tap (like .toggle would), a long hold yields .holdStart then
/// .holdEnd (like .holdToTalk would) — the mode parameter defaults to this
/// case, so passing it explicitly here is what proves the three modes are
/// actually distinguished, not that any single one happens to work.
@Test func automaticModeAQuickPressIsATapNotAToggleOrAHoldStart() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .automatic) == nil)
    #expect(interp.keyUp(at: 0.1, mode: .automatic) == .tap)
}

@Test func automaticModeALongHoldStartsAndEndsAsPushToTalk() {
    var interp = HotkeyInterpreter(holdThreshold: .milliseconds(400))
    #expect(interp.keyDown(at: 0, mode: .automatic) == nil)
    #expect(interp.elapsedCheck(at: 0.5, mode: .automatic) == .holdStart)
    #expect(interp.keyUp(at: 2.0, mode: .automatic) == .holdEnd)
}
