import Foundation
import Testing
@testable import PersonalGantt

struct BalancedSchedulingTests {
    private var calendar: Calendar { ReminderFixtures.calendar }
    private func day(_ n: Int, _ hour: Int = 8) -> Date { calendar.date(byAdding: .day, value: n, to: ReminderFixtures.date(hour))! }
    @Test func hundredHoursSpreadOverThirtyUsableDays() {
        let work = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 6000, deadline: day(30, 0))
        let slots = (0..<30).map { AvailableSlot(start: day($0), end: day($0, 23)) }
        let result = Scheduler().schedule(tasks: [work], availableSlots: slots, workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 300), calendar: calendar, distributionMode: .balanced)
        let totals = DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar).mapValues { $0 / 60 }
        #expect(totals.count == 30 && totals.values.allSatisfy { $0 == 200 })
        #expect(result.unscheduledTaskIDs.isEmpty)
    }
    @Test func unevenCapacitySaturatesSmallDaysAndRedistributes() {
        let work = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 300, deadline: day(3, 0))
        let slots = [AvailableSlot(start: day(0), end: day(0, 9)), AvailableSlot(start: day(1), end: day(1, 12)), AvailableSlot(start: day(2), end: day(2, 12))]
        let result = Scheduler().schedule(tasks: [work], availableSlots: slots, calendar: calendar, distributionMode: .balanced)
        #expect(result.blocks.map(\.durationMinutes) == [60,120,120])
    }
    @Test func routinesReserveTheirOwnDaysAndShareCap() {
        let rule = Routine(title: "Synthetic Routine", estimatedMinutesPerDay: 30, startDate: day(0, 0), endDate: day(9, 0), recurrence: .daily)
        let range = DateInterval(start: day(0, 0), end: day(10, 0))
        let tasks = RoutinePlanner().tasks(for: [rule], in: range, calendar: calendar)
        let work = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 600, deadline: range.end)
        let slots = (0..<10).map { AvailableSlot(start: day($0), end: day($0, 23)) }
        let result = Scheduler().schedule(tasks: tasks + [work], availableSlots: slots, workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 120), calendar: calendar, distributionMode: .balanced)
        #expect(result.unscheduledTaskIDs.isEmpty)
        #expect(DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar).values.allSatisfy { $0 <= 120 * 60 })
        for task in tasks { #expect(result.blocks.filter { $0.taskID == task.id }.allSatisfy { $0.start >= task.routineOccurrence!.dayStart && $0.end <= task.deadline }) }
    }
    @Test func unavailableDaysExcludedAndFractionalSharesStayDeterministic() {
        let work = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 181, deadline: day(7, 0))
        let slots = [0,2,6].map { AvailableSlot(start: day($0), end: day($0, 12)) }
        let a = Scheduler().schedule(tasks: [work], availableSlots: slots, calendar: calendar, distributionMode: .balanced)
        let b = Scheduler().schedule(tasks: [work], availableSlots: slots.reversed(), calendar: calendar, distributionMode: .balanced)
        #expect(a == b && a.unscheduledTaskIDs.isEmpty)
        #expect(abs(a.blocks.reduce(0) { $0 + $1.durationMinutes } - 181) < 0.000001)
    }
    @Test func nearDeadlineUsesAvailableTimeAndEarliestModeRetainsBehavior() {
        let work = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 300, deadline: day(0, 12))
        let slots = (0..<10).map { AvailableSlot(start: day($0), end: day($0, 23)) }
        let a = Scheduler().schedule(tasks: [work], availableSlots: slots, calendar: calendar, distributionMode: .balanced)
        let b = Scheduler().schedule(tasks: [work], availableSlots: slots, calendar: calendar)
        #expect(a == b && a.blocks.first?.end == work.deadline && a.unscheduledTaskIDs == [work.id])
    }
    @Test func lossOfTodayRedistributesRemainingAcrossWholeFutureRange() {
        let work = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 1200, deadline: day(10, 0))
        let original = (0..<10).map { AvailableSlot(start: day($0), end: day($0, 23)) }
        let initial = Scheduler().schedule(tasks: [work], availableSlots: original, calendar: calendar, distributionMode: .balanced)
        let now = day(0, 0)
        let after = ScheduleReplanner().schedule(tasks: [work], availableSlots: Array(original.dropFirst()), previousBlocks: initial.blocks,
            now: now, calendar: calendar, distributionMode: .balanced)
        #expect(after.blocks.count == 9 && after.unscheduledTaskIDs.isEmpty)
        #expect(after.blocks.allSatisfy { $0.durationMinutes > 133 && $0.durationMinutes < 134 })
    }
}
@MainActor struct BalancedIntegrationTests {
    @Test func modePersistsAndSyncsWithoutChangingLegacyDefault() throws {
        let a = ScheduleViewModel(tasks: [], availableSlots: []), b = ScheduleViewModel(tasks: [], availableSlots: [])
        #expect(a.schedulingSettings.distributionMode == .earliestFirst)
        a.setDistributionMode(.balanced)
        try b.mergeSyncRecords(Array(a.syncState.records.values))
        #expect(b.schedulingSettings.distributionMode == .balanced)
    }
}
