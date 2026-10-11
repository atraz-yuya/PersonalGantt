import Foundation
import Testing
@testable import PersonalGantt

struct RoutinePlannerTests {
    private let calendar = ReminderFixtures.calendar

    @Test func dailyCreatesSeparateRequirementsWithInclusiveEndDate() {
        let routine = routine(.daily)
        let tasks = expand(routine)
        #expect(tasks.count == 7 && Set(tasks.map(\.id)).count == 7)
        #expect(tasks.allSatisfy { $0.estimatedMinutes == 30 && $0.routineOccurrence?.routineID == routine.id })
        #expect(tasks.first?.routineOccurrence?.dayStart == date(0, day: 12))
        #expect(tasks.last?.deadline == date(0, day: 19))
        #expect(tasks == expand(routine))
    }

    @Test(arguments: [RecurrenceRule.weekdays, .selectedWeekdays([2, 4, 6]), .weekly(weekday: 4)])
    func recurrenceIncludesOnlySelectedWeekdays(rule: RecurrenceRule) {
        let tasks = expand(routine(rule))
        let days = tasks.compactMap { $0.routineOccurrence.map { calendar.component(.weekday, from: $0.dayStart) } }
        switch rule {
        case .weekdays: #expect(days == [2, 3, 4, 5, 6])
        case .selectedWeekdays: #expect(days == [2, 4, 6])
        case .weekly: #expect(days == [4])
        default: Issue.record("Unexpected rule")
        }
    }

    @Test func expansionIntersectsRoutineDatesAndRollingWindow() {
        var value = routine(.daily)
        value.startDate = date(0, day: 14); value.endDate = date(0, day: 16)
        #expect(expand(value).count == 3)
        value.startDate = date(0, day: 1)
        value.endDate = calendar.date(byAdding: .year, value: 20, to: value.startDate)!
        #expect(expand(value).count == 7)
    }

    @Test func futureOccurrenceCannotUseEarlierDayEvenForSameDeadlineOrdering() {
        var value = routine(.daily); value.startDate = date(0, day: 13); value.endDate = value.startDate
        let tasks = expand(value)
        let slots = [AvailableSlot(start: date(8, day: 12), end: date(23, day: 14))]
        let result = Scheduler().schedule(tasks: tasks, availableSlots: slots, calendar: calendar)
        #expect(result.blocks.count == 1 && result.blocks.first?.start == date(0, day: 13))
        #expect(result.blocks.first?.durationMinutes == 30)
    }

    @Test func missingDaysAreUnallocatedAndNeverMovedToAnotherDay() {
        let tasks = expand(routine(.daily))
        let result = Scheduler().schedule(tasks: tasks, availableSlots: [AvailableSlot(start: date(8, day: 13), end: date(23, day: 13))], calendar: calendar)
        #expect(result.blocks.count == 1 && result.blocks.first?.taskID == tasks[1].id)
        #expect(result.unscheduledTaskIDs.count == 6)
    }

    @Test func normalTasksAndOccurrencesShareSameDailyBudget() {
        let daily = expand(routine(.daily))
        let normal = PersonalGantt.Task(title: "通常", estimatedMinutes: 180, deadline: date(0, day: 19))
        let slots = (12...18).map { AvailableSlot(start: date(8, day: $0), end: date(23, day: $0)) }
        let result = Scheduler().schedule(tasks: daily + [normal], availableSlots: slots,
            workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 60), calendar: calendar)
        #expect(result.unscheduledTaskIDs.isEmpty)
        #expect(DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar).values.allSatisfy { $0 <= 3600 })
        #expect(result.blocks.filter { $0.taskID == normal.id }.reduce(0) { $0 + $1.durationMinutes } == 180)
    }

    @Test func completionAndSkipPersistAcrossRegeneration() {
        var value = routine(.daily)
        let tasks = expand(value)
        value.completedOccurrenceIDs.insert(tasks[0].id)
        value.skippedOccurrenceIDs.insert(tasks[1].id)
        let regenerated = expand(value)
        #expect(regenerated.count == 6 && regenerated.first?.isCompleted == true)
        #expect(!regenerated.contains { $0.id == tasks[1].id })
    }

    @Test(arguments: ["Asia/Tokyo", "America/Los_Angeles"])
    func localDateIdentityIsIndependentOfTimeZoneOffset(zone: String) throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = try #require(TimeZone(identifier: zone))
        let start = try #require(local.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let end = try #require(local.date(byAdding: .day, value: 1, to: start))
        var value = routine(.daily); value.startDate = start; value.endDate = start
        let generated = RoutinePlanner().tasks(for: [value], in: DateInterval(start: start, end: end), calendar: local)
        #expect(generated.first?.id == expand(routine(.daily)).first?.id)
    }

    @Test(arguments: [3, 11]) func daylightSavingOccurrencesHaveActualLocalDayIntervals(month: Int) throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try #require(local.date(from: DateComponents(year: 2026, month: month, day: month == 3 ? 8 : 1)))
        let end = try #require(local.date(byAdding: .day, value: 1, to: start))
        var value = routine(.daily); value.startDate = start; value.endDate = start
        let generated = RoutinePlanner().tasks(for: [value], in: DateInterval(start: start, end: end), calendar: local)
        #expect(generated.count == 1)
        #expect(generated.first?.deadline.timeIntervalSince(start) == Double(month == 3 ? 23 : 25) * 3600)
    }

    @Test(arguments: [RecurrenceRule.selectedWeekdays([]), .selectedWeekdays([0, 2]), .weekly(weekday: 8)])
    func invalidRecurrenceIsRejected(rule: RecurrenceRule) {
        let value = routine(rule)
        #expect(throws: RoutineInputError.invalidWeekdays) { try value.validate() }
        #expect(expand(value).isEmpty)
    }

    @Test func invalidDatesMinutesTitleAndStateAreRejected() {
        var value = routine(.daily); value.startDate = date(0, day: 20)
        #expect(throws: RoutineInputError.invalidDates) { try value.validate() }
        value = routine(.daily); value.estimatedMinutesPerDay = 0
        #expect(throws: TaskInputError.invalidMinutes) { try value.validate() }
        value = routine(.daily); value.title = " "
        #expect(throws: TaskInputError.emptyTitle) { try value.validate() }
        value = routine(.daily); let id = UUID(); value.completedOccurrenceIDs = [id]; value.skippedOccurrenceIDs = [id]
        #expect(throws: RoutineInputError.invalidState) { try value.validate() }
    }

    private func expand(_ routine: Routine) -> [PersonalGantt.Task] {
        RoutinePlanner().tasks(for: [routine], in: DateInterval(start: date(0, day: 12), end: date(0, day: 19)), calendar: calendar)
    }
    private func routine(_ rule: RecurrenceRule) -> Routine {
        Routine(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, title: "英語", estimatedMinutesPerDay: 30,
                startDate: date(0, day: 12), endDate: date(0, day: 18), recurrence: rule)
    }
    private func date(_ hour: Int, day: Int) -> Date { ReminderFixtures.date(hour, day: day) }
}
