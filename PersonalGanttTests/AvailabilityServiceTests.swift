import Foundation
import Testing
@testable import PersonalGantt

struct AvailabilityServiceTests {
    private let service = AvailabilityService()

    @Test func noFixedEventsUsesWeekdayHours() throws {
        #expect(try ranges([]) == [range(8, 23)])
    }

    @Test func oneEventSplitsActivity() throws {
        #expect(try ranges([event(12, 13)]) == [range(8, 12), range(13, 23)])
    }

    @Test func multipleUnorderedEventsLeaveThreeSlots() throws {
        #expect(try ranges([event(15, 17), event(12, 13)]) == [range(8, 12), range(13, 15), range(17, 23)])
    }

    @Test func overlappingAndDuplicateEventsAreUnited() throws {
        #expect(try ranges([event(12, 14), event(13, 15), event(12, 14)]) == [range(8, 12), range(15, 23)])
    }

    @Test func adjacentEventsAreUnited() throws {
        #expect(try ranges([event(12, 13), event(13, 14)]) == [range(8, 12), range(14, 23)])
    }

    @Test func eventsOutsideActivityDoNotConsumeTime() throws {
        #expect(try ranges([event(5, 7), event(23, 24)]) == [range(8, 23)])
    }

    @Test func boundaryCrossingEventsAreClipped() throws {
        #expect(try ranges([event(7, 9), event(22, 24)]) == [range(9, 22)])
    }

    @Test func overnightEventOccupiesBothDays() throws {
        let busy = FixedEvent(id: "overnight", calendarID: "work", title: "夜間", start: date(22), end: date(10, day: 6))
        #expect(try ranges([busy], days: 2) == [range(8, 22), range(10, 23, day: 6)])
    }

    @Test func allDayEndIsExclusive() throws {
        let busy = FixedEvent(id: "all-day", calendarID: "work", title: "終日", start: date(0), end: date(0, day: 6), isAllDay: true)
        #expect(try ranges([busy], days: 2) == [range(8, 23, day: 6)])
    }

    @Test func multiDayAllDayEventBlocksEveryCoveredDay() throws {
        let busy = FixedEvent(id: "all-day", calendarID: "work", title: "終日", start: date(0), end: date(0, day: 7), isAllDay: true)
        #expect(try ranges([busy], days: 3) == [range(8, 23, day: 7)])
    }

    @Test func allDayFlagExpandsPartialDayTimestamps() throws {
        var busy = event(12, 13)
        busy.isAllDay = true
        #expect(try ranges([busy]).isEmpty)
    }

    @Test func completelyOccupiedDayHasNoSlots() throws {
        #expect(try ranges([event(8, 23)]).isEmpty)
        #expect(try ranges([event(0, 24)]).isEmpty)
    }

    @Test func cancelledEventsAreIgnored() throws {
        var busy = event(8, 23)
        busy.isCancelled = true
        #expect(try ranges([busy]) == [range(8, 23)])
    }

    @Test func malformedEventsAreIgnored() throws {
        let malformed = [
            event(13, 12), event(12, 12),
            FixedEvent(id: "invalid", calendarID: "work", title: "無効", start: Date(timeIntervalSinceReferenceDate: .nan), end: date(23))
        ]
        #expect(try ranges(malformed) == [range(8, 23)])
    }

    @Test func SaturdayAndSundayUseWeekendHours() throws {
        var settings = ActivitySettings.legacyFixture
        settings.planningDayCount = 3
        let slots = try service.availableSlots(fixedEvents: [], settings: settings, referenceDate: date(0, day: 10), calendar: utc)
        #expect(slots.map { DateInterval(start: $0.start, end: $0.end) } == [
            range(9, 23, day: 10), range(9, 23, day: 11), range(8, 23, day: 12)
        ])
    }

    @Test func defaultHorizonIsFourteenLocalDaysIncludingToday() throws {
        let reference = date(0, day: 6)
        let interval = try service.planningInterval(referenceDate: reference, settings: .legacyFixture, calendar: utc)
        let slots = try service.availableSlots(fixedEvents: [], settings: .legacyFixture, referenceDate: reference, calendar: utc)
        #expect(interval == DateInterval(start: reference, end: date(0, day: 20)))
        #expect(slots.count == 14)
        #expect(slots.last?.end == date(23, day: 19))
    }

    @Test func todayStartsAtCurrentTimeAndClosedDayIsSkipped() throws {
        #expect(try ranges([], reference: date(10, 15)) == [DateInterval(start: date(10, 15), end: date(23))])
        #expect(try ranges([], days: 2, reference: date(23, 30)) == [range(8, 23, day: 6)])
    }

    @Test func settingsCanBeChangedWithoutChangingService() throws {
        var settings = ActivitySettings.legacyFixture
        settings.weekday = ActivityWindow(startMinute: 10 * 60 + 30, endMinute: 1440)
        settings.planningDayCount = 1
        let slots = try service.availableSlots(fixedEvents: [], settings: settings, referenceDate: date(0), calendar: utc)
        #expect(slots.map { DateInterval(start: $0.start, end: $0.end) } == [DateInterval(start: date(10, 30), end: date(0, day: 6))])
    }

    @Test(arguments: [0, 1, 2, 3])
    func invalidActivitySettingsAreRejected(index: Int) {
        var settings = ActivitySettings.legacyFixture
        switch index {
        case 0: settings.planningDayCount = 0
        case 1: settings.weekday = ActivityWindow(startMinute: 23 * 60, endMinute: 8 * 60)
        case 2: settings.weekend.startMinute = -1
        default: settings.weekend.endMinute = 1441
        }
        #expect(throws: AvailabilityError.invalidSettings) {
            try service.availableSlots(fixedEvents: [], settings: settings, referenceDate: date(0), calendar: utc)
        }
    }

    @Test func daylightSavingUsesCalendarDaysRatherThanTwentyFourHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
        let interval = try service.planningInterval(referenceDate: start, settings: .legacyFixture, calendar: calendar)
        let slots = try service.availableSlots(fixedEvents: [], settings: .legacyFixture, referenceDate: start, calendar: calendar)
        #expect(interval.end == end)
        #expect(interval.duration == 14 * 24 * 3600 + 3600)
        #expect(slots.count == 14)
        for slot in slots {
            let weekday = calendar.component(.weekday, from: slot.start)
            #expect(calendar.component(.hour, from: slot.start) == ((weekday == 1 || weekday == 7) ? 9 : 8))
            #expect(calendar.component(.hour, from: slot.end) == 23)
        }
    }

    @Test func eventAndActivityUseInjectedLocalTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        func local(_ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour)))
        }
        var settings = ActivitySettings.legacyFixture
        settings.planningDayCount = 1
        let busy = try FixedEvent(id: "tokyo", calendarID: "work", title: "予定", start: local(12), end: local(13))
        let slots = try service.availableSlots(fixedEvents: [busy], settings: settings, referenceDate: local(0), calendar: calendar)
        #expect(try slots.map { DateInterval(start: $0.start, end: $0.end) } == [DateInterval(start: local(8), end: local(12)), DateInterval(start: local(13), end: local(23))])
    }

    @Test func eventsOutsideFourteenDayRangeHaveNoEffect() throws {
        let original = try service.availableSlots(fixedEvents: [], settings: .legacyFixture, referenceDate: date(0), calendar: utc)
        let outside = [event(8, 23, day: 4), event(8, 23, day: 20)]
        let updated = try service.availableSlots(fixedEvents: outside, settings: .legacyFixture, referenceDate: date(0), calendar: utc)
        #expect(original.map { DateInterval(start: $0.start, end: $0.end) } == updated.map { DateInterval(start: $0.start, end: $0.end) })
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 5) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func event(_ start: Int, _ end: Int, day: Int = 5) -> FixedEvent {
        FixedEvent(id: "\(day)-\(start)-\(end)", calendarID: "work", title: "予定", start: date(start, day: day), end: date(end, day: day))
    }

    private func range(_ start: Int, _ end: Int, day: Int = 5) -> DateInterval {
        DateInterval(start: date(start, day: day), end: date(end, day: day))
    }

    private func ranges(_ events: [FixedEvent], days: Int = 1, reference: Date? = nil) throws -> [DateInterval] {
        var settings = ActivitySettings.legacyFixture
        settings.planningDayCount = days
        return try service.availableSlots(fixedEvents: events, settings: settings, referenceDate: reference ?? date(0), calendar: utc)
            .map { DateInterval(start: $0.start, end: $0.end) }
    }
}
