import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct TaskCreationServiceTests {
    @Test func createsTrimmedOrdinaryTaskAndRecalculatesVisibleModel() throws {
        let store = IntentPlanStore()
        let model = makeModel(store)
        let service = TaskCreationService(model: model)
        let receipt = try service.create(title: " 卒論\n", estimatedMinutes: 90, deadline: date(18))
        #expect(receipt.task.title == "卒論")
        #expect(receipt.task.estimatedMinutes == 90 && receipt.task.deadline == date(18))
        #expect(!receipt.task.isCompleted && receipt.task.reminderIdentifier == nil)
        #expect(!model.isReminderTask(receipt.task.id))
        #expect(model.tasks == [receipt.task] && store.value?.tasks == model.tasks)
        #expect(model.scheduledMinutes(for: receipt.task.id) == 90)
        #expect(receipt.unallocatedMinutes == 0 && receipt.isScheduleSaved)
        #expect(receipt.dialogText.contains("卒論を90分"))
        let next = try service.create(title: "卒論", estimatedMinutes: 90, deadline: date(18))
        #expect(next.task.id != receipt.task.id)
    }

    @Test(arguments: ["", " \n\t"])
    func emptyTitleUsesUIValidation(title: String) throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        let draft = TaskDraft(title: title, deadline: date(18))
        #expect(throws: TaskInputError.emptyTitle) { try model.addTask(draft) }
        #expect(throws: TaskInputError.emptyTitle) {
            try TaskCreationService(model: model).create(title: title, estimatedMinutes: 60, deadline: date(18))
        }
        #expect(model.tasks.isEmpty && store.saves == 0)
    }

    @Test(arguments: [0, -1, Int.min])
    func invalidMinutesUsesUIValidation(minutes: Int) throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        let draft = TaskDraft(title: "作業", estimatedMinutesText: String(minutes), deadline: date(18))
        #expect(throws: TaskInputError.invalidMinutes) { try model.addTask(draft) }
        #expect(throws: TaskInputError.invalidMinutes) {
            try TaskCreationService(model: model).create(title: "作業", estimatedMinutes: minutes, deadline: date(18))
        }
        #expect(model.tasks.isEmpty && store.saves == 0)
    }

    @Test func largestIntegerDoesNotOverflowSchedulingOrDialog() throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        let receipt = try TaskCreationService(model: model).create(title: "作業", estimatedMinutes: Int.max, deadline: date(18))
        #expect(receipt.task.estimatedMinutes == Int.max)
        #expect(receipt.unallocatedMinutes.isFinite && receipt.unallocatedMinutes > 0)
        #expect(receipt.dialogText.contains("配置できませんでした"))
        #expect(store.value?.tasks == [receipt.task])
        #expect(throws: TaskInputError.invalidMinutes) {
            try TaskDraft(title: "作業", estimatedMinutesText: String(Int.max) + "0", deadline: date(18)).validated()
        }
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan])
    func invalidDateUsesUIValidation(interval: Double) throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        let deadline = Date(timeIntervalSinceReferenceDate: interval)
        #expect(throws: TaskInputError.invalidDeadline) { try model.addTask(TaskDraft(title: "作業", deadline: deadline)) }
        #expect(throws: TaskInputError.invalidDeadline) {
            try TaskCreationService(model: model).create(title: "作業", estimatedMinutes: 60, deadline: deadline)
        }
        #expect(model.tasks.isEmpty && store.saves == 0)
    }

    @Test func pastDeadlineRemainsValidButUnallocatedAndSaved() throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        let deadline = date(0, day: 6)
        let receipt = try TaskCreationService(model: model).create(title: "過去締切", estimatedMinutes: 60, deadline: deadline)
        #expect(receipt.task.deadline == deadline && receipt.unallocatedMinutes == 60)
        #expect(model.result.blocks.isEmpty && store.value?.tasks == [receipt.task])
        #expect(receipt.dialogText.contains("60分配置できませんでした"))
    }

    @Test func swiftDataReopenRestoresIntentTaskAndSchedule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LocalPlan.store")
        let model = makeModel(try SwiftDataPlanStore(url: url))
        let receipt = try TaskCreationService(model: model).create(title: "Kaggle", estimatedMinutes: 60, deadline: date(23))
        let reopened = makeModel(try SwiftDataPlanStore(url: url))
        #expect(reopened.tasks == [receipt.task])
        #expect(reopened.result == model.result && reopened.isRestoredPlan)
    }

    @Test func cachedCalendarIsAvoidedWithoutAdditionalNetworkCalls() async throws {
        let store = IntentPlanStore(); let provider = IntentCalendarProvider()
        let model = makeModel(store, provider: provider)
        #expect(await model.applyCalendarSelection(["work"]))
        let reads = provider.reads
        let receipt = try TaskCreationService(model: model).create(title: "卒論", estimatedMinutes: 180, deadline: date(18))
        #expect(provider.reads == reads && provider.accessRequests == 0)
        #expect(model.scheduledMinutes(for: receipt.task.id) == 180)
        #expect(model.result.blocks.allSatisfy { block in
            model.fixedEvents.allSatisfy { !(block.start < $0.end && $0.start < block.end) }
        })
        #expect(store.value?.blocks == model.result.blocks)
    }

    @Test func noCalendarCacheSavesTaskAndUsesProvisionalSlotsOffline() throws {
        let store = IntentPlanStore(); let provider = IntentCalendarProvider(); provider.fail = true
        let model = makeModel(store, provider: provider)
        let receipt = try TaskCreationService(model: model).create(title: "AtCoder", estimatedMinutes: 30, deadline: date(18))
        #expect(model.lastCalendarRefresh == nil && model.scheduledMinutes(for: receipt.task.id) == 30)
        #expect(store.value?.tasks == [receipt.task] && provider.reads == 0 && provider.accessRequests == 0)
    }

    @Test func failedCalendarRefreshDoesNotPreventTaskCreationOrEraseCache() async throws {
        let store = IntentPlanStore(); let provider = IntentCalendarProvider()
        let model = makeModel(store, provider: provider)
        #expect(await model.applyCalendarSelection(["work"]))
        let slots = model.availableSlots; let events = model.fixedEvents
        provider.fail = true
        await model.refreshCalendars()
        let reads = provider.reads
        let receipt = try TaskCreationService(model: model).create(title: "セキスペ", estimatedMinutes: 60, deadline: date(18))
        #expect(provider.reads == reads && model.calendarMessage != nil)
        #expect(model.availableSlots == slots && model.fixedEvents == events)
        #expect(store.value?.tasks == [receipt.task] && model.scheduledMinutes(for: receipt.task.id) == 60)
    }

    @Test func noCapacityStillSavesRequirementAndReportsUnallocatedTime() throws {
        let store = IntentPlanStore()
        let model = ScheduleViewModel(tasks: [], availableSlots: [])
        model.attachPlanStore(store)
        let receipt = try TaskCreationService(model: model).create(title: "卒論", estimatedMinutes: 60, deadline: date(18))
        #expect(store.value?.tasks == [receipt.task] && model.result.blocks.isEmpty)
        #expect(receipt.unallocatedMinutes == 60 && receipt.isScheduleSaved)
        #expect(store.value?.unscheduledTaskIDs == [receipt.task.id])
    }

    @Test func failedInitialSaveDoesNotPublishTaskOrModifyExistingPlan() throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        let existing = try model.addTask(TaskDraft(title: "既存", deadline: date(18)))
        let before = store.value; let result = model.result
        store.failFromSave = store.saves + 1
        #expect(throws: PlanStorageError.unavailable) {
            try TaskCreationService(model: model).create(title: "未保存", estimatedMinutes: 60, deadline: date(18))
        }
        #expect(model.tasks == [existing] && model.result == result && store.value == before)
    }

    @Test func failedScheduleSaveKeepsDurableTaskAndReturnsSeparateWarning() throws {
        let store = IntentPlanStore(); let model = makeModel(store)
        store.failFromSave = 2
        let receipt = try TaskCreationService(model: model).create(title: "保存済み", estimatedMinutes: 60, deadline: date(18))
        #expect(store.value?.tasks == [receipt.task] && store.value?.blocks.isEmpty == true)
        #expect(model.scheduledMinutes(for: receipt.task.id) == 60)
        #expect(!receipt.isScheduleSaved && receipt.dialogText.contains("タスクは保存済み"))
        let reopened = makeModel(store)
        #expect(reopened.tasks == [receipt.task])
        store.failFromSave = nil
        model.retryPlanSave()
        #expect(store.value?.blocks == model.result.blocks && model.persistenceMessage == nil)
    }

    @Test func missingOrUnreadableStoreCannotReportSuccess() throws {
        let missing = ScheduleViewModel(tasks: [], availableSlots: [])
        #expect(throws: PlanStorageError.unavailable) {
            try TaskCreationService(model: missing).create(title: "作業", estimatedMinutes: 60, deadline: date(18))
        }
        let store = IntentPlanStore(); store.failLoad = true
        let blocked = makeModel(store)
        #expect(throws: PlanStorageError.unavailable) {
            try TaskCreationService(model: blocked).create(title: "作業", estimatedMinutes: 60, deadline: date(18))
        }
        #expect(missing.tasks.isEmpty && blocked.tasks.isEmpty && store.saves == 0)
    }

    private func makeModel(_ store: any PlanSnapshotStoring, provider: IntentCalendarProvider? = nil) -> ScheduleViewModel {
        ScheduleViewModel(tasks: [], calendarProvider: provider ?? IntentCalendarProvider(),
                          calendar: ReminderFixtures.calendar, clock: { date(0) }, planStore: store)
    }
    private func date(_ hour: Int, day: Int = 7) -> Date { ReminderFixtures.date(hour, day: day) }
}

@MainActor
private final class IntentPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    var saves = 0
    var failLoad = false
    var failFromSave: Int?
    func load() throws -> PlanSnapshot? {
        if failLoad { throw PlanStorageError.unavailable }
        return value
    }
    func save(_ snapshot: PlanSnapshot) throws {
        saves += 1
        if let failFromSave, saves >= failFromSave { throw PlanStorageError.unavailable }
        try snapshot.validate()
        value = snapshot
    }
}

@MainActor
private final class IntentCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var reads = 0
    var accessRequests = 0
    var fail = false
    func requestAccess() async throws -> CalendarAuthorization { accessRequests += 1; return authorization }
    func loadCalendars() async throws -> [CalendarSource] {
        reads += 1
        if fail { throw GoogleCalendarError.network }
        return [CalendarSource(id: "work", title: "合成Calendar", accountTitle: "テスト")]
    }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        reads += 1
        if fail { throw GoogleCalendarError.network }
        return [FixedEvent(id: "fixed", calendarID: "work", title: "合成予定",
                           start: ReminderFixtures.date(9), end: ReminderFixtures.date(12))]
    }
}
