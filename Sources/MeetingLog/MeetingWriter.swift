import Foundation

/// Performs `SessionTracker`'s actions on disk. The whole file is rewritten
/// atomically on every append: it keeps `ended` in the frontmatter true,
/// a crash can never leave half a line, and an hour of meeting is ~60 KB.
public final class MeetingWriter {
    public let directory: URL
    private let format: MeetingFormat
    private var open: (url: URL, header: MeetingHeader, lines: [MeetingLine])?

    public init(directory: URL, format: MeetingFormat = MeetingFormat()) {
        self.directory = directory
        self.format = format
    }

    public var currentFile: URL? { open?.url }

    public func apply(_ actions: [SessionAction]) throws {
        for action in actions {
            switch action {
            case .open(let header):
                try prepareDirectory()
                open = (uniqueURL(for: header), header, [])
                try flush()
            case .append(let lines, let ended):
                guard var session = open else { continue }
                session.lines += lines
                session.header.ended = max(session.header.ended, ended)
                open = session
                try flush()
            case .close:
                open = nil
            }
        }
    }

    private func flush() throws {
        guard let open else { return }
        try Data(format.render(open.header, lines: open.lines).utf8).write(to: open.url, options: .atomic)
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func uniqueURL(for header: MeetingHeader) -> URL {
        let name = format.fileName(for: header)
        let base = String(name.dropLast(3))
        var url = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return url
    }
}
