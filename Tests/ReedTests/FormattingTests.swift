import Testing
@testable import Reed

@Test func durationFormatUsesSecondsOnlyUnderAMinute() {
    #expect(DurationFormat.short(12) == "12s")
}

@Test func durationFormatUsesMinutesAndSecondsUnderAnHour() {
    #expect(DurationFormat.short(6 * 60 + 40) == "6m 40s")
}

@Test func durationFormatUsesHoursAndMinutesAtAnHourOrMore() {
    #expect(DurationFormat.short(2 * 3600 + 14 * 60) == "2h 14m")
}

@Test func durationFormatDropsSecondsOnceMinutesAreShown() {
    // Two units max: "2h 14m", never "2h 14m 30s".
    #expect(DurationFormat.short(2 * 3600 + 14 * 60 + 30) == "2h 14m")
}

@Test func durationFormatRoundsToTheNearestSecond() {
    #expect(DurationFormat.short(11.6) == "12s")
}

@Test func durationFormatClampsNegativeInputToZero() {
    #expect(DurationFormat.short(-5) == "0s")
}
