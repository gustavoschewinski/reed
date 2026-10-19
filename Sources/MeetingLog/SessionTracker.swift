import Foundation

public enum SessionAction: Sendable, Equatable {
    case open(MeetingHeader)
    case append([MeetingLine], ended: Date)
    case close
}

/// Decides which session each transcribed chunk belongs to. Pure: it emits
/// actions, `MeetingWriter` performs them.
///
/// A chunk from a different source is held back until that source has
/// spoken for `switchHysteresis`; only then does a new session start, with
/// the held chunks as its beginning. If the current source speaks again
/// first, the held chunks were a blip (a notification, a quick tab switch)
/// and go into the current session.
public struct SessionTracker: Sendable {
    public var mode: MeetingMode
    public let silenceTimeout: TimeInterval
    public let switchHysteresis: TimeInterval

    private var current: MeetingSource?
    private var lastSpeech: Date?
    private var pending: [MeetingChunk] = []

    public init(mode: MeetingMode, silenceTimeout: TimeInterval = 300, switchHysteresis: TimeInterval = 30) {
        self.mode = mode
        self.silenceTimeout = silenceTimeout
        self.switchHysteresis = switchHysteresis
    }

    public mutating func ingest(_ chunk: MeetingChunk) -> [SessionAction] {
        var actions: [SessionAction] = []
        if current != nil, let lastSpeech, chunk.start.timeIntervalSince(lastSpeech) > silenceTimeout {
            actions += finish()
        }
        defer { lastSpeech = max(lastSpeech ?? chunk.end, chunk.end) }

        guard let current else {
            return actions + open(with: [chunk])
        }
        if chunk.source.continues(current) {
            actions += flushPending()
            actions.append(.append(chunk.lines, ended: chunk.end))
            return actions
        }
        if let first = pending.first, !chunk.source.continues(first.source) {
            actions += flushPending()
        }
        pending.append(chunk)
        let pendingSpeech = pending.reduce(0) { $0 + $1.speechDuration }
        guard pendingSpeech >= switchHysteresis else { return actions }
        let next = pending
        pending = []
        actions.append(.close)
        self.current = nil
        return actions + open(with: next)
    }

    /// Called periodically; closes a session whose speech stopped long ago,
    /// so the next speech opens a new file even if it comes much later.
    public mutating func tick(now: Date) -> [SessionAction] {
        guard current != nil, let lastSpeech, now.timeIntervalSince(lastSpeech) > silenceTimeout else { return [] }
        return finish()
    }

    /// Ends the current session (manual mode off, Reed quitting, mode change).
    public mutating func finish() -> [SessionAction] {
        guard current != nil else { return [] }
        let actions = flushPending() + [.close]
        current = nil
        lastSpeech = nil
        return actions
    }

    private mutating func open(with chunks: [MeetingChunk]) -> [SessionAction] {
        guard let first = chunks.first, let last = chunks.last else { return [] }
        current = first.source
        let header = MeetingHeader(started: first.start, ended: last.end, source: first.source, mode: mode)
        return [.open(header), .append(chunks.flatMap(\.lines), ended: last.end)]
    }

    private mutating func flushPending() -> [SessionAction] {
        let held = pending
        pending = []
        return held.map { .append($0.lines, ended: $0.end) }
    }
}
