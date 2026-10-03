import Foundation

public enum MeetingPaths {
    /// `~/Library/Application Support/Reed/Meetings`. Shared by the app
    /// and reed-mcp; neither is sandboxed, so both resolve the same path.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reed", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }
}
