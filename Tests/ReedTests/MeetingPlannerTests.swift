import Foundation
import Testing
@testable import Reed

private let t0 = Date(timeIntervalSince1970: 0)

// `#expect` can't wrap a mutating call, so each observation is bound first.

@Test func zerosWhileSomethingPlaysForAMinuteLooksBlocked() {
    var w = SilenceWatchdog(threshold: 60)
    let atStart = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0)
    let at59 = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(59))
    let at61 = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(61))
    #expect(!atStart)
    #expect(!at59)
    #expect(at61)
}

@Test func anyRealSampleClearsTheWatchdog() {
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0)
    _ = w.observe(samplesAreSilent: false, someoneIsPlaying: true, now: t0.addingTimeInterval(30))
    let later = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(80))
    #expect(!later)
}

@Test func silenceWithNothingPlayingIsNotSuspicious() {
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: false, now: t0)
    let later = w.observe(samplesAreSilent: true, someoneIsPlaying: false, now: t0.addingTimeInterval(600))
    #expect(!later)
}
