import Foundation
import Testing
@testable import PersonalGantt

struct TodayTests {
    @Test func currentAndNextWorkRemainingAndActualAreSeparate() {
        let task = PersonalGantt.Task(title: "Synthetic", estimatedMinutes: 180, deadline: ReminderFixtures.date(23))
        let blocks = [ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(10)), ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(12), end: ReminderFixtures.date(13))]
        let session = WorkSession(taskID: task.id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(9), actualMinutes: 60)
        let summary = TodaySummary.make(now: ReminderFixtures.date(9), tasks: [task], blocks: blocks, sessions: [session], calendar: ReminderFixtures.calendar)
        #expect(summary.nextWork == blocks.first && summary.remainingPlannedMinutes == 120 && summary.actualMinutes == 60)
    }
    @Test func completedTaskRetainsHistoryButIsNotNextWork() {
        let task = PersonalGantt.Task(title: "Synthetic", isCompleted: true, estimatedMinutes: 60, deadline: ReminderFixtures.date(23))
        let block = ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(9))
        let summary = TodaySummary.make(now: ReminderFixtures.date(0), tasks: [task], blocks: [block], sessions: [], calendar: ReminderFixtures.calendar)
        #expect(summary.blocks == [block] && summary.nextWork == nil && summary.actualMinutes == 0)
    }
    @Test func crossMidnightActualIsClippedToToday() {
        let session = WorkSession(taskID: UUID(), start: ReminderFixtures.date(23, day: 6), end: ReminderFixtures.date(1), actualMinutes: 120)
        let summary = TodaySummary.make(now: ReminderFixtures.date(2), tasks: [], blocks: [], sessions: [session], calendar: ReminderFixtures.calendar)
        #expect(summary.actualMinutes == 60)
    }
}
@MainActor struct TodayIntegrationTests {
    @Test func skipNormalWorkDefersFutureWithoutDeletingTaskAndSyncs() throws {
        let provider = TodayProvider()
        let model = ScheduleViewModel(tasks: [], calendarProvider: provider, calendar: ReminderFixtures.calendar, clock: { ReminderFixtures.date(0) })
        let task = try model.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23, day: 9)))
        model.skipToday(taskID: task.id)
        #expect(model.tasks.count == 1 && model.result.blocks.first?.start == ReminderFixtures.date(8, day: 8))
        let target = ScheduleViewModel(tasks: [], availableSlots: [])
        try target.mergeSyncRecords(Array(model.syncState.records.values))
        #expect(target.task(for: task.id)?.notBefore == ReminderFixtures.date(0, day: 8))
    }
    @Test func deferredTaskDoesNotConsumeEarlierSlotsForOtherTasks() {
        let deferred = PersonalGantt.Task(title: "Later", estimatedMinutes: 60, deadline: ReminderFixtures.date(12), notBefore: ReminderFixtures.date(10))
        let ordinary = PersonalGantt.Task(title: "Other", estimatedMinutes: 60, deadline: ReminderFixtures.date(13))
        let result = Scheduler().schedule(tasks: [deferred,ordinary], availableSlots: [AvailableSlot(start: ReminderFixtures.date(8), end: ReminderFixtures.date(12))])
        #expect(result.blocks.first?.taskID == ordinary.id && result.blocks.first?.start == ReminderFixtures.date(8))
        #expect(result.unscheduledTaskIDs.isEmpty)
    }
}
@MainActor private final class TodayProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .signedOut
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
