import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct ReminderSyncTests {
    @Test func launchChecksAuthorizationWithoutPrompting() async {
        let provider = FakeReminderProvider()
        provider.authorization = .notDetermined
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        await model.loadState()
        #expect(provider.accessRequests == 0 && provider.listLoads == 0)
    }

    @Test func explicitGrantListsSourcesButDoesNotFetchAllReminders() async {
        let provider = FakeReminderProvider()
        provider.authorization = .notDetermined
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        await model.requestAccess()
        #expect(model.authorization == .fullAccess && model.lists.count == 2)
        #expect(provider.accessRequests == 1 && provider.requestedSelections.isEmpty)
    }

    @Test func denialDoesNotReadOrEraseRequirements() async {
        let provider = FakeReminderProvider()
        provider.authorization = .notDetermined
        provider.nextAuthorization = .denied
        let storage = MemoryReminderMetadata()
        storage.state.metadata["r"] = ReminderFixtures.metadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        await model.requestAccess()
        #expect(model.authorization == .denied)
        #expect(provider.listLoads == 0 && provider.requestedSelections.isEmpty)
        #expect(storage.state.metadata["r"]?.estimatedMinutes == 60)
    }

    @Test func chosenListsOnlyAndMissingRequirementsAreInputWaiting() async {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(), ReminderFixtures.record("other-r", list: "other")]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        #expect(provider.requestedSelections == [["list"]])
        #expect(model.records.map(\.id) == ["r"])
        #expect(model.importedTasks.isEmpty && model.waitingRecords.count == 1)
        #expect(model.waitingDescription(for: model.records[0]).contains("所要時間"))
    }

    @Test func configureValidRequirementPublishesStableTaskAndRestoresIt() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let storage = MemoryReminderMetadata()
        let first = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await first.applySelection(["list"]))
        try first.configure(identifier: "r", estimatedMinutesText: "90", deadlineOverride: nil)
        let original = try #require(first.importedTasks.first)
        let second = ReminderSyncViewModel(provider: provider, storage: storage)
        await second.loadState()
        #expect(second.importedTasks == [original])
        #expect(second.selectedListIDs == ["list"])
        #expect(provider.accessRequests == 0)
    }

    @Test func localDeadlineIsOnlyUsedForMissingSourceDeadline() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(deadline: nil)]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        #expect(model.waitingRecords.count == 1)
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: ReminderFixtures.date(20))
        #expect(model.importedTasks.first?.deadline == ReminderFixtures.date(20))
        provider.records = [ReminderFixtures.record(deadline: ReminderFixtures.date(21))]
        await model.refresh()
        #expect(model.importedTasks.first?.deadline == ReminderFixtures.date(21))
        #expect(provider.writes.isEmpty)
    }

    @Test(arguments: ["", "0", "-1", "1.5", "abc", "999999999999999999999999999"])
    func invalidMinutesDoNotMutateStoredRequirements(input: String) async {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let storage = MemoryReminderMetadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await model.applySelection(["list"]))
        let state = storage.state
        #expect(throws: TaskInputError.invalidMinutes) {
            try model.configure(identifier: "r", estimatedMinutesText: input, deadlineOverride: nil)
        }
        #expect(storage.state == state && model.importedTasks.isEmpty)
    }

    @Test func missingDeadlineAndInvalidFallbackDoNotPublishTask() async {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(deadline: nil)]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        #expect(throws: TaskInputError.invalidDeadline) {
            try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        }
        #expect(throws: TaskInputError.invalidDeadline) {
            try model.configure(identifier: "r", estimatedMinutesText: "60",
                                deadlineOverride: Date(timeIntervalSinceReferenceDate: .infinity))
        }
        #expect(model.importedTasks.isEmpty)
    }

    @Test func sourceCompletionAndEditsUpdateTaskWithoutWritingReminder() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let id = try #require(model.importedTasks.first?.id)
        provider.records = [ReminderFixtures.record(title: "変更された合成Task", deadline: ReminderFixtures.date(20), completed: true)]
        await model.refresh()
        #expect(model.importedTasks.first?.id == id)
        #expect(model.importedTasks.first?.isCompleted == true)
        #expect(model.importedTasks.first?.title == "変更された合成Task")
        #expect(model.importedTasks.first?.deadline == ReminderFixtures.date(20))
        #expect(provider.writes.isEmpty)
    }

    @Test func localToggleWritesOnlyExpectedReminderCompletionInBothDirections() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "120", deadlineOverride: nil)
        await model.toggleCompletion(identifier: "r")
        #expect(model.importedTasks.first?.isCompleted == true)
        await model.toggleCompletion(identifier: "r")
        #expect(model.importedTasks.first?.isCompleted == false)
        #expect(provider.writes.map { $0.0 } == ["r", "r"])
        #expect(provider.writes.map { $0.1 } == ["list", "list"])
        #expect(provider.writes.map { $0.2 } == [false, true])
        #expect(provider.writes.map { $0.3 } == [true, false])
        #expect(model.importedTasks.first?.estimatedMinutes == 120)
        #expect(provider.records.first?.title == "合成Task")
        #expect(provider.records.first?.deadline == ReminderFixtures.date(23))
    }

    @Test func failedWriteDoesNotPretendCompletionOrDropPlannedWork() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let before = model.importedTasks
        provider.failCompletion = true
        await model.toggleCompletion(identifier: "r")
        #expect(model.importedTasks == before)
        #expect(model.message?.contains("保持") == true)
        #expect(provider.records.first?.isCompleted == false)
    }

    @Test func staleCompletionRejectsOverwriteAndRefreshResolvesIt() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        provider.records = [ReminderFixtures.record(completed: true)]
        await model.toggleCompletion(identifier: "r")
        #expect(model.importedTasks.first?.isCompleted == false)
        #expect(model.message?.contains("再読み込み") == true)
        await model.refresh()
        #expect(model.importedTasks.first?.isCompleted == true)
    }

    @Test func readOnlyRecordCannotAttemptAWrite() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(writable: false)]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        await model.toggleCompletion(identifier: "r")
        #expect(provider.writes.isEmpty)
        #expect(model.importedTasks.first?.isCompleted == false)
        #expect(model.message?.contains("変更できません") == true)
    }

    @Test func failedFetchSelectionOrStorageSaveKeepsEntireSnapshot() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(), ReminderFixtures.record("s", list: "other")]
        let storage = MemoryReminderMetadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let before = model.importedTasks
        let oldRecords = model.records
        let oldState = storage.state
        provider.failRecords = true
        #expect(!(await model.applySelection(["other"])))
        #expect(model.records == oldRecords && model.importedTasks == before)
        #expect(storage.state == oldState)
        provider.failRecords = false
        storage.failSave = true
        #expect(!(await model.applySelection(["other"])))
        #expect(model.selectedListIDs == ["list"] && model.importedTasks == before)
        #expect(throws: ReminderServiceError.localStorage) {
            try model.configure(identifier: "r", estimatedMinutesText: "120", deadlineOverride: nil)
        }
        #expect(model.importedTasks == before)
    }

    @Test func corruptedLocalStorageCannotBeOverwrittenByRefresh() async {
        let storage = MemoryReminderMetadata()
        storage.failLoad = true
        let provider = FakeReminderProvider()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        await model.refresh()
        await model.requestAccess()
        #expect(!model.isStorageAvailable)
        #expect(provider.listLoads == 0 && provider.accessRequests == 0 && storage.saves == 0)
    }

    @Test func missingListPrunesSelectionButKeepsLocalEstimates() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let storage = MemoryReminderMetadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        provider.lists.removeAll { $0.id == "list" }
        await model.refresh()
        #expect(model.importedTasks.isEmpty && model.selectedListIDs.isEmpty)
        #expect(storage.state.metadata["r"]?.estimatedMinutes == 60)
        #expect(model.message?.contains("除外") == true)
    }

    @Test func emptySelectionDoesNotQueryAllRemindersAndCanRestoreRequirements() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let count = provider.requestedSelections.count
        #expect(await model.applySelection([]))
        #expect(provider.requestedSelections.count == count && model.importedTasks.isEmpty)
        #expect(await model.applySelection(["list"]))
        #expect(model.importedTasks.first?.estimatedMinutes == 60)
    }

    @Test func excludedReminderDoesNotReappearOnRefreshAndCanBeReincluded() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let id = model.importedTasks.first?.id
        #expect(model.exclude(identifier: "r"))
        await model.refresh()
        #expect(model.importedTasks.isEmpty && model.isExcluded("r"))
        #expect(provider.writes.isEmpty && provider.records.count == 1)
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        #expect(model.importedTasks.first?.id == id)
    }

    @Test func removedReminderRemovesTaskWithoutDeletingLocalRequirements() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let storage = MemoryReminderMetadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        provider.records = []
        await model.refresh()
        #expect(model.importedTasks.isEmpty)
        #expect(storage.state.metadata["r"]?.estimatedMinutes == 60)
    }

    @Test func revokedPermissionRetainsImportedTasksAndNeverPrompts() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let before = model.importedTasks
        provider.authorization = .denied
        await model.loadState()
        #expect(model.importedTasks == before && provider.accessRequests == 0)
        #expect(model.message?.contains("保持") == true)
    }

    @Test func unselectedOrDuplicateRecordsCannotPartiallyPublish() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let before = model.importedTasks
        provider.unfiltered = true
        provider.records.append(ReminderFixtures.record("s", list: "other"))
        await model.refresh()
        #expect(model.importedTasks == before && model.records.count == 1)
        provider.records = [ReminderFixtures.record(), ReminderFixtures.record()]
        await model.refresh()
        #expect(model.importedTasks == before && model.records.count == 1)
    }

    @Test func cancelledFetchRetainsSnapshotAndNextFetchSucceeds() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let before = model.importedTasks
        provider.pausesNextLoad = true
        let job = _Concurrency.Task { await model.refresh() }
        await provider.waitUntilPaused()
        job.cancel()
        provider.records = [ReminderFixtures.record(title: "更新")]
        provider.resume()
        await job.value
        #expect(model.importedTasks == before)
        await model.refresh()
        #expect(model.importedTasks.first?.title == "更新")
    }

    @Test func notificationDuringCompletionIsCoalescedAndRetainsSuccessfulWrite() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record()]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        provider.onCompletion = { await model.refresh(); await model.refresh() }
        let reads = provider.requestedSelections.count
        await model.toggleCompletion(identifier: "r")
        #expect(provider.requestedSelections.count == reads + 1)
        #expect(model.importedTasks.first?.isCompleted == true)
        #expect(provider.maxConcurrentReads == 1)
    }

    @Test func recurringReminderNeedsSourceDueEvenWhenLocalOverrideIsProvided() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(deadline: nil, recurring: true)]
        let model = ReminderSyncViewModel(provider: provider, storage: MemoryReminderMetadata())
        #expect(await model.applySelection(["list"]))
        #expect(throws: TaskInputError.invalidDeadline) {
            try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: ReminderFixtures.date(23))
        }
        #expect(model.importedTasks.isEmpty)
    }

    @Test func completingRecurringReminderAppliesNextOccurrenceBeforePublishing() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(recurring: true, occurrence: "first")]
        let storage = MemoryReminderMetadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let old = try #require(model.importedTasks.first)
        provider.onCompletion = {
            provider.records = [ReminderFixtures.record(deadline: ReminderFixtures.date(23, day: 8), recurring: true, occurrence: "second")]
        }
        await model.toggleCompletion(identifier: "r")
        let next = try #require(model.importedTasks.first)
        #expect(next.id != old.id && !next.isCompleted && next.estimatedMinutes == 60)
        #expect(storage.state.metadata["r"]?.taskID == next.id)
    }

    @Test func recurringIdentityStorageFailureRetainsSnapshotAndRefreshCanRecover() async throws {
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record(recurring: true, occurrence: "first")]
        let storage = MemoryReminderMetadata()
        let model = ReminderSyncViewModel(provider: provider, storage: storage)
        #expect(await model.applySelection(["list"]))
        try model.configure(identifier: "r", estimatedMinutesText: "60", deadlineOverride: nil)
        let before = model.importedTasks
        provider.onCompletion = {
            provider.records = [ReminderFixtures.record(deadline: ReminderFixtures.date(23, day: 8), recurring: true, occurrence: "second")]
        }
        storage.failSave = true
        await model.toggleCompletion(identifier: "r")
        #expect(model.importedTasks == before && model.message != nil)
        #expect(provider.records.first?.occurrenceKey == "second")
        storage.failSave = false
        await model.refresh()
        #expect(model.importedTasks.first?.id != before.first?.id)
    }
}
