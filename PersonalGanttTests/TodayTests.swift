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
    @Test func completedTaskIsAbsentFromTodayCardsWhileActualRemains() {
        let task = PersonalGantt.Task(title: "Synthetic", isCompleted: true, estimatedMinutes: 60, deadline: ReminderFixtures.date(23))
        let block = ScheduledBlock(taskID: task.id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(9))
        let session = WorkSession(taskID: task.id, start: block.start, end: block.end, actualMinutes: 60)
        let summary = TodaySummary.make(now: ReminderFixtures.date(0), tasks: [task], blocks: [block], sessions: [session], calendar: ReminderFixtures.calendar)
        #expect(summary.blocks.isEmpty && summary.nextWork == nil && summary.remainingPlannedMinutes == 0 && summary.actualMinutes == 60)
    }
    @Test func crossMidnightActualIsClippedToToday() {
        let session = WorkSession(taskID: UUID(), start: ReminderFixtures.date(23, day: 6), end: ReminderFixtures.date(1), actualMinutes: 120)
        let summary = TodaySummary.make(now: ReminderFixtures.date(2), tasks: [], blocks: [], sessions: [session], calendar: ReminderFixtures.calendar)
        #expect(summary.actualMinutes == 60)
    }
}
@MainActor struct TodayIntegrationTests {
    @Test func completingBegunTaskHidesAllTodayCardsAndRestartKeepsHistory() async throws {
        let clock = TodayClock(), store = TodayStore()
        func makeModel() -> ScheduleViewModel {
            ScheduleViewModel(tasks: [], calendarProvider: TodayConfirmedProvider(), activitySettings: .legacyFixture,
                calendar: ReminderFixtures.calendar, clock: { clock.now }, planStore: store)
        }
        let model = makeModel()
        let task = try model.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        // Begun history is protected only after the plan's Calendar read is confirmed.
        #expect(await model.applyCalendarSelection(["work"]))
        let history = try #require(model.result.blocks.first)
        clock.now = history.start.addingTimeInterval(30 * 60)
        try model.logWork(taskID: task.id, minutes: 30)
        await model.toggleTaskCompletion(id: task.id)
        #expect(model.task(for: task.id)?.isCompleted == true && model.result.blocks.contains(history))
        func summary(_ model: ScheduleViewModel) -> TodaySummary {
            TodaySummary.make(now: clock.now, tasks: model.tasks, blocks: model.result.blocks, sessions: model.workSessions, calendar: ReminderFixtures.calendar)
        }
        #expect(summary(model).blocks.isEmpty && summary(model).actualMinutes == 30)
        let restarted = makeModel()
        #expect(restarted.result.blocks.contains(history) && restarted.workSessions == model.workSessions)
        #expect(summary(restarted).blocks.isEmpty && summary(restarted).actualMinutes == 30)
        await restarted.toggleTaskCompletion(id: task.id)
        #expect(summary(restarted).blocks.contains(history))
    }
    @Test func completedRoutineAndDeletedTaskDoNotLeaveTodayCards() async throws {
        let clock = TodayClock()
        let model = ScheduleViewModel(tasks: [], calendarProvider: TodayConfirmedProvider(), activitySettings: .legacyFixture,
            calendar: ReminderFixtures.calendar, clock: { clock.now })
        _ = try model.saveRoutine(Routine(title: "Synthetic routine", estimatedMinutesPerDay: 60,
            startDate: clock.now, endDate: ReminderFixtures.date(0, day: 8), recurrence: .daily))
        #expect(await model.applyCalendarSelection(["work"]))
        let task = try #require(model.tasks.first { $0.routineOccurrence?.dayStart == ReminderFixtures.date(0) })
        let history = try #require(model.result.blocks.first { $0.taskID == task.id })
        clock.now = history.start.addingTimeInterval(30 * 60)
        model.toggleCompletion(id: task.id)
        #expect(model.result.blocks.contains(history) && model.task(for: task.id)?.isCompleted == true)
        let summary = TodaySummary.make(now: clock.now, tasks: model.tasks, blocks: model.result.blocks, sessions: [], calendar: ReminderFixtures.calendar)
        #expect(summary.blocks.isEmpty && model.tasks.contains { $0.routineOccurrence?.dayStart == ReminderFixtures.date(0, day: 8) && !$0.isCompleted })
        let deleted = TodaySummary.make(now: clock.now, tasks: [], blocks: [history], sessions: [], calendar: ReminderFixtures.calendar)
        #expect(deleted.blocks.isEmpty)
    }
    @Test func skipNormalWorkDefersFutureWithoutDeletingTaskAndSyncs() throws {
        let provider = TodayProvider()
        let model = ScheduleViewModel(tasks: [], calendarProvider: provider, activitySettings: .legacyFixture, calendar: ReminderFixtures.calendar, clock: { ReminderFixtures.date(0) })
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
@MainActor private final class TodayClock { var now = ReminderFixtures.date(0) }
@MainActor private final class TodayStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot }
}
@MainActor private final class TodayConfirmedProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [CalendarSource(id: "work", title: "Synthetic", accountTitle: "Test")] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
@MainActor private final class TodayProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .signedOut
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
