import Foundation
import Observation
import Synchronization
import Testing
@testable import PersonalGantt

@MainActor struct ReminderMetadataSyncTests {
    @Test func iphoneEstimateClearsMacQueueWithoutCopyingNativeFields() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        let localID = try #require(pair.mac.reminders?.metadata(for: "mac-native")?.taskID)
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        let task = try #require(pair.mac.tasks.first)
        #expect(task.id == localID && task.estimatedMinutes == 30 && task.title == "Mac native title")
        #expect(pair.mac.inputQueueCount == 0 && pair.iphone.inputQueueCount == 0)
        #expect(pair.mac.tasks.count == 1 && pair.iphone.tasks.count == 1)
        #expect(pair.macProvider.writes.isEmpty && pair.iphoneProvider.writes.isEmpty)
        #expect(pair.mac.syncState.records.values.filter { $0.kind == .task && $0.payload != nil }.isEmpty)
        let record = try #require(pair.mac.syncState.records.values.first { $0.kind == .reminderMetadata })
        let payload = try #require(record.payload)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: ["externalIdentifier", "occurrenceKey", "estimatedMinutes", "supplementalDeadline", "isExcluded"]))
    }
    @Test func macEditReturnsToIphoneWithoutDuplicateOrLostWork() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        let macTask = try #require(pair.mac.tasks.first), iphoneID = try #require(pair.iphone.tasks.first?.id)
        try pair.mac.logWork(taskID: macTask.id, minutes: 10)
        pair.macClock.now.addTimeInterval(60)
        try pair.mac.reminders?.configure(identifier: "mac-native", estimatedMinutesText: "60", deadlineOverride: nil)
        await pair.mac.localSync?.syncNow(); await settle()
        #expect(pair.iphone.tasks.count == 1 && pair.iphone.tasks.first?.id == iphoneID)
        #expect(pair.iphone.tasks.first?.estimatedMinutes == 60 && pair.mac.tasks.first?.id == macTask.id)
        #expect(pair.iphone.completedMinutes(for: iphoneID) == 10 && pair.mac.completedMinutes(for: macTask.id) == 10)
    }
    @Test func supplementalDeadlineSyncsButNativeDeadlineWins() async throws {
        let pair = try await MetadataPair(deadline: nil)
        defer { pair.stop() }
        let supplement = ReminderFixtures.date(23, day: 14)
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: supplement)
        await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.tasks.first?.deadline == supplement && pair.mac.inputQueueCount == 0)
        pair.macProvider.records = [ReminderFixtures.record("mac-native", list: "mac-list", title: "Mac native title", deadline: ReminderFixtures.date(20, day: 14), external: "shared-external")]
        await pair.mac.reminders?.refresh()
        #expect(pair.mac.tasks.first?.deadline == ReminderFixtures.date(20, day: 14))
        #expect(pair.macProvider.writes.isEmpty)
        await pair.mac.localSync?.syncNow(); await settle()
        #expect(pair.iphone.tasks.first?.deadline == supplement)
    }
    @Test func exclusionAndReconfigurationSyncBothWays() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.reminders?.exclude(identifier: "mac-native") == true)
        await pair.mac.localSync?.syncNow(); await settle()
        #expect(pair.iphone.reminders?.isExcluded("iphone-native") == true && pair.iphone.inputQueueCount == 0 && pair.iphone.tasks.isEmpty)
        pair.iphoneClock.now.addTimeInterval(120)
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "45", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.reminders?.isExcluded("mac-native") == false && pair.mac.tasks.first?.estimatedMinutes == 45)
    }
    @Test func excludingUnregisteredReminderNotifiesInputQueueObservers() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        let changed = Mutex(false)
        withObservationTracking {
            #expect(pair.mac.reminders?.waitingRecords.count == 1)
        } onChange: { changed.withLock { $0 = true } }
        #expect(pair.iphone.reminders?.exclude(identifier: "iphone-native") == true)
        await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.inputQueueCount == 0 && changed.withLock { $0 })
    }
    @Test func restartKeepsSettingsEvenWithUnmodifiedAssociationCache() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        let id = try #require(pair.mac.tasks.first?.id)
        #expect(pair.macMetadata.state.metadata["mac-native"]?.estimatedMinutes == nil)
        let restarted = MetadataPair.makeModel(store: pair.macPlan, clock: pair.macClock)
        restarted.attachReminders(provider: pair.macProvider, storage: pair.macMetadata)
        await restarted.reminders?.loadState()
        #expect(restarted.inputQueueCount == 0 && restarted.tasks.count == 1 && restarted.tasks.first?.id == id)
        #expect(restarted.reminders?.metadata(for: "mac-native")?.estimatedMinutes == 30)
    }
    @Test func nativeDeletionKeepsUnmatchedSettingsInertAndDoesNotEraseOtherDevice() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        let id = try #require(pair.mac.tasks.first?.id), native = pair.macProvider.records
        pair.macProvider.records = []; await pair.mac.reminders?.refresh()
        await pair.mac.localSync?.syncNow(); await settle()
        #expect(pair.mac.tasks.isEmpty && pair.mac.inputQueueCount == 0 && pair.iphone.tasks.count == 1)
        #expect(pair.mac.syncState.records.values.contains { $0.kind == .reminderMetadata && $0.payload != nil })
        pair.macProvider.records = native; await pair.mac.reminders?.refresh()
        #expect(pair.mac.tasks.count == 1 && pair.mac.tasks.first?.id == id)
    }
    @Test func tombstoneDoesNotResurrectCachedEstimate() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        // Refresh writes a projection cache; the revision/tombstone still lives in the plan.
        await pair.mac.reminders?.refresh()
        #expect(pair.macMetadata.state.metadata["mac-native"]?.estimatedMinutes == 30)
        let previous = try #require(pair.mac.syncState.records.values.first { $0.kind == .reminderMetadata })
        var state = pair.iphone.syncState
        state.captureValue(kind: .reminderMetadata, id: previous.id, payload: nil, now: ReminderFixtures.date(1, day: 13))
        try pair.mac.applyLocalSyncRecords([#require(state.records[previous.key])])
        #expect(pair.mac.inputQueueCount == 1 && pair.mac.tasks.isEmpty)
        await pair.mac.reminders?.refresh()
        #expect(pair.mac.tasks.isEmpty && pair.mac.syncState.records[previous.key]?.payload == nil)
    }
    @Test func metadataBeforeNativeFetchWaitsThenMatchesLocalIdentifier() async throws {
        let pair = try await MetadataPair(macFetch: false)
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.tasks.isEmpty)
        #expect(await pair.mac.reminders?.applySelection(["mac-list"]) == true)
        #expect(pair.mac.tasks.count == 1 && pair.mac.inputQueueCount == 0)
    }
    @Test func concurrentEditsUseExistingLWWAndConverge() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        try pair.mac.reminders?.configure(identifier: "mac-native", estimatedMinutesText: "90", deadlineOverride: nil)
        await pair.iphone.localSync?.syncNow(); await settle()
        await pair.mac.localSync?.syncNow(); await settle()
        #expect(pair.iphone.tasks.first?.estimatedMinutes == 90 && pair.mac.tasks.first?.estimatedMinutes == 90)
        #expect(pair.iphone.syncState.records == pair.mac.syncState.records && !pair.iphone.syncState.conflictKeys.isEmpty)
    }
    @Test func metadataAndPlanSaveFailuresLeaveQueueAndTrustIntact() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        pair.iphoneMetadata.failSave = true
        #expect(throws: ReminderServiceError.localStorage) { try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil) }
        #expect(pair.iphone.inputQueueCount == 1 && pair.iphone.tasks.isEmpty)
        pair.iphoneMetadata.failSave = false
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        let before = pair.mac.syncState
        pair.macPlan.fail = true; await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.syncState == before && pair.mac.inputQueueCount == 1 && pair.mac.tasks.isEmpty)
        #expect(pair.mac.reminders?.metadata(for: "mac-native")?.estimatedMinutes == nil)
        pair.macPlan.fail = false; pair.mac.retryPlanSave()
        await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.inputQueueCount == 0 && pair.mac.tasks.first?.estimatedMinutes == 30)
    }
    @Test(arguments: [nil, "next-occurrence"] as [String?])
    func distinctOccurrencesAndAmbiguousExternalIDsCannotMisapply(occurrence: String?) async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        pair.macProvider.records = [ReminderFixtures.record("mac-native", list: "mac-list", external: "shared-external", recurring: true, occurrence: occurrence)]
        await pair.mac.reminders?.refresh(); await pair.iphone.localSync?.syncNow(); await settle()
        #expect(pair.mac.tasks.isEmpty && pair.mac.inputQueueCount == 1)
        #expect(pair.mac.reminders?.metadata(for: "mac-native")?.estimatedMinutes == nil)
        pair.macProvider.records = [ReminderFixtures.record("mac-native", list: "mac-list", external: "shared-external"), ReminderFixtures.record("duplicate", list: "mac-list", external: "shared-external")]
        await pair.mac.reminders?.refresh()
        #expect(pair.mac.tasks.isEmpty && pair.mac.inputQueueCount == 2)
    }
    @Test func legacyConfiguredTaskKeepsItsIdentityAfterMetadataMerge() async throws {
        let pair = try await MetadataPair(macFetch: false)
        defer { pair.stop() }
        let oldID = UUID()
        pair.macMetadata.state.metadata["mac-native"] = ReminderTaskMetadata(taskID: oldID, externalIdentifier: "shared-external", listID: "mac-list", estimatedMinutes: 60, deadlineOverride: nil)
        let restarted = MetadataPair.makeModel(store: pair.macPlan, clock: pair.macClock)
        restarted.attachReminders(provider: pair.macProvider, storage: pair.macMetadata)
        #expect(await restarted.reminders?.applySelection(["mac-list"]) == true)
        #expect(restarted.tasks.first?.id == oldID)
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        try restarted.applyLocalSyncRecords(Array(pair.iphone.syncState.records.values))
        #expect(restarted.tasks.count == 1 && restarted.tasks.first?.id == oldID && restarted.tasks.first?.estimatedMinutes == 30)
    }
    @Test func explicitBackupRestoreUpdatesOlderSynchronizedSettings() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        pair.stop()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        pair.iphone.configureBackup(reminderStore: pair.iphoneMetadata, journal: FileBackupJournal(url: directory.appendingPathComponent("iphone.json")), deviceID: pair.iphone.syncState.deviceID)
        pair.mac.configureBackup(reminderStore: pair.macMetadata, journal: FileBackupJournal(url: directory.appendingPathComponent("mac.json")), deviceID: pair.mac.syncState.deviceID)
        try pair.iphone.reminders?.configure(identifier: "iphone-native", estimatedMinutesText: "30", deadlineOverride: nil)
        try pair.mac.applyLocalSyncRecords(Array(pair.iphone.syncState.records.values))
        let id = try #require(pair.mac.tasks.first?.id)
        let backup = try pair.iphone.makeBackup()
        pair.macClock.now.addTimeInterval(60)
        try pair.mac.reminders?.configure(identifier: "mac-native", estimatedMinutesText: "90", deadlineOverride: nil)
        pair.macClock.now.addTimeInterval(60)
        try pair.mac.restoreBackup(backup)
        await pair.mac.reminders?.refresh()
        #expect(pair.mac.tasks.count == 1 && pair.mac.tasks.first?.id == id && pair.mac.tasks.first?.estimatedMinutes == 30)
    }
    @Test func ambiguousBackupMetadataCannotCreatePortableEdits() async throws {
        let pair = try await MetadataPair()
        defer { pair.stop() }
        pair.stop()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        pair.mac.configureBackup(reminderStore: pair.macMetadata, journal: FileBackupJournal(url: directory.appendingPathComponent("mac.json")), deviceID: pair.mac.syncState.deviceID)
        var backup = try pair.mac.makeBackup()
        backup.sourceDeviceID = UUID()
        backup.reminders.metadata["other"] = ReminderTaskMetadata(taskID: UUID(), externalIdentifier: "shared-external", listID: "foreign-list", estimatedMinutes: 90)
        backup.reminders.metadata["mac-native"]?.estimatedMinutes = 30
        try pair.mac.restoreBackup(backup)
        await pair.mac.reminders?.refresh()
        #expect(pair.mac.syncState.records.values.allSatisfy { $0.kind != .reminderMetadata })
        #expect(pair.mac.tasks.isEmpty && pair.mac.inputQueueCount == 1)
    }
    @Test func diskCheckpointRestoresPortableMetadataAndLocalWorkID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planURL = directory.appendingPathComponent("Plan.store"), metadataURL = directory.appendingPathComponent("Metadata.json")
        let provider = FakeReminderProvider()
        provider.records = [ReminderFixtures.record("disk-native", external: "disk-external")]
        func openModel() throws -> ScheduleViewModel {
            let model = ScheduleViewModel(tasks: [], calendarProvider: MetadataCalendar(), calendar: ReminderFixtures.calendar,
                clock: { ReminderFixtures.date(0, day: 13) }, planStore: try SwiftDataPlanStore(url: planURL))
            model.attachReminders(provider: provider, storage: FileReminderMetadataStore(url: metadataURL))
            return model
        }
        var model: ScheduleViewModel? = try openModel()
        #expect(await model?.reminders?.applySelection(["list"]) == true)
        try model?.reminders?.configure(identifier: "disk-native", estimatedMinutesText: "30", deadlineOverride: nil)
        let id = try #require(model?.tasks.first?.id)
        model = nil
        let restarted = try openModel()
        await restarted.reminders?.loadState()
        #expect(restarted.tasks.count == 1 && restarted.tasks.first?.id == id && restarted.tasks.first?.estimatedMinutes == 30)
        #expect(restarted.inputQueueCount == 0 && restarted.syncState.records.values.contains { $0.kind == .reminderMetadata })
    }
}

struct ReminderMetadataWireTests {
    @Test(arguments: ["title", "deadline", "isCompleted", "listID", "taskID", "accessToken"])
    func nativeOrSecretFieldsAreRejected(field: String) throws {
        let value = try #require(ReminderSyncMetadata(metadata: ReminderFixtures.metadata()))
        var object = try #require(JSONSerialization.jsonObject(with: SyncState.payloadData(value)) as? [String: Any])
        object[field] = "synthetic"
        let record = SyncRecord(kind: .reminderMetadata, id: value.id, revision: SyncRevision(date: ReminderFixtures.date(0), counter: 0, deviceID: UUID()), payload: try JSONSerialization.data(withJSONObject: object))
        #expect(throws: SyncError.invalidData) { try SyncPayloadValidator.validate(record) }
    }
    @Test func identityAndSizeValidationAlsoAppliesToTombstones() throws {
        let value = try #require(ReminderSyncMetadata(metadata: ReminderFixtures.metadata()))
        var record = SyncRecord(kind: .reminderMetadata, id: String(repeating: "f", count: 64), revision: SyncRevision(date: ReminderFixtures.date(0), counter: 0, deviceID: UUID()), payload: try SyncState.payloadData(value))
        #expect(throws: SyncError.invalidData) { try SyncPayloadValidator.validate(record) }
        record.payload = nil; record.id = "native-id"
        #expect(throws: SyncError.invalidData) { try SyncPayloadValidator.validate(record) }
        #expect(ReminderSyncMetadata(metadata: ReminderFixtures.metadata(minutes: 0)) == nil)
        #expect(ReminderSyncMetadata(metadata: ReminderFixtures.metadata(external: String(repeating: "x", count: 4097))) == nil)
        #expect(ReminderSyncMetadata.key(externalIdentifier: "a|b", occurrenceKey: "c") != ReminderSyncMetadata.key(externalIdentifier: "a", occurrenceKey: "b|c"))
    }
}

@MainActor private final class MetadataClock { var now = ReminderFixtures.date(0, day: 13) }
@MainActor private final class MetadataPlan: PlanSnapshotStoring {
    var value: PlanSnapshot?, fail = false
    func load() throws -> PlanSnapshot? { value }
    func save(_ value: PlanSnapshot) throws { if fail { throw PlanStorageError.unavailable }; try value.validate(); self.value = value }
}
@MainActor private final class MetadataCalendar: CalendarProviding {
    var authorization: CalendarAuthorization { .signedOut }
    func requestAccess() async throws -> CalendarAuthorization { .signedOut }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
@MainActor private struct MetadataPair {
    let iphone: ScheduleViewModel, mac: ScheduleViewModel
    let iphoneClock = MetadataClock(), macClock = MetadataClock()
    let iphonePlan = MetadataPlan(), macPlan = MetadataPlan()
    let iphoneProvider = FakeReminderProvider(), macProvider = FakeReminderProvider()
    let iphoneMetadata = MemoryReminderMetadata(), macMetadata = MemoryReminderMetadata()
    let a: LocalTestLink, b: LocalTestLink
    static func makeModel(store: MetadataPlan, clock: MetadataClock) -> ScheduleViewModel {
        ScheduleViewModel(tasks: [], calendarProvider: MetadataCalendar(), calendar: ReminderFixtures.calendar,
            clock: { clock.now }, planStore: store)
    }
    init(deadline: Date? = ReminderFixtures.date(23, day: 14), macFetch: Bool = true) async throws {
        let aid = ReminderFixtures.id(6001), bid = ReminderFixtures.id(6002)
        let ah = Data(repeating: 1, count: 32), bh = Data(repeating: 2, count: 32)
        a = LocalTestLink(id: aid, hash: ah); b = LocalTestLink(id: bid, hash: bh); a.other = b; b.other = a
        Self.makeModel(store: iphonePlan, clock: iphoneClock).recalculate(); iphonePlan.value?.syncState?.deviceID = aid
        Self.makeModel(store: macPlan, clock: macClock).recalculate(); macPlan.value?.syncState?.deviceID = bid
        iphone = Self.makeModel(store: iphonePlan, clock: iphoneClock); mac = Self.makeModel(store: macPlan, clock: macClock)
        for (model, provider, storage, identifier, list) in [(iphone, iphoneProvider, iphoneMetadata, "iphone-native", "iphone-list"), (mac, macProvider, macMetadata, "mac-native", "mac-list")] {
            provider.lists = [ReminderList(id: list, title: "Synthetic list", accountTitle: "Synthetic account", allowsCompletionChanges: true)]
            provider.records = [ReminderFixtures.record(identifier, list: list, title: identifier == "mac-native" ? "Mac native title" : "iPhone native title", deadline: deadline, external: "shared-external")]
            model.attachReminders(provider: provider, storage: storage)
            if model === iphone || macFetch { #expect(await model.reminders?.applySelection([list]) == true) }
        }
        for (model, link, remote, hash, name) in [(iphone, a, bid, bh, "Mac"), (mac, b, aid, ah, "iPhone")] {
            var prefs = LocalSyncPreferences(); prefs.enabled = true
            prefs.trustedDevice = LocalTrustedDevice(deviceID: remote, name: name, certificateHash: hash, pairedAt: ReminderFixtures.date(0))
            model.configureLocalSync(link: link, store: LocalPreferenceMemory(value: prefs)); model.localSync?.setAvailable(true)
        }
        iphone.localSync?.connect(LocalPeer(id: bid, name: "Mac", pairing: false)); await settle()
        #expect(iphone.localSync?.isConnected == true && mac.localSync?.isConnected == true)
    }
    func stop() { iphone.localSync?.setAvailable(false); mac.localSync?.setAvailable(false) }
}
