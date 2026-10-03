import Foundation
import MeetingLog

struct AudioProcess: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool
    var isRunningInput: Bool
}

struct ResolvedSources: Equatable, Sendable {
    /// The app most likely producing what the system tap hears.
    var output: MeetingSource?
    /// Another app holding the microphone: the user is in a call.
    var call: MeetingSource?

    var micInUseElsewhere: Bool { call != nil }
    /// One label for everything captured right now, Me and Others alike,
    /// so both sides of a call land in the same session.
    var current: MeetingSource { call ?? output ?? .inPerson }
}

enum SourceResolver {
    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.FaceTime",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    /// Window titles worth naming a session after. Anything else (Gmail,
    /// Docs, …) is dropped, which `MeetingSource.continues` treats as
    /// "same session" — so tabbing away mid-call never splits it.
    static let meetingTitleMarkers = ["meet", "youtube", "zoom", "teams", "discord", "whereby", "jitsi", "twitch", "webex"]

    static func canonicalBundleID(_ id: String) -> String {
        if id.hasPrefix("com.apple.WebKit.") { return "com.apple.Safari" }
        if let range = id.range(of: ".helper") { return String(id[..<range.lowerBound]) }
        return id
    }

    static func meetingTitle(_ title: String) -> String? {
        let lower = title.lowercased()
        return meetingTitleMarkers.contains(where: lower.contains) ? title : nil
    }

    /// `isUserApp` filters out system daemons: macOS's own speech service
    /// (`com.apple.CoreSpeech`) holds the microphone all day, which is not a
    /// call and must not open Reed's mic in automatic mode.
    static func resolve(
        _ processes: [AudioProcess], ownPID: pid_t,
        appName: (String) -> String, windowTitle: (String) -> String?,
        isUserApp: (String) -> Bool = { _ in true }
    ) -> ResolvedSources {
        let others = processes.filter { $0.pid != ownPID && isUserApp(canonicalBundleID($0.bundleID)) }
        func source(for bundle: String) -> MeetingSource {
            let title = isBrowser(bundle) ? windowTitle(bundle).flatMap(meetingTitle) : nil
            return MeetingSource(app: appName(bundle), title: title)
        }
        func best(_ list: [AudioProcess]) -> String? {
            list.map { canonicalBundleID($0.bundleID) }.min { rank($0) < rank($1) }
        }
        let output = best(others.filter(\.isRunningOutput)).map(source)
        let call = best(others.filter(\.isRunningInput)).map(source)
        return ResolvedSources(output: output, call: call)
    }

    private static func rank(_ bundle: String) -> Int {
        if callApps.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) { return 0 }
        if isBrowser(bundle) { return 1 }
        return 2
    }

    /// Bundle IDs are compared ignoring case: helper processes don't always
    /// report the app's own capitalization (Arc's is all lowercase).
    private static func isBrowser(_ bundle: String) -> Bool {
        browsers.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame })
    }
}
