import Foundation
import Testing
@testable import MeetingLog

private let utc = TimeZone(identifier: "UTC")!
private let t0 = ISO8601DateFormatter().date(from: "2026-10-02T14:00:00Z")!

private func server() throws -> MCPServer {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reed-mcp-\(UUID().uuidString)")
    let writer = MeetingWriter(directory: dir, format: MeetingFormat(timeZone: utc))
    let h = MeetingHeader(started: t0, ended: t0.addingTimeInterval(1800), source: MeetingSource(app: "Zoom"), mode: .auto)
    try writer.apply([.open(h), .append([MeetingLine(time: t0, kind: .speech(.others, "sobe o deploy amanhã"))], ended: h.ended), .close])
    return MCPServer(library: MeetingLibrary(directory: dir, format: MeetingFormat(timeZone: utc)),
                     now: { t0.addingTimeInterval(3 * 3600) }, timeZone: utc)
}

private func call(_ s: MCPServer, _ json: String) throws -> [String: Any] {
    let out = try #require(s.handle(json))
    return try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
}

private func toolText(_ response: [String: Any]) -> String? {
    ((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
}

@Test func initializeAdvertisesTools() throws {
    let r = try call(try server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
    let result = try #require(r["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
}

@Test func notificationsGetNoResponse() throws {
    #expect(try server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
}

@Test func toolsListNamesTheThreeTools() throws {
    let r = try call(try server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String }.sorted() == ["get_meeting", "list_meetings", "search"])
}

@Test func getMeetingAtAClockTimeToday() throws {
    let r = try call(try server(), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"at":"14:10"}}}"#)
    #expect(toolText(r)?.contains("sobe o deploy amanhã") == true)
}

@Test func getMeetingWithATraversalIdIsAToolError() throws {
    let r = try call(try server(), #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"../../etc/passwd"}}}"#)
    #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test func searchFindsText() throws {
    let r = try call(try server(), #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search","arguments":{"query":"deploy"}}}"#)
    #expect(toolText(r)?.contains("deploy") == true)
}

@Test func listMeetingsForADate() throws {
    let r = try call(try server(), #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_meetings","arguments":{"date":"2026-10-02"}}}"#)
    #expect(toolText(r)?.contains("Zoom") == true)
}

@Test func unknownMethodAndBadJSON() throws {
    let s = try server()
    let r = try call(s, #"{"jsonrpc":"2.0","id":7,"method":"nope"}"#)
    #expect((r["error"] as? [String: Any])?["code"] as? Int == -32601)
    let bad = try call(s, "{not json")
    #expect((bad["error"] as? [String: Any])?["code"] as? Int == -32700)
}
