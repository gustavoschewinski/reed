import Foundation
import MeetingLog

// reed-mcp: read-only MCP server over stdio for Reed's meeting transcripts.
// `claude mcp add reed -- /Applications/Reed.app/Contents/MacOS/reed-mcp`
let server = MCPServer(library: MeetingLibrary(directory: MeetingPaths.defaultDirectory))
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let response = server.handle(line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
