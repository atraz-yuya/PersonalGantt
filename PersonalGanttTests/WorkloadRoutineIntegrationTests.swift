import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct WorkloadRoutineIntegrationTests {
    @Test func settingsDefaultToUnlimitedAndSurviveReopen() throws {
        let store = WorkloadPlanStore(); let model = makeModel(store)
        #expect(model.workloadSettings == .unlimited)
        let work = try model.addTask(TaskDraft(title: "長期作業", estimatedMinutesText: "600", deadline: date(23, day: 9)))
        #expect(model.result.blocks.count == 1)
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        #expect(model.result.blocks.count == 2 && model.scheduledMinutes(for: work.id) == 600)
        #expect(model.dailyScheduledMinutes.values.allSatisfy { $0 <= 300 })
        let reopened = makeModel(store)
        #expect(reopened.workloadSettings.maxScheduledMinutesPerDay == 300)
        #expect(reopened.tasks == model.tasks && reopened.result == model.result)
        try reopened.setWorkloadSettings(.unlimited)
        #expect(reopened.result.blocks.count == 1)
    }

    @Test func siriUsesWorkloadLimitWithoutFetchingCalendarAndReportsShortfall() throws {
        let store = WorkloadPlanStore(); let provider = WorkloadCalendarProvider()
        let model = makeModel(store, provider: provider)
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 60))
        let receipt = try TaskCreationService(model: model).create(title: "卒論", estimatedMinutes: 120, deadline: date(23))
        #expect(receipt.unallocatedMinutes == 60 && receipt.isScheduleSaved)
        #expect(receipt.dialogText.contains("1日60分の上限") && receipt.dialogText.contains("60分配置できませんでした"))
        #expect(provider.reads == 0 && store.value?.tasks == [receipt.task])
        let far = try TaskCreationService(model: model).create(title: "長期", estimatedMinutes: 6000, deadline: date(23, day: 31))
        #expect(far.dialogText.contains("締切までに"))
        #expect(model.planningInterval?.end == far.task.deadline)
    }

    @Test func routineAndManualTasksShareCapAndCalendarRefreshRespectsIt() async throws {
        let store = WorkloadPlanStore(); let provider = WorkloadCalendarProvider()
        let model = makeModel(store, provider: provider)
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 60))
        try model.saveRoutine(routine())
        _ = try model.addTask(TaskDraft(title: "通常", estimatedMinutesText: "180", deadline: date(23, day: 9)))
        let before = model.tasks
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(model.tasks == before)
        #expect(model.dailyScheduledMinutes.values.allSatisfy { $0 <= 60 })
        #expect(model.result.blocks.allSatisfy { block in model.fixedEvents.allSatisfy { !(block.start < $0.end && $0.start < block.end) } })
        #expect(model.unscheduledTasks.reduce(0) { $0 + model.unallocatedMinutes(for: $1) } == 90)
    }

    @Test func routineCompletionSkipEditingAndDeletionSurviveRecalculation() throws {
        let store = WorkloadPlanStore(); let model = makeModel(store)
        var value = try model.saveRoutine(routine())
        let first = try #require(model.tasks.first)
        let second = try #require(model.tasks.dropFirst().first)
        model.toggleCompletion(id: first.id)
        model.deleteTask(id: second.id)
        #expect(model.tasks.count == 2 && model.task(for: first.id)?.isCompleted == true)
        model.recalculate()
        let reopened = makeModel(store)
        #expect(reopened.task(for: first.id)?.isCompleted == true && reopened.task(for: second.id) == nil)
        value.title = " 編集した英語 "; value.estimatedMinutesPerDay = 45
        try reopened.saveRoutine(value)
        #expect(reopened.tasks.allSatisfy { $0.title == "編集した英語" && $0.estimatedMinutes == 45 })
        #expect(reopened.task(for: first.id)?.isCompleted == true)
        reopened.toggleCompletion(id: first.id)
        #expect(reopened.task(for: first.id)?.isCompleted == false)
        reopened.resetRoutineSkippedDays(id: value.id)
        #expect(reopened.tasks.count == 3 && reopened.task(for: second.id)?.id == second.id)
        reopened.deleteRoutine(id: value.id)
        #expect(reopened.routines.isEmpty && reopened.tasks.isEmpty && reopened.result.blocks.isEmpty)
    }

    @Test func routineTaskCannotBeEditedAsOneOffRequirement() throws {
        let model = makeModel(WorkloadPlanStore()); try model.saveRoutine(routine())
        let occurrence = try #require(model.tasks.first)
        #expect(throws: RoutineInputError.editOccurrence) { try model.updateTask(id: occurrence.id, draft: TaskDraft(task: occurrence)) }
    }

    @Test func begunRoutineWorkIsProtectedAndCountsWhenLimitChangesOrRoutineIsDeleted() async throws {
        let store = WorkloadPlanStore(); let clock = WorkloadClock(date: date(0))
        let model = makeModel(store, clock: clock)
        var value = routine(); value.estimatedMinutesPerDay = 180
        try model.saveRoutine(value)
        await model.refreshCalendars()
        let begun = try #require(model.result.blocks.first)
        clock.date = date(9)
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 60))
        #expect(model.result.blocks.contains(begun) && model.workloadLimitExceededDays == 1)
        model.deleteRoutine(id: value.id)
        #expect(model.tasks.isEmpty && model.result.blocks == [begun])
        #expect(model.title(for: begun.taskID) == value.title)
        _ = try model.addTask(TaskDraft(title: "通常", deadline: date(23)))
        #expect(model.result.blocks == [begun] && model.unscheduledTasks.count == 1)
    }

    @Test func offlineDayChangeGeneratesNextWindowWithoutDuplicatingBegunWork() async throws {
        let store = WorkloadPlanStore(); let clock = WorkloadClock(date: date(0))
        let provider = WorkloadCalendarProvider()
        let model = makeModel(store, provider: provider, clock: clock)
        var value = routine(); value.endDate = ReminderFixtures.calendar.date(byAdding: .day, value: 120, to: date(0))!
        try model.saveRoutine(value)
        await model.applicationDidBecomeActive()
        #expect(model.tasks.count == 90)
        let oldIDs = Set(model.tasks.map(\.id))
        let first = try #require(model.result.blocks.first)
        provider.fail = true; clock.date = date(0, day: 8)
        await model.refreshForDayChangeIfNeeded()
        #expect(model.tasks.count == 90 && model.result.blocks.contains(first))
        #expect(Set(model.tasks.map(\.id)).intersection(oldIDs).count == 89)
        #expect(model.title(for: first.taskID) == value.title)
        #expect(model.calendarMessage != nil && model.persistenceMessage == nil)
        let added = try #require(model.tasks.first { !oldIDs.contains($0.id) })
        #expect(model.result.unscheduledTaskIDs.contains(added.id))
        provider.fail = false; await model.refreshCalendars()
        #expect(!model.result.unscheduledTaskIDs.contains(added.id))
        #expect(model.scheduledMinutes(for: added.id) == 30)
    }

    @Test func swiftDataAndBackupRoundTripIncludeLimitsRoutinesAndDailyCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LocalPlan.store")
        let model = makeModel(try SwiftDataPlanStore(url: url))
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        try model.saveRoutine(routine())
        let task = try #require(model.tasks.first); model.toggleCompletion(id: task.id)
        let reopened = makeModel(try SwiftDataPlanStore(url: url))
        #expect(reopened.routines == model.routines && reopened.workloadSettings == model.workloadSettings)
        #expect(reopened.task(for: task.id)?.isCompleted == true)
        let backup = try PersonalGanttBackup.decode(model.makeBackup().encoded())
        let target = makeModel(WorkloadPlanStore())
        try target.restoreBackup(backup)
        #expect(target.routines == model.routines && target.workloadSettings == model.workloadSettings)
        #expect(target.tasks == model.tasks && target.result == model.result)
    }

    @Test func legacyCheckpointAndBackupDecodeAsUnlimitedWithoutRoutines() throws {
        let source = makeModel(WorkloadPlanStore())
        _ = try source.addTask(TaskDraft(title: "旧Task", deadline: date(23)))
        var backup = try source.makeBackup()
        backup.plan.version = 1; backup.plan.syncState = nil; backup.plan.workSessions = nil; backup.plan.schedulingSettings = nil; backup.plan.workloadSettings = nil; backup.plan.routines = nil
        let encoded = try backup.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let plan = try #require(object["plan"] as? [String: Any])
        #expect(plan["routines"] == nil && plan["workloadSettings"] == nil)
        let store = WorkloadPlanStore(); store.value = backup.plan
        let restored = makeModel(store)
        #expect(restored.workloadSettings == .unlimited && restored.routines.isEmpty && restored.tasks == source.tasks)
        let target = makeModel(WorkloadPlanStore()); try target.restoreBackup(PersonalGanttBackup.decode(encoded))
        #expect(target.tasks == source.tasks && target.workloadSettings == .unlimited)
    }

    @Test(arguments: Array(0..<6)) func malformedVersionTwoSnapshotsAreRejected(kind: Int) throws {
        let model = makeModel(WorkloadPlanStore()); try model.saveRoutine(routine())
        var snapshot = try model.makeBackup().plan
        switch kind {
        case 0: snapshot.workloadSettings = WorkloadSettings(maxScheduledMinutesPerDay: 0)
        case 1: snapshot.routines = nil
        case 2:
            let duplicate = snapshot.routines![0]
            snapshot.routines?.append(duplicate)
        case 3: snapshot.tasks[0].routineOccurrence = RoutineOccurrence(routineID: UUID(), dayKey: "other", dayStart: date(0), dayEnd: date(0, day: 8))
        case 4: snapshot.tasks[0].isCompleted = true
        default: snapshot.tasks[0].deadline = date(23)
        }
        #expect(throws: PlanStorageError.invalidSnapshot) { try snapshot.validate() }
    }

    @Test func saveFailureRetainsWarningAndRetryPersistsNewSettings() throws {
        let store = WorkloadPlanStore(); let model = makeModel(store)
        _ = try model.addTask(TaskDraft(title: "既存", deadline: date(23)))
        let before = store.value
        store.failSave = true
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        try model.saveRoutine(routine())
        #expect(model.persistenceMessage != nil && store.value == before)
        store.failSave = false; model.retryPlanSave()
        #expect(store.value?.workloadSettings == model.workloadSettings && store.value?.routines == model.routines)
        #expect(model.persistenceMessage == nil)
    }

    @Test func remindersRemainOrdinaryTasksAndShareDailyLimitWithoutNewWrites() async throws {
        let store = WorkloadPlanStore(); let model = makeModel(store)
        let provider = FakeReminderProvider(); provider.records = [ReminderFixtures.record()]
        let metadata = MemoryReminderMetadata()
        model.attachReminders(provider: provider, storage: metadata)
        #expect(await model.reminders?.applySelection(["list"]) == true)
        try model.reminders?.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 60))
        try model.saveRoutine(routine())
        #expect(model.tasks.contains { model.isReminderTask($0.id) })
        #expect(model.dailyScheduledMinutes.values.allSatisfy { $0 <= 60 })
        #expect(provider.writes.isEmpty)
    }

    private func makeModel(_ store: any PlanSnapshotStoring, provider: WorkloadCalendarProvider? = nil, clock: WorkloadClock? = nil) -> ScheduleViewModel {
        let model = ScheduleViewModel(tasks: [], calendarProvider: provider ?? WorkloadCalendarProvider(),
            calendar: ReminderFixtures.calendar, clock: { clock?.date ?? date(0) }, planStore: store)
        model.configureBackup(reminderStore: MemoryReminderMetadata(), journal: WorkloadBackupJournal(), deviceID: UUID())
        return model
    }
    private func routine() -> Routine { Routine(title: "英語", estimatedMinutesPerDay: 30, startDate: date(0), endDate: date(0, day: 9), recurrence: .daily) }
    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date { ReminderFixtures.date(hour, minute, day: day) }
}

@MainActor private final class WorkloadClock {
    var date: Date
    init(date: Date) { self.date = date }
}

@MainActor private final class WorkloadPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    var failSave = false
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws {
        if failSave { throw PlanStorageError.unavailable }
        try snapshot.validate(); value = snapshot
    }
}

@MainActor private final class WorkloadBackupJournal: BackupJournalStoring {
    var value: PersonalGanttBackup?
    func load() throws -> PersonalGanttBackup? { value }
    func save(_ backup: PersonalGanttBackup) throws { value = backup }
    func remove() throws { value = nil }
}

@MainActor private final class WorkloadCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var fail = false
    var reads = 0
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] {
        reads += 1
        if fail { throw GoogleCalendarError.network }
        return [CalendarSource(id: "work", title: "合成予定", accountTitle: "テスト")]
    }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        reads += 1
        if fail { throw GoogleCalendarError.network }
        return [FixedEvent(id: "fixed", calendarID: "work", title: "合成予定", start: ReminderFixtures.date(8), end: ReminderFixtures.date(10))]
    }
}
