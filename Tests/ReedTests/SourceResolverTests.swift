import Foundation
import MeetingLog
import Testing
@testable import Reed

private let me: pid_t = 100

private func p(_ bundle: String, out: Bool = false, input: Bool = false, pid: pid_t = 1) -> AudioProcess {
    AudioProcess(pid: pid, bundleID: bundle, isRunningOutput: out, isRunningInput: input)
}

private func resolve(_ ps: [AudioProcess], titles: [String: String] = [:]) -> ResolvedSources {
    SourceResolver.resolve(ps, ownPID: me, appName: { $0 }, windowTitle: { titles[$0] })
}

@Test func helperProcessesMapToTheirApp() {
    #expect(SourceResolver.canonicalBundleID("com.google.Chrome.helper") == "com.google.Chrome")
    #expect(SourceResolver.canonicalBundleID("com.google.Chrome.helper.Renderer") == "com.google.Chrome")
    #expect(SourceResolver.canonicalBundleID("com.apple.WebKit.GPU") == "com.apple.Safari")
    #expect(SourceResolver.canonicalBundleID("us.zoom.xos") == "us.zoom.xos")
}

@Test func nothingPlayingAndNoCallIsInPerson() {
    let r = resolve([p("com.google.Chrome")])
    #expect(r.output == nil && r.call == nil)
    #expect(r.current == .inPerson)
}

@Test func reedItselfIsIgnored() {
    let r = resolve([p("app.reed", out: true, input: true, pid: me)])
    #expect(r.output == nil && r.call == nil)
}

@Test func callAppsWinOverBrowsersAndOthers() {
    let r = resolve([p("com.spotify.client", out: true), p("com.google.Chrome.helper", out: true), p("us.zoom.xos", out: true)])
    #expect(r.output == MeetingSource(app: "us.zoom.xos"))
}

@Test func micUseByAnotherAppIsACall() {
    let r = resolve([p("com.google.Chrome.helper", out: true, input: true)], titles: ["com.google.Chrome": "Meet - Daily - Google Chrome"])
    #expect(r.call == MeetingSource(app: "com.google.Chrome", title: "Meet - Daily - Google Chrome"))
    #expect(r.micInUseElsewhere)
    #expect(r.current == r.call)
}

@Test func onlyMeetingLikeBrowserTitlesAreKept() {
    #expect(SourceResolver.meetingTitle("Meet – Daily – Google Chrome") != nil)
    #expect(SourceResolver.meetingTitle("Funny cats - YouTube") != nil)
    #expect(SourceResolver.meetingTitle("Inbox (3) - Gmail") == nil)
    let r = resolve([p("com.google.Chrome.helper", out: true)], titles: ["com.google.Chrome": "Inbox - Gmail"])
    #expect(r.output == MeetingSource(app: "com.google.Chrome", title: nil))
}

@Test func systemDaemonsHoldingTheMicAreNotACall() {
    // macOS's own speech daemon keeps the microphone open all day; it is
    // not a call and must not open Reed's mic in automatic mode.
    let r = SourceResolver.resolve(
        [p("com.apple.CoreSpeech", out: true, input: true), p("com.google.Chrome.helper", out: true)],
        ownPID: me, appName: { $0 }, windowTitle: { _ in nil },
        isUserApp: { $0 != "com.apple.CoreSpeech" }
    )
    #expect(r.call == nil)
    #expect(r.output == MeetingSource(app: "com.google.Chrome"))
}

@Test func bundleIDsMatchKnownAppsRegardlessOfCase() {
    // Arc's helper reports a lowercase bundle ID.
    let r = resolve([p("company.thebrowser.browser.helper", out: true), p("com.spotify.client", out: true)],
                    titles: ["company.thebrowser.browser": "Talk - YouTube"])
    #expect(r.output == MeetingSource(app: "company.thebrowser.browser", title: "Talk - YouTube"))
}

@Test func displayNamesDropInvisibleFormattingCharacters() {
    // WhatsApp's localized name starts with a left-to-right mark (U+200E).
    #expect(SourceResolver.displayName("\u{200E}WhatsApp") == "WhatsApp")
    #expect(SourceResolver.displayName(" Arc ") == "Arc")
}
