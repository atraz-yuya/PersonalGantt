import Foundation
import SwiftData
import Testing
@testable import PersonalGantt

@MainActor
struct PlanPersistenceTests {
    @Test func swiftDataDiskRoundTripReopensAndReplacesOneCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LocalPlan.store")
        let first = try SwiftDataPlanStore(url: url)
        #expect(try first.load() == nil)
        var value = fixture()
        try first.save(value)
        #expect(try SwiftDataPlanStore(url: url).load() == value)
        value.tasks[0].title = "変更後の合成Task"
        value.tasks[0].isCompleted = true
        value.blocks = []
        try first.save(value)
        #expect(try SwiftDataPlanStore(url: url).load() == value)
    }

    @Test func invalidSaveCannotReplaceLastGoodCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataPlanStore(url: directory.appendingPathComponent("LocalPlan.store"))
        let good = fixture()
        try store.save(good)
        var invalid = good; invalid.tasks[0].estimatedMinutes = 0
        #expect(throws: PlanStorageError.invalidSnapshot) { try store.save(invalid) }
        #expect(try store.load() == good)
    }

    @Test(arguments: Array(0..<10)) func snapshotRejectsInvalidOrNewerData(kind: Int) throws {
        var value = fixture()
        switch kind {
        case 0: value.version = 2
        case 1: value.tasks.append(value.tasks[0])
        case 2: value.tasks[0].title = " "
        case 3: value.blocks[0].end = value.blocks[0].start
        case 4: value.blocks.append(value.blocks[0])
        case 5: value.reminderTaskIDs = [value.tasks[0].id]
        case 6: value.unscheduledTaskIDs = [UUID()]
        case 7: value.planningEnd = nil
        case 8: value.slots[0].end = value.slots[0].start
        default: value.fixedEvents[0].calendarID = "unknown"
        }
        #expect(throws: (kind == 0 ? PlanStorageError.unsupportedVersion : .invalidSnapshot)) { try value.validate() }
    }

    @Test func unreadablePayloadIsNotAnEmptyStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LocalPlan.store")
        let schema = Schema(versionedSchema: LocalPlanSchemaV1.self)
        let container = try ModelContainer(for: schema, migrationPlan: LocalPlanMigrationPlan.self,
            configurations: [ModelConfiguration("LocalPlan", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.insert(LocalPlanSchemaV1.Checkpoint(payload: Data("not a checkpoint".utf8)))
        try context.save()
        #expect(throws: PlanStorageError.invalidSnapshot) { try SwiftDataPlanStore(url: url).load() }
    }

    @Test func manualCRUDAndCompletionSurviveSeparateViewModels() throws {
        let store = MemoryPlanStore()
        var model = makeModel(store: store)
        let task = try model.addTask(TaskDraft(title: "合成手動Task", estimatedMinutesText: "60", deadline: date(23)))
        model = makeModel(store: store)
        #expect(model.tasks.first?.id == task.id)
        try model.updateTask(id: task.id, draft: TaskDraft(title: "編集したTask", estimatedMinutesText: "90", deadline: date(22)))
        model = makeModel(store: store)
        #expect(model.tasks.first?.title == "編集したTask" && model.tasks.first?.estimatedMinutes == 90)
        model.toggleCompletion(id: task.id)
        model = makeModel(store: store)
        #expect(model.tasks.first?.isCompleted == true && model.result.blocks.isEmpty)
        model.toggleCompletion(id: task.id)
        model.deleteTask(id: task.id)
        model = makeModel(store: store)
        #expect(model.tasks.isEmpty && model.result.blocks.isEmpty)
    }

    @Test func restartKeepsPastAndCurrentBlocksAndDeletedTitleDuringRefresh() async throws {
        let store = MemoryPlanStore(); store.value = fixture()
        let provider = PersistenceCalendarProvider()
        provider.events = [FixedEvent(id: "new", calendarID: "work", title: "新しい合成予定", start: date(8), end: date(12))]
        let model = makeModel(store: store, provider: provider, now: date(8, 30))
        let old = model.result.blocks
        #expect(model.isRestoredPlan && model.fixedEvents == fixture().fixedEvents)
        model.deleteTask(id: fixture().tasks[0].id)
        #expect(model.result.blocks == old)
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(model.result.blocks == old && model.protectedConflictCount == 1)
        let reopened = makeModel(store: store, now: date(9))
        #expect(reopened.result.blocks == old)
        #expect(reopened.title(for: fixture().tasks[0].id) == "合成Task")
    }

    @Test func offlineActivationAndDayChangeRetainCachedPlanWithoutPrompt() async {
        let store = MemoryPlanStore(); store.value = fixture()
        let provider = PersistenceCalendarProvider(); provider.authorization = .signedOut
        let model = makeModel(store: store, provider: provider, now: date(0, day: 9))
        let before = model.result
        await model.applicationDidBecomeActive()
        await model.refreshForDayChangeIfNeeded()
        #expect(model.result == before && model.fixedEvents == fixture().fixedEvents)
        #expect(model.isRestoredPlan && provider.reads == 0 && provider.accessRequests == 0)
    }

    @Test func persistedHistoryAndCurrentWorkSurviveWhileFutureWorkMoves() async throws {
        let store = MemoryPlanStore(); var saved = fixture()
        let historicalID = UUID()
        let futureTask = PersonalGantt.Task(title: "未来の合成Task", estimatedMinutes: 60, deadline: date(23))
        let past = ScheduledBlock(taskID: historicalID, start: date(8, day: 6), end: date(9, day: 6))
        let current = saved.blocks[0]
        saved.archivedTitles[historicalID] = "過去の合成Task"
        saved.tasks.append(futureTask)
        saved.blocks = [past, current, ScheduledBlock(taskID: futureTask.id, start: date(9), end: date(10))]
        store.value = saved
        let provider = PersistenceCalendarProvider()
        provider.events = [FixedEvent(id: "new", calendarID: "work", title: "合成予定", start: date(8), end: date(12))]
        let model = makeModel(store: store, provider: provider, now: date(8, 30))
        await model.refreshCalendars()
        #expect(model.result.blocks == [past, current, ScheduledBlock(taskID: futureTask.id, start: date(12), end: date(13))])
        let reopened = makeModel(store: store, now: date(13))
        #expect(reopened.result == model.result && reopened.title(for: historicalID) == "過去の合成Task")
    }

    @Test func failedRefreshPreservesCheckpointThenSuccessfulRefreshReplansFutureOnly() async throws {
        let store = MemoryPlanStore(); store.value = fixture()
        let provider = PersistenceCalendarProvider(); provider.fail = true
        let model = makeModel(store: store, provider: provider)
        let before = try #require(store.value)
        await model.refreshCalendars()
        #expect(model.result.blocks == before.blocks && store.value == before)
        provider.fail = false
        provider.events = [FixedEvent(id: "new", calendarID: "work", title: "合成予定", start: date(8), end: date(12))]
        await model.refreshCalendars()
        #expect(model.result.blocks.first?.start == date(12))
        #expect(!model.isRestoredPlan && store.value?.fixedEvents == provider.events)
    }

    @Test func storageFailureShowsUnsavedStateAndRetrySavesLatestWithoutReplanning() throws {
        let store = MemoryPlanStore(); store.value = fixture()
        let model = makeModel(store: store)
        store.failSave = true
        try model.updateTask(id: fixture().tasks[0].id, draft: TaskDraft(title: "未保存の合成変更", estimatedMinutesText: "90", deadline: date(23)))
        #expect(model.persistenceMessage != nil && store.value == fixture())
        let result = model.result
        store.failSave = false; model.retryPlanSave()
        #expect(model.persistenceMessage == nil && store.value?.tasks[0].title == "未保存の合成変更")
        #expect(model.result == result)
    }

    @Test func loadFailureLocksStoreAndNeverOverwritesOldData() throws {
        let store = MemoryPlanStore(); store.value = fixture(); store.failLoad = true
        let model = makeModel(store: store)
        #expect(model.isPlanStorageBlocked && model.persistenceMessage != nil)
        _ = try model.addTask(TaskDraft(title: "メモリ内だけの合成Task", deadline: date(23)))
        model.retryPlanSave()
        #expect(store.saves == 0 && store.value == fixture())
    }

    @Test func changedAccountOrSelectionDoesNotRestoreOldAvailabilityOrFuturePlan() {
        let store = MemoryPlanStore(); store.value = fixture()
        let differentScope = makeModel(store: store, now: date(8, 30), scope: "new-account")
        #expect(differentScope.result.blocks == fixture().blocks)
        #expect(differentScope.result.unscheduledTaskIDs.isEmpty)
        #expect(differentScope.availableSlots.isEmpty && differentScope.fixedEvents.isEmpty)
        let selection = PersistenceCalendarSelection(); selection.ids = ["other"]
        let differentSelection = makeModel(store: store, selection: selection)
        #expect(differentSelection.result.blocks.isEmpty && differentSelection.availableSlots.isEmpty)
        #expect(differentSelection.selectedCalendarIDs == ["other"])
    }

    @Test func restoredRemindersAreReadOnlyUntilFreshImportAndFailureRetainsThem() async throws {
        let store = MemoryPlanStore(); var saved = fixture()
        saved.tasks[0].reminderIdentifier = "r"; saved.reminderTaskIDs = [saved.tasks[0].id]; store.value = saved
        let metadata = MemoryReminderMetadata()
        metadata.state.selectedListIDs = ["list"]
        metadata.state.metadata["r"] = ReminderTaskMetadata(taskID: saved.tasks[0].id, listID: "list", estimatedMinutes: 60)
        let provider = FakeReminderProvider(); provider.records = [ReminderFixtures.record()]; provider.failRecords = true
        let model = makeModel(store: store)
        model.attachReminders(provider: provider, storage: metadata)
        let task = try #require(model.tasks.first)
        #expect(model.taskIsBusy(task.id) && !model.canToggleTask(task))
        #expect(throws: ReminderServiceError.reminderUnavailable) { try model.updateTask(id: task.id, draft: TaskDraft(task: task)) }
        model.deleteTask(id: task.id); await model.toggleTaskCompletion(id: task.id)
        #expect(model.tasks == saved.tasks && provider.writes.isEmpty)
        await model.reminders?.refresh()
        #expect(model.tasks == saved.tasks)
        provider.failRecords = false; await model.reminders?.refresh()
        let refreshedTask = try #require(model.tasks.first)
        #expect(!model.taskIsBusy(task.id) && model.canToggleTask(refreshedTask))
        await model.toggleTaskCompletion(id: task.id)
        #expect(provider.writes.count == 1 && store.value?.tasks.first?.isCompleted == true)
    }

    private func fixture() -> PlanSnapshot {
        let task = PersonalGantt.Task(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "合成Task", estimatedMinutes: 60, deadline: date(23))
        return PlanSnapshot(savedAt: date(0), tasks: [task], reminderTaskIDs: [],
            blocks: [ScheduledBlock(taskID: task.id, start: date(8), end: date(9))], unscheduledTaskIDs: [], archivedTitles: [:],
            slots: [AvailableSlot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, start: date(8), end: date(23))],
            calendars: [CalendarSource(id: "work", title: "合成Calendar", accountTitle: "テスト")], selectedCalendarIDs: ["work"],
            fixedEvents: [FixedEvent(id: "fixed", calendarID: "work", title: "合成予定", start: date(10), end: date(12))],
            planningStart: date(0), planningEnd: date(0, day: 21), lastCalendarRefresh: date(0), hasConfirmedPlan: true, calendarScope: "scope")
    }

    private func makeModel(store: MemoryPlanStore, provider: PersistenceCalendarProvider? = nil,
                           now: Date = ReminderFixtures.date(0), scope: String = "scope", selection: PersistenceCalendarSelection? = nil) -> ScheduleViewModel {
        ScheduleViewModel(tasks: [], calendarProvider: provider ?? PersistenceCalendarProvider(), calendar: ReminderFixtures.calendar, clock: { now },
                          selectionStore: selection, selectionScope: scope, planStore: store)
    }
    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date { ReminderFixtures.date(hour, minute, day: day) }
}

@MainActor
private final class MemoryPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    var failLoad = false
    var failSave = false
    var saves = 0
    func load() throws -> PlanSnapshot? {
        if failLoad { throw PlanStorageError.unavailable }; return value
    }
    func save(_ snapshot: PlanSnapshot) throws {
        if failSave { throw PlanStorageError.unavailable }
        try snapshot.validate(); value = snapshot; saves += 1
    }
}

@MainActor
private final class PersistenceCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var events: [FixedEvent] = []
    var fail = false
    var reads = 0
    var accessRequests = 0
    func requestAccess() async throws -> CalendarAuthorization { accessRequests += 1; return authorization }
    func loadCalendars() async throws -> [CalendarSource] {
        reads += 1
        if fail { throw CalendarServiceError.calendarUnavailable }
        return [CalendarSource(id: "work", title: "合成Calendar", accountTitle: "テスト")]
    }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { events }
}

@MainActor
private final class PersistenceCalendarSelection: CalendarSelectionStoring {
    var ids: Set<String> = []
    func load(clientID: String) -> Set<String> { ids }
    func save(_ calendarIDs: Set<String>, clientID: String) { ids = calendarIDs }
    func clear(clientID: String) { ids = [] }
}
