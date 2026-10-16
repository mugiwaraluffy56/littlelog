import Foundation
import Testing
@testable import littlelog

struct DayKeyTests {
    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test func formatsLocalCalendarDay() throws {
        let key = DayKey.make(for: try date("2026-10-16T12:00:00Z"), calendar: try calendar("UTC"))
        #expect(key == "2026-10-16")
    }

    @Test func usesLocalTimeZoneNotUTC() throws {
        // 23:30 UTC is already the next morning in Kolkata and still the same evening in Los Angeles.
        let instant = try date("2026-10-16T23:30:00Z")
        #expect(DayKey.make(for: instant, calendar: try calendar("Asia/Kolkata")) == "2026-10-17")
        #expect(DayKey.make(for: instant, calendar: try calendar("America/Los_Angeles")) == "2026-10-16")
    }

    @Test func midnightBoundary() throws {
        let tz = try calendar("Asia/Kolkata")
        #expect(DayKey.make(for: try date("2026-10-16T18:29:59Z"), calendar: tz) == "2026-10-16")
        #expect(DayKey.make(for: try date("2026-10-16T18:30:00Z"), calendar: tz) == "2026-10-17")
    }

    @Test func daylightSavingTransitionKeepsDays() throws {
        // US clocks fall back on 2026-11-01; the 25-hour day still yields one key.
        let tz = try calendar("America/New_York")
        #expect(DayKey.make(for: try date("2026-11-01T04:30:00Z"), calendar: tz) == "2026-11-01")
        #expect(DayKey.make(for: try date("2026-11-02T04:59:00Z"), calendar: tz) == "2026-11-01")
        #expect(DayKey.make(for: try date("2026-11-02T05:00:00Z"), calendar: tz) == "2026-11-02")
    }
}
