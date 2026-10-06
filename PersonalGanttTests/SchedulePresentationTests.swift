import Foundation
import Testing
@testable import PersonalGantt

struct SchedulePresentationTests {
    @Test func dayOnlyIncludesIntersectingWorkAndSortsItChronologically() throws {
        let value = try snapshot(blocks: [block(2, date(14), date(15)), block(1, date(9), date(10)),
            block(3, date(9, day: 8), date(10, day: 8))])
        #expect(value.blocks.map { $0.source.taskID } == [id(1), id(2)])
        #expect(value.workMinutes == 120)
    }

    @Test func overnightWorkIsClippedAndMinutesAreConservedAcrossDays() throws {
        let original = block(1, date(23, 30), date(1, day: 8))
        let first = try snapshot(blocks: [original])
        let second = try snapshot(on: date(0, day: 8), blocks: [original])
        #expect(first.blocks[0].interval == DateInterval(start: date(23, 30), end: date(0, day: 8)))
        #expect(second.blocks[0].interval == DateInterval(start: date(0, day: 8), end: date(1, day: 8)))
        #expect(first.workMinutes + second.workMinutes == original.durationMinutes)
        #expect(first.blocks[0].source == original && second.blocks[0].source == original)
        #expect(first.blocks[0].id != second.blocks[0].id)
    }

    @Test func midnightEndIsExclusiveAndDoesNotLeakIntoFollowingDay() throws {
        let original = block(1, date(23), date(0, day: 8))
        #expect(try snapshot(on: date(0, day: 8), blocks: [original]).blocks.isEmpty)
        #expect(try snapshot(blocks: [original]).workMinutes == 60)
    }

    @Test func emptyDayRemainsAnEmptyDayRatherThanShowingOtherDays() throws {
        let value = try snapshot(blocks: [block(1, date(9, day: 8), date(10, day: 8))])
        #expect(value.items.isEmpty && value.workMinutes == 0 && value.availableIntervals.isEmpty)
    }

    @Test func invalidIntervalsAreIgnoredWithoutCreatingDisplayItems() throws {
        let value = try snapshot(blocks: [block(1, date(10), date(9)), block(2, date(9), date(9)),
            block(3, Date(timeIntervalSinceReferenceDate: .nan), date(10))])
        #expect(value.items.isEmpty)
        #expect(SchedulePresentation.day(containing: Date(timeIntervalSinceReferenceDate: .nan), calendar: utc) == nil)
    }

    @Test func fixedEventsAreClippedCancelledEventsExcludedAndTitlesNotMerged() throws {
        let first = event("a", date(9), date(11))
        let overlapping = event("b", date(10), date(12))
        let overnight = event("c", date(23, day: 6), date(1))
        var cancelled = event("cancelled", date(0), date(23)); cancelled.isCancelled = true
        let value = try snapshot(events: [overlapping, first, overnight, cancelled])
        #expect(value.events.map { $0.source.id } == ["c", "a", "b"])
        #expect(value.events[0].interval == DateInterval(start: date(0), end: date(1)))
        #expect(value.events.map { $0.source.title } == ["c", "a", "b"])
    }

    @Test func allDayUsesSameFullDayOccupationAsAvailabilityAndExclusiveEnd() throws {
        var allDay = event("holiday", date(10), date(18)); allDay.isAllDay = true
        let value = try snapshot(events: [allDay])
        #expect(value.events[0].interval == value.day.interval)
        let placement = try #require(GanttPlacement.of(value.events[0].interval, in: value.day))
        #expect(placement.startFraction == 0 && placement.lengthFraction == 1)
        allDay.start = date(0); allDay.end = date(0, day: 8)
        #expect(try snapshot(on: date(0, day: 8), events: [allDay]).events.isEmpty)
    }

    @Test func timelineTiesHaveStableOrderingAndDifferentEventWorkIdentities() throws {
        let value = try snapshot(blocks: [block(2, date(9), date(10)), block(1, date(9), date(10))],
                                 events: [event("b", date(9), date(10)), event("a", date(9), date(10))])
        #expect(value.items.map(\.id) == [
            .event(value.events[0].id), .event(value.events[1].id), .work(value.blocks[0].id), .work(value.blocks[1].id)
        ])
        #expect(Set(value.items.map(\.id)).count == 4)
    }

    @Test func availabilityClipsToTheDayAndIsSeparateFromAssignedWork() throws {
        let value = try snapshot(blocks: [block(1, date(9), date(10))],
            slots: [AvailableSlot(start: date(23, day: 6), end: date(12)), AvailableSlot(start: date(23), end: date(2, day: 8))])
        #expect(value.availableIntervals == [DateInterval(start: date(0), end: date(12)), DateInterval(start: date(23), end: date(0, day: 8))])
        #expect(value.blocks.count == 1 && value.workMinutes == 60)
    }

    @Test func ganttUsesStartEndDatesAndClipsBothSides() throws {
        let day = try #require(SchedulePresentation.day(containing: date(0), calendar: utc))
        let position = try #require(GanttPlacement.of(DateInterval(start: date(12), end: date(13)), in: day))
        #expect(position.startFraction == 0.5)
        #expect(abs(position.lengthFraction - 1.0 / 24) < 0.000001)
        let crossing = try #require(GanttPlacement.of(DateInterval(start: date(23, day: 6), end: date(1)), in: day))
        #expect(crossing.startFraction == 0 && abs(crossing.lengthFraction - 1.0 / 24) < 0.000001)
        #expect(GanttPlacement.of(DateInterval(start: date(0, day: 8), end: date(1, day: 8)), in: day) == nil)
    }

    @Test func subminuteBlocksRetainTheirActualWidthAndDuration() throws {
        let original = block(1, date(9), date(9).addingTimeInterval(30))
        let value = try snapshot(blocks: [original])
        #expect(value.workMinutes == 0.5)
        let position = try #require(GanttPlacement.of(value.blocks[0].interval, in: value.day))
        #expect(abs(position.lengthFraction - 30.0 / 86400) < 0.000001)
    }

    @Test func timePositionHasExclusiveEndAndDoesNotInferActualCompletion() {
        let original = block(1, date(9), date(10))
        #expect(BlockTimePosition.of(original, now: date(8)) == .future)
        #expect(BlockTimePosition.of(original, now: date(9)) == .current)
        #expect(BlockTimePosition.of(original, now: date(9, 59)) == .current)
        #expect(BlockTimePosition.of(original, now: date(10)) == .past)
    }

    @Test func planningDaysIncludeEmptyDaysAndExcludeRangeEnd() {
        let days = SchedulePresentation.days(in: DateInterval(start: date(0), end: date(0, day: 21)), calendar: utc)
        #expect(days.count == 14 && days.first?.id == date(0) && days.last?.id == date(0, day: 20))
    }

    @Test(arguments: [(2026, 3, 8, 23), (2026, 11, 1, 25)])
    func dstDaysUseActualLengthAndWallClockBoundaries(_ year: Int, _ month: Int, _ dayNumber: Int, _ hours: Int) throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = try #require(local.date(from: DateComponents(year: year, month: month, day: dayNumber)))
        let day = try #require(SchedulePresentation.day(containing: start, calendar: local))
        #expect(day.interval.duration == Double(hours) * 3600)
        let noon = try #require(local.date(bySettingHour: 12, minute: 0, second: 0, of: start))
        let end = try #require(local.date(byAdding: .hour, value: 1, to: noon))
        let position = try #require(GanttPlacement.of(DateInterval(start: noon, end: end), in: day))
        #expect(abs(position.lengthFraction - 1.0 / Double(hours)) < 0.000001)
        #expect(abs(position.startFraction - noon.timeIntervalSince(start) / day.interval.duration) < 0.000001)
        let rangeEnd = try #require(local.date(byAdding: .day, value: 14, to: start))
        let days = SchedulePresentation.days(in: DateInterval(start: start, end: rangeEnd), calendar: local)
        #expect(days.count == 14 && days[1].id == day.interval.end)
    }

    @Test func localTimezoneDeterminesWhichDayContainsWork() throws {
        var tokyo = utc; tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let original = block(1, date(16), date(17)) // Oct 8, 01:00–02:00 in Tokyo.
        let localToday = try #require(SchedulePresentation.snapshot(on: date(0), blocks: [original], events: [], slots: [], calendar: tokyo))
        let localTomorrow = try #require(SchedulePresentation.snapshot(on: date(16), blocks: [original], events: [], slots: [], calendar: tokyo))
        #expect(localToday.blocks.isEmpty && localTomorrow.blocks.count == 1)
    }

    private var utc: Calendar { ReminderFixtures.calendar }
    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date { ReminderFixtures.date(hour, minute, day: day) }
    private func id(_ value: Int) -> UUID { ReminderFixtures.id(value) }
    private func block(_ value: Int, _ start: Date, _ end: Date) -> ScheduledBlock { ScheduledBlock(taskID: id(value), start: start, end: end) }
    private func event(_ value: String, _ start: Date, _ end: Date) -> FixedEvent { FixedEvent(id: value, calendarID: "synthetic", title: value, start: start, end: end) }
    private func snapshot(on date: Date = ReminderFixtures.date(0), blocks: [ScheduledBlock] = [], events: [FixedEvent] = [], slots: [AvailableSlot] = []) throws -> DaySchedule {
        try #require(SchedulePresentation.snapshot(on: date, blocks: blocks, events: events, slots: slots, calendar: utc))
    }
}
