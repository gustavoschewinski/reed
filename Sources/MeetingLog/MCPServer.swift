import Foundation

/// A minimal MCP server over newline-delimited JSON-RPC 2.0: one request
/// line in, at most one response line out. Read-only by construction —
/// it only ever holds a `MeetingLibrary`'s read methods. No SDK dependency:
/// three tools don't justify one, and the binary stays Foundation-only.
public struct MCPServer: Sendable {
    private let library: MeetingLibrary
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let format: MeetingFormat

    public init(library: MeetingLibrary, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.library = library
        self.now = now
        self.timeZone = timeZone
        self.format = MeetingFormat(timeZone: timeZone)
    }

    public func handle(_ line: String) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
            let request = object as? [String: Any],
            let method = request["method"] as? String
        else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]) }

        guard let id = request["id"] else { return nil }  // notification
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "reed", "version": "1.0"],
                "instructions": "Transcripts of the user's meetings and other audio, recorded on their Mac by Reed. Lines marked Me are the user; Others is everything their Mac played.",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch callTool(name, args) {
            case .success(let text):
                return reply(id, ["content": [["type": "text", "text": text]]])
            case .failure(let error):
                return reply(id, ["content": [["type": "text", "text": error.message]], "isError": true])
            }
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    struct ToolError: Error { let message: String }

    private func callTool(_ name: String, _ args: [String: Any]) -> Result<String, ToolError> {
        switch name {
        case "list_meetings":
            var since = (args["since"] as? String).flatMap(parseTime)
            var until = (args["until"] as? String).flatMap(parseTime)
            if let day = (args["date"] as? String).flatMap(parseDay) {
                since = day
                until = day.addingTimeInterval(86_400)
            }
            let meetings = library.list(since: since, until: until)
            guard !meetings.isEmpty else { return .success("No meetings found.") }
            return .success(meetings.map(describe).joined(separator: "\n"))
        case "get_meeting":
            if let id = args["id"] as? String {
                guard let text = library.transcript(id: id) else { return .failure(ToolError(message: "No meeting with id \(id).")) }
                return .success(text)
            }
            guard let at = (args["at"] as? String).flatMap(parseTime) else {
                return .failure(ToolError(message: "Pass `id`, or `at` as HH:mm (today) or an ISO 8601 date-time."))
            }
            guard let meeting = library.meeting(at: at), let text = library.transcript(id: meeting.id) else {
                return .failure(ToolError(message: "No meetings recorded."))
            }
            return .success(text)
        case "search":
            guard let query = args["query"] as? String, !query.isEmpty else { return .failure(ToolError(message: "`query` is required.")) }
            let days = args["days"] as? Int ?? 7
            let hits = library.search(query, since: now().addingTimeInterval(-Double(days) * 86_400), limit: 50)
            guard !hits.isEmpty else { return .success("No matches.") }
            return .success(hits.map { "\($0.id) — \($0.line)" }.joined(separator: "\n"))
        default:
            return .failure(ToolError(message: "Unknown tool \(name)."))
        }
    }

    private func describe(_ m: MeetingSummary) -> String {
        let source = [m.header.source.app, m.header.source.title].compactMap { $0 }.joined(separator: " — ")
        let start = format.clock(m.header.started).prefix(5)
        let end = format.clock(m.header.ended).prefix(5)
        return "\(m.id) | \(start)–\(end) | \(source) | \(m.header.mode.rawValue)"
    }

    /// `HH:mm` means today in the user's time zone; anything else must be ISO 8601.
    private func parseTime(_ s: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: s) { return iso }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now())
    }

    private func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "list_meetings",
            "description": "List recorded meetings/sessions, newest first, with id, local start–end time, source app/title and mode.",
            "inputSchema": ["type": "object", "properties": [
                "date": ["type": "string", "description": "YYYY-MM-DD, local time"],
                "since": ["type": "string", "description": "ISO 8601 or HH:mm today"],
                "until": ["type": "string", "description": "ISO 8601 or HH:mm today"],
            ]],
        ],
        [
            "name": "get_meeting",
            "description": "Full transcript of one meeting, by id or by a time it covered (e.g. \"14:00\" for the meeting at 2pm today).",
            "inputSchema": ["type": "object", "properties": [
                "id": ["type": "string"],
                "at": ["type": "string", "description": "HH:mm today, or ISO 8601"],
            ]],
        ],
        [
            "name": "search",
            "description": "Find lines across recent meetings (case- and accent-insensitive).",
            "inputSchema": ["type": "object", "required": ["query"], "properties": [
                "query": ["type": "string"],
                "days": ["type": "integer", "description": "How far back, default 7"],
            ]],
        ],
    ]
}
