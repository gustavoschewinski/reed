import CoreAudio
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
