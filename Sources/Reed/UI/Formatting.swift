import Foundation

/// Shared formatting for the main window: the dashboard's hero figures and
/// history's row metadata both need duration and relative-date strings, so
/// they live here once instead of being duplicated per view.
enum DurationFormat {
    /// "2h 14m", "6m 40s", or "12s" — at most two units, and never more
    /// precision than the underlying estimate actually has.
    static func short(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}

/// `RelativeDateTimeFormatter` is a plain `Foundation.Formatter`, not
/// `Sendable` — under Swift 6 strict concurrency a shared instance needs an
/// isolation domain. This is only ever read from SwiftUI view bodies, so
/// `@MainActor` is the natural (and cheapest) one, rather than reaching for
/// `nonisolated(unsafe)` on a mutable class instance.
@MainActor
enum RelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func string(from date: Date, relativeTo now: Date = .now) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }
}
