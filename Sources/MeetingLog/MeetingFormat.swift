import Foundation

/// The on-disk shape of a meeting: YAML-ish frontmatter, then one line per
/// utterance. Kept deliberately simple so a person can read the file and
/// `reed-mcp` can parse it without a YAML library.
public struct MeetingFormat: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func render(_ header: MeetingHeader, lines: [MeetingLine]) -> String {
        var out = "---\n"
        out += "started: \(iso(header.started))\n"
        out += "ended: \(iso(header.ended))\n"
        out += "source: \(quote(header.source.app))\n"
        if let title = header.source.title {
            out += "title: \(quote(title))\n"
        }
        out += "mode: \(header.mode.rawValue)\n"
        out += "---\n"
        for line in lines {
            switch line.kind {
            case .speech(let speaker, let text):
                out += "**\(clock(line.time)) · \(speaker.rawValue)** \(text)\n"
            case .gap(let until):
                out += "**\(clock(line.time))** [gap until \(clock(until))]\n"
            }
        }
        return out
    }

    public func parseHeader(_ text: String) -> MeetingHeader? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next() == "---" else { return nil }
        var fields: [String: String] = [:]
        while let line = lines.next() {
            if line == "---" {
                guard
                    let started = fields["started"].flatMap(parseISO),
                    let ended = fields["ended"].flatMap(parseISO),
                    let app = fields["source"].map(unquote),
                    let mode = fields["mode"].flatMap(MeetingMode.init(rawValue:))
                else { return nil }
                return MeetingHeader(
                    started: started, ended: ended,
                    source: MeetingSource(app: app, title: fields["title"].map(unquote)),
                    mode: mode
                )
            }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return nil
    }

    public func fileName(for header: MeetingHeader) -> String {
        let stamp = formatter("yyyy-MM-dd_HHmm").string(from: header.started)
        let label = [header.source.app, header.source.title].compactMap { $0 }.joined(separator: " ")
        return "\(stamp)_\(Slug.make(label)).md"
    }

    func clock(_ date: Date) -> String {
        formatter("HH:mm:ss").string(from: date)
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func parseISO(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f
    }

    private func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

public enum Slug {
    /// ASCII, lowercase, dash-separated; never empty.
    public static func make(_ text: String, maxLength: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
        }
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "session" : out
    }
}
