import Foundation

/// A transcript reduced to just the fields the dashboard needs.
struct StatsInput: Sendable, Equatable {
    let createdAt: Date
    let durationSeconds: Double
    let wordCount: Int
}

enum Stats {
    /// Average sustained typing speed. Dictation is compared against this to
    /// estimate time saved; it is an assumption, not a measurement.
    static let typingWordsPerMinute = 40.0

    static func timeSaved(wordCount: Int, durationSeconds: Double) -> Double {
        (Double(wordCount) / typingWordsPerMinute) * 60.0 - durationSeconds
    }

    static func totalTimeSaved(_ items: [StatsInput]) -> Double {
        let total = items.reduce(0.0) {
            $0 + timeSaved(wordCount: $1.wordCount, durationSeconds: $1.durationSeconds)
        }
        return max(0, total)
    }

    static func currentStreak(_ items: [StatsInput], now: Date, calendar: Calendar) -> Int {
        let activeDays = Set(items.map { calendar.startOfDay(for: $0.createdAt) })
        guard !activeDays.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)

        // A streak may end today or yesterday — the user has not necessarily
        // dictated yet today, and that should not zero out their run.
        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  activeDays.contains(yesterday)
            else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// Word totals per day, oldest first, always exactly `days` long.
    static func dailyWordCounts(
        _ items: [StatsInput], days: Int, now: Date, calendar: Calendar
    ) -> [Int] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)

        var totals: [Date: Int] = [:]
        for item in items {
            let key = calendar.startOfDay(for: item.createdAt)
            totals[key, default: 0] += item.wordCount
        }

        return (0..<days).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return totals[d] ?? 0
        }
    }
}
