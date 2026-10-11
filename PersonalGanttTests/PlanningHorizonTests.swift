import Foundation
import Testing
@testable import PersonalGantt

struct PlanningHorizonTests {
    private let resolver = PlanningHorizonResolver()
    private var calendar: Calendar { ReminderFixtures.calendar }
    private var now: Date { ReminderFixtures.date(0) }
    private func day(_ offset: Int, _ hour: Int = 0) -> Date {
        let base = calendar.date(byAdding: .day, value: offset, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }
    private func task(_ deadline: Date, completed: Bool = false) -> PersonalGantt.Task {
        PersonalGantt.Task(title: "合成作業", isCompleted: completed, estimatedMinutes: 60, deadline: deadline)
    }
    private func routine(_ offset: Int) -> Routine {
        Routine(title: "合成英語", estimatedMinutesPerDay: 30, startDate: now, endDate: day(offset), recurrence: .daily)
    }

    @Test func emptyUsesMinimumAndMidnightStart() throws {
        let value = try resolver.resolve(now: day(0, 12), tasks: [], routines: [], calendar: calendar)
        #expect(value == PlanningHorizon(start: now, end: day(14), wasCapped: false))
    }
    @Test(arguments: [7, 14, 30, 89, 90, 120]) func deadlinesExtendAndCap(days: Int) throws {
        let value = try resolver.resolve(now: now, tasks: [task(day(days))], routines: [], calendar: calendar)
        #expect(value.end == day(min(90, max(14, days))))
        #expect(value.wasCapped == (days > 90))
    }
    @Test func exactDeadlineTimeIsPreserved() throws {
        #expect(try resolver.resolve(now: now, tasks: [task(day(30, 15))], routines: [], calendar: calendar).end == day(30, 15))
    }
    @Test func multipleTasksIgnoreCompletionAndGeneratedOccurrences() throws {
        var occurrenceTask = task(day(120))
        occurrenceTask.routineOccurrence = RoutineOccurrence(routineID: UUID(), dayKey: "synthetic", dayStart: day(119), dayEnd: day(120))
        let tasks = [task(day(7)), task(day(30)), task(day(60)), task(day(150), completed: true), occurrenceTask]
        let value = try resolver.resolve(now: now, tasks: tasks, routines: [], calendar: calendar)
        #expect(value.end == day(60) && !value.wasCapped)
        #expect(try resolver.resolve(now: now, tasks: tasks.reversed(), routines: [], calendar: calendar) == value)
    }
    @Test func routineEndIsInclusiveAndMixedInputUsesFarthest() throws {
        let value = routine(45)
        #expect(try resolver.resolve(now: now, tasks: [], routines: [value], calendar: calendar).end == day(46))
        #expect(try resolver.resolve(now: now, tasks: [task(day(60))], routines: [value], calendar: calendar).end == day(60))
    }
    @Test func routineIsBoundedAndInvalidOrExpiredRoutineIsIgnored() throws {
        #expect(try resolver.resolve(now: now, tasks: [], routines: [routine(120)], calendar: calendar).wasCapped)
        var invalid = routine(150); invalid.estimatedMinutesPerDay = 0
        var expired = routine(-1); expired.startDate = day(-10)
        let value = try resolver.resolve(now: now, tasks: [], routines: [invalid, expired], calendar: calendar)
        #expect(value.end == day(14) && !value.wasCapped)
    }
    @Test func futureRoutineStillExtendsHorizonButDoesNotGenerateOutsideIt() throws {
        var value = routine(160); value.startDate = day(120)
        let horizon = try resolver.resolve(now: now, tasks: [], routines: [value], calendar: calendar)
        #expect(horizon.end == day(90) && horizon.wasCapped)
        #expect(RoutinePlanner().tasks(for: [value], in: horizon.interval, calendar: calendar).isEmpty)
    }
    @Test(arguments: [3, 10]) func dstUsesCalendarDays(month: Int) throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = local.date(from: DateComponents(year: 2026, month: month, day: month == 3 ? 1 : 25))!
        let value = try resolver.resolve(now: start, tasks: [], routines: [], calendar: local)
        #expect(value.end == local.date(byAdding: .day, value: 14, to: start))
        #expect(value.end.timeIntervalSince(start) == Double(14 * 24 + (month == 3 ? -1 : 1)) * 3600)
    }
    @Test func timeZoneAndDayChangeUseLocalBoundaries() throws {
        var tokyo = calendar; tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let instant = day(0, 23)
        let utcValue = try resolver.resolve(now: instant, tasks: [], routines: [], calendar: calendar)
        let tokyoValue = try resolver.resolve(now: instant, tasks: [], routines: [], calendar: tokyo)
        #expect(utcValue.start != tokyoValue.start)
        #expect(tokyoValue.start == tokyo.startOfDay(for: instant))
        let tomorrow = try resolver.resolve(now: day(1), tasks: [], routines: [], calendar: calendar)
        #expect(tomorrow.start == day(1) && tomorrow.end == day(15))
    }
    @Test(arguments: [PlanningHorizonSettings(minimumDays: 0, maximumDays: 90),
                      PlanningHorizonSettings(minimumDays: 20, maximumDays: 14),
                      PlanningHorizonSettings(minimumDays: 14, maximumDays: 91)])
    func invalidSettingsReject(settings: PlanningHorizonSettings) {
        #expect(throws: AvailabilityError.invalidSettings) {
            try resolver.resolve(now: now, tasks: [], routines: [], settings: settings, calendar: calendar)
        }
    }
    @Test func configurableMinimumAndMaximum() throws {
        let value = try resolver.resolve(now: now, tasks: [task(day(40))], routines: [],
            settings: PlanningHorizonSettings(minimumDays: 7, maximumDays: 30), calendar: calendar)
        #expect(value.end == day(30) && value.wasCapped)
    }
    @Test func coverageContainsAndIntersectsUsingHalfOpenBounds() {
        let coverage = CalendarCoverage(start: now, end: day(14))
        #expect(coverage.contains(DateInterval(start: now, end: day(14))))
        #expect(!coverage.contains(DateInterval(start: now, end: day(30))))
        #expect(coverage.intersection(with: DateInterval(start: day(1), end: day(30))) == DateInterval(start: day(1), end: day(14)))
        #expect(coverage.intersection(with: DateInterval(start: day(14), end: day(30))) == nil)
    }
    @Test func availabilityClipsPartialDayToRequestedAndConfirmedRange() throws {
        let slots = try AvailabilityService().availableSlots(fixedEvents: [], in: DateInterval(start: day(0, 10), end: day(30, 12)),
            referenceDate: day(0, 11), calendar: calendar)
        #expect(slots.first?.start == day(0, 11) && slots.last?.end == day(30, 12))
        #expect(slots.allSatisfy { $0.start >= day(0, 11) && $0.end <= day(30, 12) })
    }
}
