import Foundation
import Testing
@testable import PersonalGantt

struct GoogleEventConversionTests {
    @Test func timedOffsetsAndFractionalSecondsArePreserved() throws {
        let fixed = try #require(try convert(#"{"id":"e","summary":"授業","start":{"dateTime":"2026-10-06T10:00:00.500+09:00"},"end":{"dateTime":"2026-10-06T12:00:00.500+09:00"}}"#))
        #expect(fixed.start == local(6, 10).addingTimeInterval(0.5))
        #expect(fixed.end.timeIntervalSince(fixed.start) == 7200)
        #expect(!fixed.isAllDay)
        #expect(fixed.title == "授業")
    }

    @Test func floatingDateUsesActivityTimeZoneAndEndIsExclusive() throws {
        let fixed = try #require(try convert(#"{"id":"all","start":{"date":"2026-10-06"},"end":{"date":"2026-10-07"}}"#))
        #expect(fixed.start == local(6, 0))
        #expect(fixed.end == local(7, 0))
        #expect(fixed.isAllDay)
        let slots = try AvailabilityService().availableSlots(fixedEvents: [fixed], settings: .legacyFixture, referenceDate: local(6, 0), calendar: tokyo)
        #expect(slots.first?.start == local(7, 8))
    }

    @Test func noOffsetUsesExplicitGoogleTimeZone() throws {
        let fixed = try #require(try convert(#"{"id":"e","start":{"dateTime":"2026-10-06T10:00:00","timeZone":"Asia/Tokyo"},"end":{"dateTime":"2026-10-06T12:00:00","timeZone":"Asia/Tokyo"}}"#))
        #expect(fixed.start == local(6, 10))
        #expect(fixed.end == local(6, 12))
    }

    @Test func cancellationWithoutTimesIsIgnored() throws {
        #expect(try convert(#"{"id":"cancelled-instance","status":"cancelled"}"#) == nil)
    }

    @Test(arguments: [
        #"{"id":"e","start":{"date":"2026-02-30"},"end":{"date":"2026-03-01"}}"#,
        #"{"id":"e","start":{"date":"invalid"},"end":{"date":"2026-10-07"}}"#,
        #"{"id":"e","start":{"dateTime":"bad"},"end":{"dateTime":"2026-10-06T12:00:00Z"}}"#,
        #"{"id":"e","start":{"dateTime":"2026-10-06T12:00:00Z"},"end":{"dateTime":"2026-10-06T10:00:00Z"}}"#,
        #"{"id":"e","start":{"date":"2026-10-06"},"end":{"dateTime":"2026-10-06T12:00:00Z"}}"#,
        #"{"id":"e","start":{"dateTime":"2026-10-06T10:00:00"},"end":{"dateTime":"2026-10-06T12:00:00"}}"#,
        #"{"id":"e"}"#
    ])
    func malformedEventFailsSnapshot(text: String) {
        #expect(throws: GoogleCalendarError.invalidResponse) { try convert(text) }
    }

    @Test func eventIdentityIsStableAndSeparatedByCalendarAndOccurrence() throws {
        let json = #"{"id":"e","start":{"dateTime":"2026-10-06T10:00:00Z"},"end":{"dateTime":"2026-10-06T12:00:00Z"}}"#
        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: Data(json.utf8))
        let first = try event.fixedEvent(calendarID: "a", calendarTimeZone: nil, activityCalendar: tokyo)
        #expect(try event.fixedEvent(calendarID: "a", calendarTimeZone: nil, activityCalendar: tokyo) == first)
        #expect(try event.fixedEvent(calendarID: "b", calendarTimeZone: nil, activityCalendar: tokyo)?.id != first?.id)
    }

    private var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }
    private func local(_ day: Int, _ hour: Int) -> Date {
        tokyo.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func convert(_ text: String) throws -> FixedEvent? {
        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: Data(text.utf8))
        return try event.fixedEvent(calendarID: "synthetic-calendar", calendarTimeZone: nil, activityCalendar: tokyo)
    }
}
