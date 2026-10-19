import Foundation

public enum MeetingMode: String, Sendable, Equatable {
    case auto, manual
}

/// Which capture channel a line came from. Not diarization: the mic is
/// "Me", everything the Mac played is "Others".
public enum Speaker: String, Sendable, Equatable {
    case me = "Me"
    case others = "Others"
}

/// Where the audio of a session came from: the app, and for browsers the
/// window title, when it names a call or video (see `SourceResolver`).
public struct MeetingSource: Sendable, Equatable {
    public var app: String
    public var title: String?

    public init(app: String, title: String? = nil) {
        self.app = app
        self.title = title
    }

    /// The mic with nothing on the Mac playing: a conversation in the room.
    public static let inPerson = MeetingSource(app: "In person")

    /// Whether audio from `self` belongs to a session that started from
    /// `other`. A missing title is a wildcard, so tabbing from a Meet call
    /// to Gmail (no recognizable title) keeps the call's session.
    public func continues(_ other: MeetingSource) -> Bool {
        guard app == other.app else { return false }
        guard let title, let otherTitle = other.title else { return true }
        return title == otherTitle
    }
}

public struct MeetingLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case speech(Speaker, String)
        /// Audio that was captured but could not be transcribed.
        case gap(until: Date)
    }

    public var time: Date
    public var kind: Kind

    public init(time: Date, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

public struct MeetingHeader: Sendable, Equatable {
    public var started: Date
    public var ended: Date
    public var source: MeetingSource
    public var mode: MeetingMode

    public init(started: Date, ended: Date, source: MeetingSource, mode: MeetingMode) {
        self.started = started
        self.ended = ended
        self.source = source
        self.mode = mode
    }
}

/// One transcribed stretch of speech, as it reaches the session tracker.
public struct MeetingChunk: Sendable, Equatable {
    public var source: MeetingSource
    public var start: Date
    public var end: Date
    public var lines: [MeetingLine]

    public init(source: MeetingSource, start: Date, end: Date, lines: [MeetingLine]) {
        self.source = source
        self.start = start
        self.end = end
        self.lines = lines
    }

    public var speechDuration: TimeInterval { end.timeIntervalSince(start) }
}
