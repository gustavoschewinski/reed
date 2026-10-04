import Foundation
import Testing
@testable import MeetingLog

private let utc = TimeZone(identifier: "UTC")!
private let t0 = ISO8601DateFormatter().date(from: "2026-10-02T14:00:00Z")!

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("reed-meetings-\(UUID().uuidString)")
}

private func header(_ offset: TimeInterval, length: TimeInterval, app: String = "Zoom") -> MeetingHeader {
    MeetingHeader(started: t0.addingTimeInterval(offset), ended: t0.addingTimeInterval(offset + length),
                  source: MeetingSource(app: app), mode: .auto)
}

private func line(_ offset: TimeInterval, _ text: String) -> MeetingLine {
    MeetingLine(time: t0.addingTimeInterval(offset), kind: .speech(.others, text))
}

@Test func writerCreatesPrivateDirectoryAndRewritesOnAppend() throws {
    let dir = tempDir()
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    let h = header(0, length: 10)
    try writer.apply([.open(h), .append([line(0, "olá")], ended: h.ended)])
    try writer.apply([.append([line(30, "tchau")], ended: t0.addingTimeInterval(40))])

    let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
    #expect(perms == 0o700)
    let file = try #require(writer.currentFile)
    let filePerms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(filePerms == 0o600)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("ended: 2026-10-02T14:00:40Z"))
    #expect(text.contains("** olá\n"))
    #expect(text.contains("** tchau\n"))
}

@Test func linesArriveOutOfOrderButAreWrittenInTimeOrder() throws {
    // Me and Others are transcribed separately, so a later line from one
    // channel can be appended before an earlier line from the other.
    let dir = tempDir()
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    let h = header(0, length: 60)
    try writer.apply([.open(h), .append([line(0, "one"), line(40, "four")], ended: t0.addingTimeInterval(45))])
    try writer.apply([.append([line(10, "two"), line(40, "five")], ended: t0.addingTimeInterval(45))])
    try writer.apply([.append([line(20, "three")], ended: t0.addingTimeInterval(25))])
    let text = try String(contentsOf: try #require(writer.currentFile), encoding: .utf8)
    let order = ["one", "two", "three", "four", "five"].compactMap { text.range(of: "** \($0)\n")?.lowerBound }
    #expect(order.count == 5)
    #expect(order == order.sorted())
}

@Test func twoSessionsInTheSameMinuteGetDistinctFiles() throws {
    let dir = tempDir()
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    try writer.apply([.open(header(0, length: 5)), .append([line(0, "a")], ended: t0), .close])
    try writer.apply([.open(header(20, length: 5)), .append([line(20, "b")], ended: t0), .close])
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(files == ["2026-10-02_1400_zoom-2.md", "2026-10-02_1400_zoom.md"])
}

@Test func libraryFindsTheMeetingCoveringATimeOrTheNearest() throws {
    let dir = tempDir()
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    try writer.apply([.open(header(0, length: 1800, app: "Zoom")), .close])
    try writer.apply([.open(header(7200, length: 600, app: "Discord")), .close])
    let library = MeetingLibrary(directory: dir, format: MeetingFormat(timeZone: utc))

    #expect(library.meeting(at: t0.addingTimeInterval(900))?.header.source.app == "Zoom")
    #expect(library.meeting(at: t0.addingTimeInterval(6000))?.header.source.app == "Discord")
    #expect(library.list(since: nil, until: nil).map(\.header.source.app) == ["Discord", "Zoom"])
    #expect(library.list(since: t0.addingTimeInterval(3600), until: nil).map(\.header.source.app) == ["Discord"])
}

@Test func libraryRejectsIdsThatEscapeTheDirectory() throws {
    // Create a parent temp dir with meetings as a subdirectory
    let parentDir = FileManager.default.temporaryDirectory.appendingPathComponent("reed-traversal-\(UUID().uuidString)")
    let dir = parentDir.appendingPathComponent("meetings")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Create a VALID meeting file in the parent directory (outside the meetings folder)
    let outsideHeader = header(0, length: 10, app: "Outside")
    let outsideContent = MeetingFormat(timeZone: utc).render(outsideHeader, lines: [line(0, "secret")])
    try outsideContent.write(to: parentDir.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)

    let library = MeetingLibrary(directory: dir)
    #expect(library.transcript(id: "../outside") == nil)
    #expect(library.transcript(id: "a/b") == nil)
    #expect(library.transcript(id: "") == nil)
    #expect(library.transcript(id: "..") == nil)
}

@Test func libraryIgnoresFilesThatAreNotMeetings() throws {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "garbage".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    try Data([0xFF, 0xFE]).write(to: dir.appendingPathComponent("binary.md"))
    try "x".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

    // Create a VALID meeting file with leading dot (should be ignored by all() and transcript())
    let hiddenHeader = header(0, length: 60, app: "Hidden")
    let hiddenContent = MeetingFormat(timeZone: utc).render(hiddenHeader, lines: [line(0, "secret")])
    try hiddenContent.write(to: dir.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)

    let library = MeetingLibrary(directory: dir)
    #expect(library.list(since: nil, until: nil).isEmpty)
    #expect(library.search("garbage", since: nil, limit: 10).isEmpty)
    #expect(library.purge(endedBefore: .distantFuture) == 0)
    #expect(library.transcript(id: ".hidden") == nil)
}

@Test func searchIsCaseAndAccentInsensitive() throws {
    let dir = tempDir()
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    try writer.apply([.open(header(0, length: 60)), .append([line(0, "Vamos fazer o Deploy amanhã")], ended: t0), .close])
    let hits = MeetingLibrary(directory: dir).search("DEPLOY AMANHA", since: nil, limit: 10)
    #expect(hits.count == 1)
    #expect(hits.first?.line.contains("Deploy amanhã") == true)
}

@Test func doubleDotFilenamesAreReadableAndListable() throws {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Create a valid meeting file with double-dots in the name
    let header = MeetingHeader(started: t0, ended: t0.addingTimeInterval(60), source: MeetingSource(app: "Test"), mode: .auto)
    let content = MeetingFormat(timeZone: utc).render(header, lines: [line(0, "version check")])
    try content.write(to: dir.appendingPathComponent("notes..v2.md"), atomically: true, encoding: .utf8)

    let library = MeetingLibrary(directory: dir)
    #expect(library.list(since: nil, until: nil).count == 1)
    #expect(library.transcript(id: "notes..v2") != nil)
    #expect(library.transcript(id: "notes..v2")?.contains("version check") == true)
}

@Test func purgeDeletesOnlyOldMeetings() throws {
    let dir = tempDir()
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    try writer.apply([.open(header(0, length: 60, app: "Old")), .close])
    try writer.apply([.open(header(86_400 * 8, length: 60, app: "New")), .close])
    let library = MeetingLibrary(directory: dir)
    #expect(library.purge(endedBefore: t0.addingTimeInterval(86_400)) == 1)
    #expect(library.list(since: nil, until: nil).map(\.header.source.app) == ["New"])
}
