import Foundation

public struct MeetingSummary: Sendable, Equatable {
    /// The file name without `.md`; what `reed-mcp` hands out and takes back.
    public var id: String
    public var header: MeetingHeader
    public var url: URL
}

public struct SearchHit: Sendable, Equatable {
    public var id: String
    public var header: MeetingHeader
    public var line: String
}

/// Read side of the Meetings folder. Anything that isn't a well-formed
/// meeting file is skipped, never an error: the folder is the user's, and
/// they may drop anything in it.
public struct MeetingLibrary: Sendable {
    public let directory: URL
    private let format: MeetingFormat

    public init(directory: URL, format: MeetingFormat = MeetingFormat()) {
        self.directory = directory
        self.format = format
    }

    /// Newest first. `since`/`until` select meetings overlapping that window.
    public func list(since: Date? = nil, until: Date? = nil) -> [MeetingSummary] {
        all()
            .filter { since == nil || $0.header.ended >= since! }
            .filter { until == nil || $0.header.started <= until! }
    }

    public func transcript(id: String) -> String? {
        guard let url = url(for: id) else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8), format.parseHeader(text) != nil else { return nil }
        return text
    }

    /// The meeting in progress at `date`, else the one closest to it.
    public func meeting(at date: Date) -> MeetingSummary? {
        all().min { distance($0.header, date) < distance($1.header, date) }
    }

    public func search(_ query: String, since: Date? = nil, limit: Int = 50) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for meeting in list(since: since) {
            guard let text = try? String(contentsOf: meeting.url, encoding: .utf8) else { continue }
            let body = text.split(separator: "\n").drop { $0 != "---" }.dropFirst().drop { $0 != "---" }.dropFirst()
            for line in body where line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(SearchHit(id: meeting.id, header: meeting.header, line: String(line.prefix(300))))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    @discardableResult
    public func purge(endedBefore cutoff: Date) -> Int {
        var removed = 0
        for meeting in all() where meeting.header.ended < cutoff {
            if (try? FileManager.default.removeItem(at: meeting.url)) != nil { removed += 1 }
        }
        return removed
    }

    private func all() -> [MeetingSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard
                    let text = try? String(contentsOf: url, encoding: .utf8),
                    let header = format.parseHeader(text)
                else { return nil }
                return MeetingSummary(id: String(name.dropLast(3)), header: header, url: url)
            }
            .sorted { $0.header.started > $1.header.started }
    }

    /// Only plain file names inside `directory`; anything that could walk
    /// out of it (`..`, `/`) is refused before touching the disk.
    private func url(for id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.contains(".."), !id.hasPrefix(".") else { return nil }
        return directory.appendingPathComponent("\(id).md")
    }

    private func distance(_ header: MeetingHeader, _ date: Date) -> TimeInterval {
        if date >= header.started && date <= header.ended { return 0 }
        return min(abs(header.started.timeIntervalSince(date)), abs(header.ended.timeIntervalSince(date)))
    }
}
