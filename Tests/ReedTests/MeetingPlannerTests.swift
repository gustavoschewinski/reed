import CoreAudio
import Foundation
import Testing
@testable import Reed

private let t0 = Date(timeIntervalSince1970: 0)

// `#expect` can't wrap a mutating call, so each observation is bound first.

@Test func zerosWhileSomethingPlaysForAMinuteShowsTheNoticeOnce() {
    var w = SilenceWatchdog(threshold: 60)
    let atStart = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0)
    let at59 = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(59))
    let at61 = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(61))
    let at63 = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(63))
    #expect(atStart == nil)
    #expect(at59 == nil)
    #expect(at61 == .show)
    #expect(at63 == nil)
    #expect(w.showing)
}

@Test func onceTheTapHasHeardAudioItNeverTripsAgain() {
    // Browsers report output while silent and a call's far side can be
    // quiet for minutes: after one real sample, permission is proven.
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0)
    _ = w.observe(samplesAreSilent: false, someoneIsPlaying: true, now: t0.addingTimeInterval(30))
    var verdicts: [SilenceNotice?] = []
    for s in stride(from: 32.0, through: 3600, by: 2) {
        verdicts.append(w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(s)))
    }
    #expect(verdicts.allSatisfy { $0 == nil })
}

@Test func silenceWithNothingPlayingIsNotSuspicious() {
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: false, now: t0)
    let later = w.observe(samplesAreSilent: true, someoneIsPlaying: false, now: t0.addingTimeInterval(600))
    #expect(later == nil)
}

@Test func realAudioAfterTheNoticeClearsIt() {
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0)
    let shown = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(61))
    let cleared = w.observe(samplesAreSilent: false, someoneIsPlaying: true, now: t0.addingTimeInterval(63))
    #expect(shown == .show)
    #expect(cleared == .clear)
    #expect(!w.showing)
}

@Test func aRestartedTapKeepsTheNoticeUntilAudioArrives() {
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: false, someoneIsPlaying: true, now: t0)
    w.tapStarted()  // proof is per tap start
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(2))
    let shown = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(63))
    w.tapStarted()
    let stillSilent = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(65))
    let heard = w.observe(samplesAreSilent: false, someoneIsPlaying: true, now: t0.addingTimeInterval(67))
    #expect(shown == .show)
    #expect(stillSilent == nil)
    #expect(heard == .clear)
}

@Test func dismissingTheNoticeShowsItAgainAfterAnotherSilentMinute() {
    var w = SilenceWatchdog(threshold: 60)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0)
    _ = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(61))
    w.dismiss()  // the user's retry: a fresh minute before it shows again
    let soon = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(63))
    let again = w.observe(samplesAreSilent: true, someoneIsPlaying: true, now: t0.addingTimeInterval(125))
    #expect(soon == nil)
    #expect(again == .show)
}

// No hardware: synthetic buffer lists.
private func withList(_ sizes: [UInt32], _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
    let list = AudioBufferList.allocate(maximumBuffers: sizes.count)
    defer { free(list.unsafeMutablePointer) }
    var storage = [UnsafeMutableRawPointer]()
    for (i, size) in sizes.enumerated() {
        let mem = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), 1), alignment: 16)
        storage.append(mem)
        list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: size, mData: mem)
    }
    defer { storage.forEach { $0.deallocate() } }
    body(list)
}

@Test func tapBufferIsTheLastOfTwo() {
    withList([100, 200]) { list in
        #expect(SystemAudioTap.tapBuffer(in: list)?.mDataByteSize == 200)
    }
}

@Test func tapBufferOfOneIsThatBuffer() {
    withList([64]) { list in
        #expect(SystemAudioTap.tapBuffer(in: list)?.mDataByteSize == 64)
    }
}

@Test func emptyTapBufferIsRejected() {
    withList([100, 0]) { list in
        #expect(SystemAudioTap.tapBuffer(in: list) == nil)
    }
}

// MARK: - MeetingPlanner

private func inputs(manual: Bool = false, auto: Bool = false, available: Bool = true, playing: Bool = false,
                    call: Bool = false, dictating: Bool = false) -> CaptureInputs {
    CaptureInputs(manualOn: manual, autoEnabled: auto, systemAudioAvailable: available,
                  somethingPlaying: playing, micInUseElsewhere: call, dictating: dictating)
}

@Test func offCapturesNothing() {
    #expect(MeetingPlanner.plan(inputs(playing: true, call: true)) == CapturePlan(systemTap: false, mic: false))
}

@Test func manualCapturesBothSides() {
    #expect(MeetingPlanner.plan(inputs(manual: true)) == CapturePlan(systemTap: true, mic: true))
}

@Test func autoListensToTheMacOnlyWhileSomethingPlays() {
    #expect(MeetingPlanner.plan(inputs(auto: true)) == CapturePlan(systemTap: false, mic: false))
    #expect(MeetingPlanner.plan(inputs(auto: true, playing: true)) == CapturePlan(systemTap: true, mic: false))
}

@Test func autoOpensTheMicOnlyDuringACall() {
    #expect(MeetingPlanner.plan(inputs(auto: true, playing: true, call: true)) == CapturePlan(systemTap: true, mic: true))
}

@Test func dictationTakesTheMic() {
    #expect(MeetingPlanner.plan(inputs(manual: true, dictating: true)) == CapturePlan(systemTap: true, mic: false))
}

@Test func withoutSystemAudioManualIsMicOnly() {
    #expect(MeetingPlanner.plan(inputs(manual: true, available: false)) == CapturePlan(systemTap: false, mic: true))
}

@Test func autoOpensTheMicForACallEvenWithNothingPlaying() {
    #expect(MeetingPlanner.plan(inputs(auto: true, call: true)) == CapturePlan(systemTap: false, mic: true))
}
