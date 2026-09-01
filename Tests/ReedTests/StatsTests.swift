import Foundation
import Testing
@testable import Reed

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func day(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")!
    return f.date(from: iso)!
}

private func item(_ iso: String, words: Int = 100, duration: Double = 60) -> StatsInput {
    StatsInput(createdAt: day(iso), durationSeconds: duration, wordCount: words)
}

@Test func timeSavedIsTypingTimeMinusSpeakingTime() {
    // 120 words at 40 wpm would take 180s to type; spoken in 60s.
    #expect(Stats.timeSaved(wordCount: 120, durationSeconds: 60) == 120)
}

@Test func timeSavedIsNegativeWhenSpeakingIsSlowerThanTyping() {
    // 10 words would take 15s to type, but took 60s to say.
    #expect(Stats.timeSaved(wordCount: 10, durationSeconds: 60) == -45)
}

@Test func totalTimeSavedClampsAtZero() {
    let items = [item("2026-08-31T10:00:00Z", words: 1, duration: 600)]
    #expect(Stats.totalTimeSaved(items) == 0)
}

@Test func totalTimeSavedSumsAcrossTranscripts() {
    let items = [
        item("2026-08-31T10:00:00Z", words: 120, duration: 60),
        item("2026-08-31T11:00:00Z", words: 120, duration: 60),
    ]
    #expect(Stats.totalTimeSaved(items) == 240)
}

@Test func streakCountsConsecutiveDaysEndingToday() {
    let items = [
        item("2026-08-31T10:00:00Z"),
        item("2026-08-30T10:00:00Z"),
        item("2026-08-29T10:00:00Z"),
    ]
    #expect(Stats.currentStreak(items, now: day("2026-08-31T23:00:00Z"), calendar: utc) == 3)
}

@Test func streakSurvivesWhenTodayIsEmptyButYesterdayIsNot() {
    let items = [item("2026-08-30T10:00:00Z"), item("2026-08-29T10:00:00Z")]
    #expect(Stats.currentStreak(items, now: day("2026-08-31T09:00:00Z"), calendar: utc) == 2)
}

@Test func streakBreaksAfterATwoDayGap() {
    let items = [item("2026-08-31T10:00:00Z"), item("2026-08-28T10:00:00Z")]
    #expect(Stats.currentStreak(items, now: day("2026-08-31T23:00:00Z"), calendar: utc) == 1)
}

@Test func streakIsZeroWithNoTranscripts() {
    #expect(Stats.currentStreak([], now: day("2026-08-31T23:00:00Z"), calendar: utc) == 0)
}

@Test func multipleTranscriptsInOneDayCountAsOneStreakDay() {
    let items = [item("2026-08-31T08:00:00Z"), item("2026-08-31T20:00:00Z")]
    #expect(Stats.currentStreak(items, now: day("2026-08-31T23:00:00Z"), calendar: utc) == 1)
}

@Test func dailyWordCountsIsOldestFirstAndPadsEmptyDays() {
    let items = [
        item("2026-08-31T10:00:00Z", words: 5),
        item("2026-08-29T10:00:00Z", words: 7),
    ]
    let counts = Stats.dailyWordCounts(
        items, days: 3, now: day("2026-08-31T23:00:00Z"), calendar: utc
    )
    #expect(counts == [7, 0, 5])
}
