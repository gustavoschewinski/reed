import Testing
@testable import Reed

/// `WindowPolicyTracker` is plain `Foundation` logic (no `AppKit`), so these
/// run with no `@MainActor` isolation, no `NSApp`, and no real windows — the
/// counting rules are exactly what's under test, decoupled from AppKit.

@Test func openingTheFirstWindowSignalsThePromotionToRegular() {
    var tracker = WindowPolicyTracker()
    #expect(tracker.windowDidOpen(.main) == true)
}

@Test func reopeningAnAlreadyOpenWindowDoesNotDoubleCount() {
    var tracker = WindowPolicyTracker()
    #expect(tracker.windowDidOpen(.main) == true)
    // Same kind, already tracked open — must not re-signal a promotion,
    // and (this is the actual double-count risk) must not need two closes
    // to empty the set again.
    #expect(tracker.windowDidOpen(.main) == false)
    #expect(tracker.windowDidClose(.main) == true)
}

@Test func openingASecondDistinctWindowDoesNotReSignalThePromotion() {
    var tracker = WindowPolicyTracker()
    #expect(tracker.windowDidOpen(.main) == true)
    // Onboarding opening while the main window is already up must not
    // claim a fresh zero-to-one transition — the app is regular already.
    #expect(tracker.windowDidOpen(.onboarding) == false)
}

@Test func closingOneOfTwoOpenWindowsDoesNotSignalTheDemotionToAccessory() {
    var tracker = WindowPolicyTracker()
    _ = tracker.windowDidOpen(.main)
    _ = tracker.windowDidOpen(.onboarding)

    // Closing the main window while onboarding is still open must not
    // drop the app back to `.accessory`.
    #expect(tracker.windowDidClose(.main) == false)
}

@Test func closingTheOtherOrderDoesNotSignalTheDemotionEitherWayRound() {
    var tracker = WindowPolicyTracker()
    _ = tracker.windowDidOpen(.main)
    _ = tracker.windowDidOpen(.onboarding)

    // Same as above, but closing onboarding first while main stays open.
    #expect(tracker.windowDidClose(.onboarding) == false)
    // Now closing the last one does signal it.
    #expect(tracker.windowDidClose(.main) == true)
}

@Test func closingTheLastOpenWindowSignalsTheDemotionToAccessory() {
    var tracker = WindowPolicyTracker()
    _ = tracker.windowDidOpen(.main)
    #expect(tracker.windowDidClose(.main) == true)
}

@Test func closingAWindowThatWasNeverTrackedAsOpenIsANoOp() {
    var tracker = WindowPolicyTracker()
    // Nothing open at all — a stray close notification must not crash or
    // spuriously re-signal a demotion that already happened.
    #expect(tracker.windowDidClose(.main) == true)
    #expect(tracker.openWindows.isEmpty)
}

@Test func reopeningAfterAFullCloseSignalsThePromotionAgain() {
    var tracker = WindowPolicyTracker()
    _ = tracker.windowDidOpen(.main)
    _ = tracker.windowDidClose(.main)

    // Mirrors a titlebar close that orders the window out without nil-ing
    // the delegate's reference to it (see `AppDelegate.openMainWindow`) —
    // reopening it must go through the zero-to-one transition again.
    #expect(tracker.windowDidOpen(.main) == true)
}
