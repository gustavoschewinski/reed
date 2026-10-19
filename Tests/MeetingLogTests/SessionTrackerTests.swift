import Foundation
import Testing
@testable import MeetingLog

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let meet = MeetingSource(app: "Google Chrome", title: "Meet – Daily")
private let youtube = MeetingSource(app: "Google Chrome", title: "YouTube – Talk")
private let zoom = MeetingSource(app: "zoom.us")

private func chunk(_ source: MeetingSource, at offset: TimeInterval, length: TimeInterval = 10, text: String = "x") -> MeetingChunk {
    let start = t0.addingTimeInterval(offset)
    return MeetingChunk(
        source: source, start: start, end: start.addingTimeInterval(length),
        lines: [MeetingLine(time: start, kind: .speech(.others, text))]
    )
}

@Test func firstChunkOpensASession() {
    var tracker = SessionTracker(mode: .auto)
    let c = chunk(meet, at: 0)
    #expect(tracker.ingest(c) == [
        .open(MeetingHeader(started: c.start, ended: c.end, source: meet, mode: .auto)),
        .append(c.lines, ended: c.end),
    ])
}

@Test func sameSourceAppends() {
    var tracker = SessionTracker(mode: .auto)
    _ = tracker.ingest(chunk(meet, at: 0))
    let c = chunk(meet, at: 20)
    #expect(tracker.ingest(c) == [.append(c.lines, ended: c.end)])
}

@Test func untitledTabOfTheSameAppDoesNotSplit() {
    var tracker = SessionTracker(mode: .auto)
    _ = tracker.ingest(chunk(meet, at: 0))
    let gmail = chunk(MeetingSource(app: "Google Chrome", title: nil), at: 20, length: 60)
    #expect(tracker.ingest(gmail) == [.append(gmail.lines, ended: gmail.end)])
}

@Test func shortBlipFromAnotherSourceStaysInTheCurrentSession() {
    var tracker = SessionTracker(mode: .auto)
    _ = tracker.ingest(chunk(meet, at: 0))
    let blip = chunk(youtube, at: 15, length: 5, text: "blip")
    #expect(tracker.ingest(blip) == [])
    let back = chunk(meet, at: 25)
    #expect(tracker.ingest(back) == [
        .append(blip.lines, ended: blip.end),
        .append(back.lines, ended: back.end),
    ])
}

@Test func thirtySecondsFromANewSourceStartsANewSession() {
    var tracker = SessionTracker(mode: .auto)
    _ = tracker.ingest(chunk(meet, at: 0))
    let a = chunk(zoom, at: 20, length: 15)
    #expect(tracker.ingest(a) == [])
    let b = chunk(zoom, at: 35, length: 15)
    #expect(tracker.ingest(b) == [
        .close,
        .open(MeetingHeader(started: a.start, ended: b.end, source: zoom, mode: .auto)),
        .append(a.lines + b.lines, ended: b.end),
    ])
}

@Test func fiveMinutesOfSilenceStartsANewSession() {
    var tracker = SessionTracker(mode: .auto)
    _ = tracker.ingest(chunk(meet, at: 0, length: 10))
    let later = chunk(meet, at: 10 + 301)
    #expect(tracker.ingest(later) == [
        .close,
        .open(MeetingHeader(started: later.start, ended: later.end, source: meet, mode: .auto)),
        .append(later.lines, ended: later.end),
    ])
}

@Test func tickClosesAfterSilenceAndFlushesPending() {
    var tracker = SessionTracker(mode: .auto)
    _ = tracker.ingest(chunk(meet, at: 0))
    let blip = chunk(youtube, at: 15, length: 5)
    _ = tracker.ingest(blip)
    #expect(tracker.tick(now: t0.addingTimeInterval(100)) == [])
    #expect(tracker.tick(now: t0.addingTimeInterval(20 + 301)) == [
        .append(blip.lines, ended: blip.end), .close,
    ])
}

@Test func finishFlushesAndCloses() {
    var tracker = SessionTracker(mode: .manual)
    _ = tracker.ingest(chunk(MeetingSource.inPerson, at: 0))
    #expect(tracker.finish() == [.close])
    #expect(tracker.finish() == [])
}
