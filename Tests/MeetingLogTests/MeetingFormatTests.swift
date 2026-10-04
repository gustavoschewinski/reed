import Foundation
import Testing
@testable import MeetingLog

private let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Test func rendersFrontmatterAndLines() {
    let format = MeetingFormat(timeZone: saoPaulo)
    let header = MeetingHeader(
        started: date("2026-10-02T17:02:10Z"), ended: date("2026-10-02T17:41:55Z"),
        source: MeetingSource(app: "Google Chrome", title: "Meet – Daily \"sync\""), mode: .auto
    )
    let lines = [
        MeetingLine(time: date("2026-10-02T17:02:10Z"), kind: .speech(.others, "então a gente sobe isso amanhã")),
        MeetingLine(time: date("2026-10-02T17:02:31Z"), kind: .speech(.me, "beleza")),
        MeetingLine(time: date("2026-10-02T17:05:10Z"), kind: .gap(until: date("2026-10-02T17:05:40Z"))),
    ]
    #expect(format.render(header, lines: lines) == """
    ---
    started: 2026-10-02T14:02:10-03:00
    ended: 2026-10-02T14:41:55-03:00
    source: "Google Chrome"
    title: "Meet – Daily \\"sync\\""
    mode: auto
    ---
    **14:02:10 · Others** então a gente sobe isso amanhã
    **14:02:31 · Me** beleza
    **14:05:10** [gap until 14:05:40]

    """)
}

@Test func headerRoundTrips() {
    let format = MeetingFormat(timeZone: saoPaulo)
    let header = MeetingHeader(
        started: date("2026-10-02T17:02:10Z"), ended: date("2026-10-02T17:41:55Z"),
        source: MeetingSource(app: "Zoom", title: nil), mode: .manual
    )
    #expect(format.parseHeader(format.render(header, lines: [])) == header)
}

@Test func parseHeaderRejectsGarbage() {
    let format = MeetingFormat(timeZone: saoPaulo)
    #expect(format.parseHeader("") == nil)
    #expect(format.parseHeader("hello\nworld") == nil)
    #expect(format.parseHeader("---\nstarted: nope\n---\n") == nil)
}

@Test func fileNameUsesLocalTimeAndSlug() {
    let format = MeetingFormat(timeZone: saoPaulo)
    let header = MeetingHeader(
        started: date("2026-10-02T17:02:10Z"), ended: date("2026-10-02T17:02:10Z"),
        source: MeetingSource(app: "Google Chrome", title: "Meet – Reunião Diária"), mode: .auto
    )
    #expect(format.fileName(for: header) == "2026-10-02_1402_google-chrome-meet-reuniao-diaria.md")
}

@Test func slugFoldsAccentsCollapsesAndTruncates() {
    #expect(Slug.make("  Olá, Mundo!! ") == "ola-mundo")
    #expect(Slug.make("***") == "session")
    #expect(Slug.make(String(repeating: "ab ", count: 30), maxLength: 10) == "ab-ab-ab-a")
}

@Test func sameAppWithUnknownTitleContinuesASession() {
    let meet = MeetingSource(app: "Google Chrome", title: "Meet – Daily")
    #expect(MeetingSource(app: "Google Chrome", title: nil).continues(meet))
    #expect(meet.continues(MeetingSource(app: "Google Chrome", title: nil)))
    #expect(!MeetingSource(app: "Google Chrome", title: "YouTube – talk").continues(meet))
    #expect(!MeetingSource(app: "Zoom").continues(meet))
}
