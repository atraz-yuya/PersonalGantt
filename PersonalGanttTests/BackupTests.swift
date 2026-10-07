import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct BackupTests {
    @Test func completeFileRoundTripAndLegacyMetadataDecode() throws {
        let source = makeModel()
        let task = try source.model.addTask(TaskDraft(title: "合成バックアップTask", deadline: date(23)))
        let backup = try source.model.makeBackup()
        let data = try backup.encoded()
        #expect(try PersonalGanttBackup.decode(data) == backup)
        #expect(backup.plan.tasks[0].id == task.id && backup.plan.blocks.count == 1)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("accessToken") && !text.contains("refreshToken") && !text.contains("clientSecret"))
        let old = try JSONDecoder().decode(ReminderLocalState.self, from: Data(#"{"selectedListIDs":[],"metadata":{}}"#.utf8))
        #expect(old.pendingTransfer == nil)
    }

    @Test(arguments: Array(0..<5)) func invalidFilesNeverChangeTarget(kind: Int) throws {
        let source = makeModel(); var backup = try source.model.makeBackup()
        switch kind {
        case 0: backup.version = 999
        case 1: backup.format = "other-app"
        case 2: backup.plan.version = 2
        case 3: backup.plan.tasks = [PersonalGantt.Task(title: " ", estimatedMinutes: 60, deadline: date(23))]
        default: backup.reminders.metadata[""] = ReminderFixtures.metadata()
        }
        let target = makeModel()
        let before = target.model.result
        #expect(throws: BackupError.invalidFile) { try target.model.restoreBackup(backup) }
        #expect(target.model.result == before && target.plan.saves == 0 && target.metadata.saves == 0)
        #expect(throws: BackupError.invalidFile) { try PersonalGanttBackup.decode(Data("invalid".utf8)) }
    }

    @Test func separateDevicesTransferTasksCompletionAndDeletionWithoutRemoteWrites() throws {
        let source = makeModel()
        let task = try source.model.addTask(TaskDraft(title: "合成Task", estimatedMinutesText: "90", deadline: date(23)))
        let target = makeModel()
        try target.model.restoreBackup(source.model.makeBackup())
        #expect(target.model.tasks == source.model.tasks && target.model.result == source.model.result)
        source.model.toggleCompletion(id: task.id)
        try target.model.restoreBackup(source.model.makeBackup())
        #expect(target.model.tasks[0].isCompleted && target.model.result.blocks.isEmpty)
        source.model.deleteTask(id: task.id)
        try target.model.restoreBackup(source.model.makeBackup())
        #expect(target.model.tasks.isEmpty && target.journal.value == nil)
    }

    @Test func importKeepsDestinationBegunWorkAndArchivedTitle() throws {
        let target = makeModel(now: date(8, 30))
        let local = try target.model.addTask(TaskDraft(title: "端末の開始済みTask", deadline: date(23)))
        let begun = try #require(target.model.result.blocks.first)
        let source = makeModel()
        _ = try source.model.addTask(TaskDraft(title: "受け渡すTask", deadline: date(23)))
        try target.model.restoreBackup(source.model.makeBackup())
        #expect(target.model.result.blocks.contains(begun))
        #expect(target.model.title(for: local.id) == "端末の開始済みTask")
        #expect(target.model.tasks.allSatisfy { $0.id != local.id })
    }

    @Test func failedTargetSaveRollsBackBothStoresAndMemory() throws {
        let target = makeModel()
        _ = try target.model.addTask(TaskDraft(title: "復元前のTask", deadline: date(23)))
        let before = try target.model.makeBackup()
        let source = makeModel()
        _ = try source.model.addTask(TaskDraft(title: "復元後のTask", deadline: date(23)))
        target.plan.failNextSave = true
        #expect(throws: BackupError.writeFailed) { try target.model.restoreBackup(source.model.makeBackup()) }
        #expect(target.model.tasks == before.plan.tasks && target.plan.value == before.plan)
        #expect(target.metadata.state == before.reminders && target.journal.value == nil)
    }

    @Test func journalFailureCannotMutateEitherStore() throws {
        let target = makeModel(); target.journal.failSave = true
        let source = makeModel()
        #expect(throws: BackupError.unavailable) { try target.model.restoreBackup(source.model.makeBackup()) }
        #expect(target.plan.saves == 0 && target.metadata.saves == 0)
    }

    @Test func interruptedRestoreLocksFurtherWritesThenStartupRecoveryRestoresOldPair() throws {
        let target = makeModel()
        _ = try target.model.addTask(TaskDraft(title: "以前の合成Task", deadline: date(23)))
        let before = try target.model.makeBackup()
        let source = makeModel(); target.plan.failAlways = true
        #expect(throws: BackupError.recoveryRequired) { try target.model.restoreBackup(source.model.makeBackup()) }
        #expect(target.model.isBackupRecoveryRequired && !target.model.canUseBackup)
        #expect(target.journal.value == before)
        target.plan.failAlways = false
        try BackupRestoration.recover(planStore: target.plan, reminderStore: target.metadata, journal: target.journal)
        #expect(target.plan.value == before.plan && target.metadata.state == before.reminders && target.journal.value == nil)
    }

    @Test func actualDiskJournalRecoversSwiftDataAndJSONAfterInterruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try SwiftDataPlanStore(url: directory.appendingPathComponent("LocalPlan.store"))
        let metadata = FileReminderMetadataStore(url: directory.appendingPathComponent("ReminderMetadata.json"))
        let journal = FileBackupJournal(url: directory.appendingPathComponent("BackupRollback.json"))
        let source = makeModel()
        _ = try source.model.addTask(TaskDraft(title: "保護する合成Task", deadline: date(23)))
        let before = try source.model.makeBackup()
        try journal.save(before)
        try metadata.save(ReminderLocalState())
        try BackupRestoration.recover(planStore: plan, reminderStore: metadata, journal: journal)
        #expect(try plan.load() == before.plan)
        #expect(try metadata.load() == before.reminders)
        #expect(try journal.load() == nil)
    }

    @Test func uniqueExternalIDTransfersSettingsAcrossDifferentLocalListAndTaskIDs() throws {
        let sourceID = UUID()
        var source = ReminderLocalState(selectedListIDs: ["source-list"])
        source.metadata["source-r"] = ReminderTaskMetadata(taskID: sourceID, externalIdentifier: "stable", listID: "source-list",
            estimatedMinutes: 90, deadlineOverride: date(23), isExcluded: true)
        let record = ReminderFixtures.record("destination-r", list: "destination-list", external: "stable")
        let local = try ReminderTaskMapper.reconcile([record], state: ReminderLocalState(selectedListIDs: ["destination-list"]))
        let resolved = try ReminderTransferMapper.importState(source, into: local, sameDevice: false, records: [record])
        #expect(resolved.state.selectedListIDs == ["destination-list"])
        #expect(resolved.state.metadata[record.id]?.estimatedMinutes == 90 && resolved.state.metadata[record.id]?.isExcluded == true)
        #expect(resolved.state.metadata[record.id]?.deadlineOverride == nil)
        #expect(resolved.taskIDs[sourceID] == local.metadata[record.id]?.taskID)
        #expect(resolved.state.pendingTransfer == nil)
    }

    @Test func missingDuplicateOrAmbiguousExternalIDsRemainPendingWithoutTitleMatching() throws {
        for external in [nil, "", "stable"] as [String?] {
            var source = ReminderLocalState()
            source.metadata["source"] = ReminderTaskMetadata(taskID: UUID(), externalIdentifier: external, listID: "foreign", estimatedMinutes: 120)
            let records = [ReminderFixtures.record("a", external: "stable"), ReminderFixtures.record("b", external: "stable")]
            let local = try ReminderTaskMapper.reconcile(records, state: ReminderLocalState())
            let resolved = try ReminderTransferMapper.importState(source, into: local, sameDevice: false, records: records)
            #expect(resolved.state.pendingTransfer?.count == 1 && resolved.taskIDs.isEmpty)
            #expect(resolved.state.metadata.values.allSatisfy { $0.estimatedMinutes == nil })
        }
    }

    @Test func recurringNextOccurrenceReceivesEstimateWithoutCreditingPreviousWork() throws {
        let record = ReminderFixtures.record("target", external: "stable", recurring: true, occurrence: "next")
        var source = ReminderLocalState()
        source.metadata["source"] = ReminderTaskMetadata(taskID: UUID(), externalIdentifier: "stable", listID: "foreign",
            estimatedMinutes: 90, occurrenceKey: "previous")
        let local = try ReminderTaskMapper.reconcile([record], state: ReminderLocalState())
        let transferred = try ReminderTransferMapper.importState(source, into: local, sameDevice: false, records: [record])
        #expect(transferred.state.metadata[record.id]?.estimatedMinutes == 90)
        #expect(transferred.taskIDs.isEmpty && transferred.reminderIDs.isEmpty)
        #expect(transferred.state.metadata[record.id]?.occurrenceKey == "next")
    }

    @Test func sameDeviceRestoreRetainsOriginalAssociationAndSelection() throws {
        var source = ReminderLocalState(selectedListIDs: ["old-list"])
        source.metadata["r"] = ReminderFixtures.metadata()
        let transferred = try ReminderTransferMapper.importState(source, into: ReminderLocalState(selectedListIDs: ["new-list"]),
            sameDevice: true, records: [])
        #expect(transferred.state == source && transferred.taskIDs.isEmpty)
    }

    @Test func cyclicTransferAliasesAreRejectedBeforeAnyRestore() {
        let first = UUID(); let second = UUID()
        var state = ReminderLocalState()
        state.transferAliases = [first: second, second: first]
        #expect(throws: ReminderServiceError.localStorage) { try state.validate() }
        state.transferAliases = [first: second]
        #expect(throws: Never.self) { try state.validate() }
    }

    @Test func deferredTransferWithMissingNativeDeadlineKeepsImportedHistoryTitleAndSaves() async throws {
        let source = makeModel(now: date(8, 30))
        let sourceProvider = FakeReminderProvider(); sourceProvider.records = [ReminderFixtures.record("source", external: "stable")]
        source.model.attachReminders(provider: sourceProvider, storage: source.metadata)
        #expect(await source.model.reminders?.applySelection(["list"]) == true)
        try source.model.reminders?.configure(identifier: "source", estimatedMinutesText: "60", deadlineOverride: nil)
        let backup = try source.model.makeBackup()
        let target = makeModel(now: date(8, 30))
        let provider = FakeReminderProvider(); provider.records = [ReminderFixtures.record("destination", deadline: nil, external: "stable")]
        target.metadata.state.selectedListIDs = ["list"]
        target.model.attachReminders(provider: provider, storage: target.metadata)
        try target.model.restoreBackup(backup)
        await target.model.reminders?.refresh()
        let block = try #require(target.model.result.blocks.first)
        #expect(target.model.tasks.isEmpty && target.model.title(for: block.taskID) == "合成Task")
        #expect(target.model.persistenceMessage == nil && target.plan.value?.blocks == target.model.result.blocks)
    }

    @Test func restartBetweenMetadataAndPlanPublicationRecoversTransferredIdentity() async throws {
        let target = makeModel(now: date(8, 30))
        let task = try target.model.addTask(TaskDraft(title: "合成履歴", deadline: date(23)))
        let originalBlock = try #require(target.model.result.blocks.first)
        target.plan.value?.tasks[0].reminderIdentifier = "source"
        target.plan.value?.reminderTaskIDs = [task.id]
        let record = ReminderFixtures.record("destination", external: "stable")
        let newID = UUID()
        target.metadata.state.selectedListIDs = ["list"]
        target.metadata.state.metadata[record.id] = ReminderTaskMetadata(taskID: newID, externalIdentifier: "stable", listID: "list", estimatedMinutes: 60)
        target.metadata.state.transferAliases = [task.id: newID]
        let provider = FakeReminderProvider(); provider.records = [record]
        let reopened = ScheduleViewModel(tasks: [], calendarProvider: BackupCalendarProvider(), calendar: ReminderFixtures.calendar,
            clock: { self.date(8, 30) }, planStore: target.plan)
        reopened.attachReminders(provider: provider, storage: target.metadata)
        await reopened.reminders?.refresh()
        #expect(reopened.result.blocks == [ScheduledBlock(taskID: newID, start: originalBlock.start, end: originalBlock.end)])
        #expect(reopened.scheduledMinutes(for: newID) == 60 && reopened.persistenceMessage == nil)
    }

    @Test func delayedReminderReadRemapsImportedHistoryWithoutDuplicatingAllocationOrWritingCompletion() async throws {
        let source = makeModel(now: date(8, 30))
        let sourceProvider = FakeReminderProvider(); sourceProvider.records = [ReminderFixtures.record("source", external: "stable")]
        source.model.attachReminders(provider: sourceProvider, storage: source.metadata)
        #expect(await source.model.reminders?.applySelection(["list"]) == true)
        try source.model.reminders?.configure(identifier: "source", estimatedMinutesText: "60", deadlineOverride: nil)
        await source.model.loadCalendarState() // Confirm the plan so its begun block is protected.
        let backup = try source.model.makeBackup()
        let target = makeModel(now: date(8, 30))
        let provider = FakeReminderProvider(); provider.records = [ReminderFixtures.record("destination", external: "stable")]
        target.metadata.state.selectedListIDs = ["list"]
        target.model.attachReminders(provider: provider, storage: target.metadata)
        try target.model.restoreBackup(backup)
        #expect(target.model.reminders?.pendingTransferCount == 1)
        await target.model.reminders?.refresh()
        let task = try #require(target.model.tasks.first)
        #expect(task.reminderIdentifier == "destination" && task.estimatedMinutes == 60)
        #expect(target.model.result.blocks.count == 1 && target.model.scheduledMinutes(for: task.id) == 60)
        #expect(target.model.reminders?.pendingTransferCount == 0 && provider.writes.isEmpty)
    }

    private func makeModel(now: Date = ReminderFixtures.date(0)) -> (model: ScheduleViewModel, plan: BackupPlanStore, metadata: MemoryReminderMetadata, journal: BackupMemoryJournal) {
        let plan = BackupPlanStore(); let metadata = MemoryReminderMetadata(); let journal = BackupMemoryJournal()
        let model = ScheduleViewModel(tasks: [], calendarProvider: BackupCalendarProvider(), calendar: ReminderFixtures.calendar,
            clock: { now }, planStore: plan)
        model.configureBackup(reminderStore: metadata, journal: journal, deviceID: UUID())
        return (model, plan, metadata, journal)
    }
    private func date(_ hour: Int, _ minute: Int = 0) -> Date { ReminderFixtures.date(hour, minute) }
}

@MainActor
private final class BackupPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    var saves = 0
    var failNextSave = false
    var failAlways = false
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws {
        if failNextSave || failAlways { failNextSave = false; throw PlanStorageError.unavailable }
        try snapshot.validate(); value = snapshot; saves += 1
    }
}

@MainActor
private final class BackupMemoryJournal: BackupJournalStoring {
    var value: PersonalGanttBackup?
    var failSave = false
    func load() throws -> PersonalGanttBackup? { value }
    func save(_ backup: PersonalGanttBackup) throws { if failSave { throw BackupError.unavailable }; value = backup }
    func remove() throws { value = nil }
}

@MainActor
private final class BackupCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
