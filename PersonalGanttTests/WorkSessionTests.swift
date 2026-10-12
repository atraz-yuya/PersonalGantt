import Foundation
import Testing
@testable import PersonalGantt

@MainActor struct WorkSessionTests {
    @Test(arguments: [0,-1,1441]) func invalidMinutesCannotChangeTask(minutes: Int) throws {
        let model = model(); let work = try model.addTask(TaskDraft(title: "Synthetic", estimatedMinutesText: "300", deadline: ReminderFixtures.date(23)))
        #expect(throws: WorkSessionError.self) { try model.logWork(taskID: work.id, minutes: minutes) }
        #expect(model.workSessions.isEmpty && model.remainingMinutes(for: work) == 300)
    }
    @Test func partialActualReplansRemainingAndFullActualDoesNotAutomaticallyCompleteTask() throws {
        let value = model(); let work = try value.addTask(TaskDraft(title: "Synthetic", estimatedMinutesText: "300", deadline: ReminderFixtures.date(23)))
        try value.logWork(taskID: work.id, minutes: 120)
        #expect(value.completedMinutes(for: work.id) == 120 && value.remainingMinutes(for: work) == 180)
        #expect(value.scheduledMinutes(for: work.id) == 180)
        try value.logWork(taskID: work.id, minutes: 180)
        #expect(value.remainingMinutes(for: work) == 0 && value.result.blocks.isEmpty)
        #expect(value.task(for: work.id)?.isCompleted == false)
        let session = try #require(value.workSessions.first); value.deleteWorkSession(id: session.id)
        #expect(value.remainingMinutes(for: work) == 120)
    }
    @Test func plannedHistoryNeverCreatesWorkSessionsAndActualAvoidsDoubleDeduction() {
        let id = UUID(), now = ReminderFixtures.date(12)
        let work = PersonalGantt.Task(id: id, title: "Synthetic", estimatedMinutes: 300, deadline: ReminderFixtures.date(23))
        let old = ScheduledBlock(taskID: id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(10))
        let actual = WorkSession(taskID: id, start: old.start, end: old.end, actualMinutes: 120)
        let result = ScheduleReplanner().schedule(tasks: [work], availableSlots: [AvailableSlot(start: now, end: ReminderFixtures.date(23))],
            previousBlocks: [old], now: now, calendar: ReminderFixtures.calendar, workSessions: [actual])
        #expect(result.blocks.contains(old))
        #expect(result.blocks.filter { $0.start >= now }.reduce(0) { $0 + $1.durationMinutes } == 180)
    }
    @Test func ongoingPlanIsProtectedAndOnlyUnrecordedPortionIsReserved() {
        let id = UUID(), now = ReminderFixtures.date(10)
        let work = PersonalGantt.Task(id: id, title: "Synthetic", estimatedMinutes: 300, deadline: ReminderFixtures.date(23))
        let block = ScheduledBlock(taskID: id, start: ReminderFixtures.date(8), end: ReminderFixtures.date(11))
        let actual = WorkSession(taskID: id, start: block.start, end: now, actualMinutes: 120)
        let result = ScheduleReplanner().schedule(tasks: [work], availableSlots: [AvailableSlot(start: now, end: ReminderFixtures.date(23))],
            previousBlocks: [block], now: now, calendar: ReminderFixtures.calendar, workSessions: [actual])
        #expect(result.blocks.contains(block))
        #expect(result.blocks.filter { $0 != block }.reduce(0) { $0 + $1.durationMinutes } == 120)
    }
    @Test func actualRecordsAndTimerSurviveCheckpointAndSync() throws {
        let store = WorkSessionStore(); let value = model(store)
        let work = try value.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        try value.logWork(taskID: work.id, minutes: 30); try value.startWork(taskID: work.id)
        let restored = model(store)
        #expect(restored.workSessions == value.workSessions && restored.activeWorkSession == value.activeWorkSession)
        let target = model(); try target.mergeSyncRecords(Array(value.syncState.records.values))
        #expect(target.workSessions == value.workSessions && target.activeWorkSession == nil)
        #expect(target.remainingMinutes(for: work) == 30)
    }
    @Test func timerRequiresAtLeastOneMinuteAndCannotStartTwoTasks() throws {
        let clock = SessionClock(); let value = ScheduleViewModel(tasks: [], calendarProvider: SessionProvider(), activitySettings: .legacyFixture, calendar: ReminderFixtures.calendar, clock: { clock.now })
        value.attachPlanStore(WorkSessionStore())
        let work = try value.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        try value.startWork(taskID: work.id)
        #expect(throws: WorkSessionError.self) { try value.startWork(taskID: work.id) }
        #expect(throws: WorkSessionError.self) { try value.finishWork() }
        clock.now = clock.now.addingTimeInterval(1800); try value.finishWork()
        #expect(value.workSessions.first?.actualMinutes == 30 && value.activeWorkSession == nil)
    }
    private func model(_ store: WorkSessionStore? = nil) -> ScheduleViewModel {
        let value = ScheduleViewModel(tasks: [], calendarProvider: SessionProvider(), activitySettings: .legacyFixture, calendar: ReminderFixtures.calendar, clock: { ReminderFixtures.date(0) })
        value.attachPlanStore(store ?? WorkSessionStore()); return value
    }
}
@MainActor private final class WorkSessionStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot }
}
@MainActor private final class SessionClock { var now = ReminderFixtures.date(0) }
@MainActor private final class SessionProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .signedOut
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
