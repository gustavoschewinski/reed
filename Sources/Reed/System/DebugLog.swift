import Foundation

/// A diagnostic log for the dictation pipeline, always compiled in but off
/// by default: it only ever touches disk when `REED_DEBUG_LOG=1` is set in
/// the environment the app was launched from. No rebuild — and so no
/// re-signing, and so no lost microphone grant — is needed to turn it on.
///
/// Foundation-only, no SwiftUI or AppKit import, and no reference to
/// anything under `UI/`: this is what lets `Core/`, `System/`, and `Data/`
/// all call it without breaking the layering rule those directories are
/// held to.
///
/// Diagnostic only, never a transcript store: every call site logs lengths
/// and counts, never the words a user dictated — the log stays safe to
/// share without breaking Reed's "only text you dictate is stored" claim.
enum DebugLog {
    /// Read once, at first use, from the environment the process actually
    /// launched with — matches how `REED_DEBUG_LOG` is meant to be set
    /// (before launch), and avoids re-reading `ProcessInfo` on every call.
    private static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["REED_DEBUG_LOG"] == "1"

    private static let logURL: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Reed/reed-debug.log")

    /// Serializes every append. File writes happen here, off the caller's
    /// thread — `log()` is called from the main actor (`DictationSession`,
    /// `OverlayPanel`), from `StreamingTranscriber`'s actor, and from
    /// `Recorder`'s audio-render thread, none of which should block on
    /// disk I/O or race each other over the same file handle.
    private static let queue = DispatchQueue(label: "com.reed.debuglog")

    /// Appends one timestamped line. A no-op — no directory created, no
    /// file touched, no formatting performed — unless `REED_DEBUG_LOG=1`
    /// was set when the process launched.
    ///
    /// `message` is `@autoclosure` so callers can pass string
    /// interpolation directly; it is still only evaluated when logging is
    /// enabled, so a disabled build never pays for the formatting either.
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let timestamp = Date()
        queue.async {
            append(timestamp: timestamp, text: text)
        }
    }

    /// Runs only on `queue`, so the timestamp format call and the file
    /// handle are never touched by two threads at once.
    private static func append(timestamp: Date, text: String) {
        let line = "\(timestamp.ISO8601Format()) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }

        let directory = logURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
