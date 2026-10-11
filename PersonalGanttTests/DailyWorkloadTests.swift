import Foundation
import Testing
@testable import PersonalGantt

struct DailyWorkloadTests {
    private let calendar = ReminderFixtures.calendar

    @Test func globalLimitIsSharedByTasksAndSpreadsLongWork() {
        let first = task(minutes: 600, deadline: date(23, day: 9))
        let second = task(minutes: 480, deadline: date(23, day: 10))
        let result = schedule([first, second], slots: (7...9).map { slot($0) }, limit: 300)
        let totals = DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar)
        #expect(totals.count == 3 && totals.values.allSatisfy { $0 == 300 * 60 })
        #expect(result.unscheduledTaskIDs == [second.id])
        #expect(result.blocks.filter { $0.taskID == second.id }.reduce(0) { $0 + $1.durationMinutes } == 300)
        for (left, right) in zip(result.blocks, result.blocks.dropFirst()) { #expect(left.end <= right.start) }
    }

    @Test func hundredHoursAcrossThirtyDaysUsesTwentyDaysAtFiveHours() {
        let rangeStart = date(0)
        let slots = (0..<30).map { offset -> AvailableSlot in
            let day = calendar.date(byAdding: .day, value: offset, to: rangeStart)!
            return AvailableSlot(start: day.addingTimeInterval(8 * 3600), end: day.addingTimeInterval(23 * 3600))
        }
        let work = task(minutes: 6000, deadline: slots.last!.end)
        let result = schedule([work], slots: slots, limit: 300)
        let totals = DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar)
        #expect(totals.count == 20 && totals.values.allSatisfy { $0 == 300 * 60 })
        #expect(result.unscheduledTaskIDs.isEmpty)
        #expect(result.blocks.reduce(0) { $0 + $1.durationMinutes } == 6000)
    }

    @Test func threeDaysEighteenHoursReportsThreeHoursShortfall() {
        let work = task(minutes: 1080, deadline: date(23, day: 9))
        let result = schedule([work], slots: (7...9).map { slot($0) }, limit: 300)
        #expect(result.unscheduledTaskIDs == [work.id])
        #expect(Double(work.estimatedMinutes) - result.blocks.reduce(0) { $0 + $1.durationMinutes } == 180)
    }

    @Test func fixedEventsReduceAvailabilityButDoNotConsumeDailyBudget() throws {
        let event = FixedEvent(id: "fixed", calendarID: "work", title: "合成予定", start: date(8), end: date(16))
        let slots = try AvailabilityService().availableSlots(fixedEvents: [event], referenceDate: date(0), calendar: calendar)
        let work = task(minutes: 300, deadline: date(23))
        let result = schedule([work], slots: slots, limit: 300)
        #expect(result.blocks == [ScheduledBlock(taskID: work.id, start: date(16), end: date(21))])
        #expect(result.unscheduledTaskIDs.isEmpty)
    }

    @Test func deadlineAndSubminuteSlotBoundariesRespectExactBudget() {
        let work = task(minutes: 61, deadline: date(10))
        let start = date(8).addingTimeInterval(30)
        let result = schedule([work], slots: [AvailableSlot(start: start, end: date(9)), AvailableSlot(start: date(9, minute: 30), end: date(12))], limit: 60)
        #expect(result.blocks.reduce(0) { $0 + $1.durationMinutes } == 60)
        #expect(result.blocks.last?.end == date(9, minute: 30).addingTimeInterval(30))
        #expect(result.unscheduledTaskIDs == [work.id])
    }

    @Test func overlappingSlotsCannotDoubleCountDailyLimit() {
        let work = task(minutes: 300, deadline: date(23))
        let result = schedule([work], slots: [slot(7), slot(7), AvailableSlot(start: date(9), end: date(20))], limit: 120)
        #expect(result.blocks.reduce(0) { $0 + $1.durationMinutes } == 120)
        #expect(result.blocks.count == 1)
    }

    @Test func crossingMidnightSplitsBudgetByLocalCalendarDay() {
        let work = task(minutes: 180, deadline: date(3, day: 8))
        let result = schedule([work], slots: [AvailableSlot(start: date(23), end: date(3, day: 8))], limit: 60)
        #expect(result.blocks == [ScheduledBlock(taskID: work.id, start: date(23), end: date(0, day: 8)),
                                  ScheduledBlock(taskID: work.id, start: date(0, day: 8), end: date(1, day: 8))])
        #expect(result.unscheduledTaskIDs == [work.id])
    }

    @Test(arguments: ["Asia/Tokyo", "America/Los_Angeles"])
    func localDaysUseInjectedTimeZone(zone: String) throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = try #require(TimeZone(identifier: zone))
        let first = try #require(local.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23)))
        let end = try #require(local.date(byAdding: .hour, value: 4, to: first))
        let work = task(minutes: 180, deadline: end)
        let result = Scheduler().schedule(tasks: [work], availableSlots: [AvailableSlot(start: first, end: end)],
            workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 60), calendar: local)
        #expect(DailyWorkload.secondsByDay(blocks: result.blocks, calendar: local).values.allSatisfy { $0 == 3600 })
        #expect(result.blocks.count == 2 && result.blocks.reduce(0) { $0 + $1.durationMinutes } == 120)
    }

    @Test(arguments: [3, 11]) func daylightSavingDaysUseRealElapsedMinutes(month: Int) throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(local.date(from: DateComponents(year: 2026, month: month, day: month == 3 ? 8 : 1)))
        let boundary = try #require(local.date(byAdding: .day, value: 1, to: day))
        #expect(boundary.timeIntervalSince(day) == Double(month == 3 ? 23 : 25) * 3600)
        let after = try #require(local.date(byAdding: .day, value: 2, to: day))
        let work = task(minutes: 240, deadline: after)
        let result = Scheduler().schedule(tasks: [work], availableSlots: [AvailableSlot(start: day, end: after)],
            workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 120), calendar: local)
        #expect(result.blocks.count == 2 && result.blocks.last?.start == boundary)
        #expect(DailyWorkload.secondsByDay(blocks: result.blocks, calendar: local).values.allSatisfy { $0 == 7200 })
    }

    @Test func protectedCrossMidnightWorkCountsAgainstBothDaysIncludingArchivedTasks() {
        let old = ScheduledBlock(taskID: UUID(), start: date(23), end: date(1, day: 8))
        let work = task(minutes: 240, deadline: date(23, day: 8))
        let result = ScheduleReplanner().schedule(tasks: [work], availableSlots: [AvailableSlot(start: date(23), end: date(4, day: 8))],
            previousBlocks: [old], now: date(23, minute: 30),
            workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 120), calendar: calendar)
        #expect(result.blocks.contains(old))
        #expect(result.blocks.filter { $0.taskID == work.id } == [ScheduledBlock(taskID: work.id, start: date(1, day: 8), end: date(2, day: 8))])
        #expect(result.unscheduledTaskIDs == [work.id])
    }

    @Test func loweringLimitKeepsBegunWorkAndAddsNothingOnOverfullDay() {
        let old = ScheduledBlock(taskID: UUID(), start: date(8), end: date(13))
        let work = task(minutes: 60, deadline: date(23))
        let result = ScheduleReplanner().schedule(tasks: [work], availableSlots: [slot(7)], previousBlocks: [old], now: date(9),
            workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: 120), calendar: calendar)
        #expect(result.blocks == [old] && result.unscheduledTaskIDs == [work.id])
    }

    @Test func unlimitedRetainsOriginalCrossDayAllocation() {
        let work = task(minutes: 120, deadline: date(3, day: 8))
        let result = Scheduler().schedule(tasks: [work], availableSlots: [AvailableSlot(start: date(23), end: date(3, day: 8))], calendar: calendar)
        #expect(result.blocks == [ScheduledBlock(taskID: work.id, start: date(23), end: date(1, day: 8))])
    }

    @Test(arguments: [0, -1, Int.min]) func invalidLimitIsRejected(limit: Int) {
        #expect(throws: WorkloadInputError.invalidLimit) { try WorkloadSettings(maxScheduledMinutesPerDay: limit).validate() }
    }

    @Test func maximumLimitDoesNotOverflow() throws {
        let settings = WorkloadSettings(maxScheduledMinutesPerDay: Int.max)
        try settings.validate()
        let work = task(minutes: 60, deadline: date(23))
        #expect(schedule([work], slots: [slot(7)], limit: Int.max).unscheduledTaskIDs.isEmpty)
    }

    private func schedule(_ tasks: [PersonalGantt.Task], slots: [AvailableSlot], limit: Int) -> SchedulingResult {
        Scheduler().schedule(tasks: tasks, availableSlots: slots, workloadSettings: WorkloadSettings(maxScheduledMinutesPerDay: limit), calendar: calendar)
    }
    private func task(minutes: Int, deadline: Date) -> PersonalGantt.Task { PersonalGantt.Task(title: "合成作業", estimatedMinutes: minutes, deadline: deadline) }
    private func slot(_ day: Int) -> AvailableSlot { AvailableSlot(start: date(8, day: day), end: date(23, day: day)) }
    private func date(_ hour: Int, minute: Int = 0, day: Int = 7) -> Date { ReminderFixtures.date(hour, minute, day: day) }
}
