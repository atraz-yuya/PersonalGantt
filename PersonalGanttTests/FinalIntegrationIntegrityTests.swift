import Foundation
import Testing
@testable import PersonalGantt

@MainActor struct FinalIntegrationIntegrityTests {
    @Test func sameRevisionWithDifferentContentsRejectsEntireBatch() throws {
        let value = model()
        let work = try value.addTask(TaskDraft(title: "Keep", deadline: ReminderFixtures.date(23)))
        let original = try #require(value.syncState.records["task_" + work.id.uuidString])
        var altered = original
        var changed = work; changed.title = "Unexpected"
        altered.payload = try SyncState.payloadData(changed)
        let before = value.syncState
        #expect(throws: SyncError.self) { try value.mergeSyncRecords([altered]) }
        #expect(value.tasks == [work] && value.syncState == before)
        var empty = SyncState()
        #expect(throws: SyncError.self) { try empty.merge([original, altered]) }
        #expect(empty.records.isEmpty)
    }

    @Test(arguments: [false, true]) func unexpectedSyncFieldsNeverEnterCheckpoint(nested: Bool) throws {
        let value = model()
        _ = try value.addTask(TaskDraft(title: "Keep", deadline: ReminderFixtures.date(23)))
        var settings = SchedulingSettings.default; settings.weights = OptimizationWeights()
        var payload = try #require(JSONSerialization.jsonObject(with: SyncState.payloadData(settings)) as? [String: Any])
        if nested {
            var weights = try #require(payload["weights"] as? [String: Any])
            weights["accessToken"] = "synthetic-secret"; payload["weights"] = weights
        } else { payload["accessToken"] = "synthetic-secret" }
        let bad = SyncRecord(kind: .schedulingSettings, id: "settings",
            revision: SyncRevision(date: ReminderFixtures.date(1), counter: 0, deviceID: UUID()),
            payload: try JSONSerialization.data(withJSONObject: payload))
        let before = value.syncState
        #expect(throws: (any Error).self) { try value.mergeSyncRecords([bad]) }
        #expect(value.syncState == before)
        var checkpoint = try value.makeBackup().plan
        checkpoint.syncState?.records[bad.key] = bad
        #expect(throws: PlanStorageError.self) { try checkpoint.validate() }
    }

    @Test func freshDeviceDefaultsDoNotOverwriteRemoteSettings() throws {
        let source = model(), target = model()
        try source.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        source.setDistributionMode(.balanced)
        target.recalculate()
        try target.mergeSyncRecords(Array(source.syncState.records.values))
        #expect(target.workloadSettings == source.workloadSettings)
        #expect(target.schedulingSettings == source.schedulingSettings)
    }

    @Test func reminderActualMapsAcrossDevicesWithoutChangingCanonicalSyncPayload() async throws {
        let source = model(), target = model()
        for (value, id) in [(source, "source"), (target, "target")] {
            let provider = FakeReminderProvider()
            provider.records = [ReminderFixtures.record(id, external: "same-external")]
            value.attachReminders(provider: provider, storage: MemoryReminderMetadata())
            let reminders = try #require(value.reminders)
            #expect(await reminders.applySelection(["list"]))
            try reminders.configure(identifier: id, estimatedMinutesText: "60", deadlineOverride: nil)
        }
        let a = try #require(source.tasks.first), b = try #require(target.tasks.first)
        #expect(a.id != b.id)
        try source.logWork(taskID: a.id, minutes: 30)
        try target.mergeSyncRecords(Array(source.syncState.records.values))
        #expect(target.completedMinutes(for: b.id) == 30 && target.remainingMinutes(for: b) == 30)
        #expect(target.workSessions == source.workSessions && target.sessions(for: b.id).count == 1)
        let session = try #require(source.workSessions.first)
        let canonical = target.syncState.records["workSession_" + session.id.uuidString]
        target.recalculate()
        #expect(target.syncState.records["workSession_" + session.id.uuidString] == canonical)
    }

    @Test func pendingSyncSendsEditsMadeDuringFirstExchange() async throws {
        let value = model(), transport = PausedIntegrationSync()
        value.attachSyncTransport(transport)
        await value.applicationDidBecomeActive()
        value.setSyncEnabled(true)
        let work = try value.addTask(TaskDraft(title: "First", deadline: ReminderFixtures.date(23)))
        let initial = _Concurrency.Task { await value.synchronize() }
        await transport.waitUntilPaused()
        try value.updateTask(id: work.id, draft: TaskDraft(title: "Edited", deadline: work.deadline))
        await value.synchronize() // coalesces while the first request is suspended
        transport.resume()
        await initial.value
        #expect(transport.batches.count == 2)
        let last = try #require(transport.batches.last?.first { $0.id == work.id.uuidString })
        #expect(try JSONDecoder().decode(PersonalGantt.Task.self, from: #require(last.payload)).title == "Edited")
        #expect(value.task(for: work.id)?.title == "Edited")
    }

    @Test func versionFourBackupAndRestartPreserveAllNewFields() throws {
        let store = IntegrationCheckpoint(), value = model(store)
        let work = try value.addTask(TaskDraft(title: "Full", estimatedMinutesText: "300", deadline: ReminderFixtures.date(23), priority: .high))
        value.setDistributionMode(.balanced); value.setLocalOptimization(true)
        try value.setRestSettings(maximumMinutes: 90, minimumBreakMinutes: 15)
        try value.logWork(taskID: work.id, minutes: 30)
        let backup = try PersonalGanttBackup.decode(value.makeBackup().encoded())
        #expect(backup.plan.version == 4 && backup.plan.tasks.first?.priority == .high)
        #expect(backup.plan.workSessions == value.workSessions && backup.plan.schedulingSettings == value.schedulingSettings)
        #expect(backup.plan.syncState == value.syncState)
        let restarted = model(store)
        #expect(restarted.persistenceMessage == nil && restarted.tasks == value.tasks)
        #expect(restarted.workSessions == value.workSessions && restarted.schedulingSettings == value.schedulingSettings)
    }

    private func model(_ store: IntegrationCheckpoint? = nil) -> ScheduleViewModel {
        let value = ScheduleViewModel(tasks: [], calendarProvider: IntegrationCalendar(), activitySettings: .legacyFixture, calendar: ReminderFixtures.calendar,
            clock: { ReminderFixtures.date(0) })
        value.attachPlanStore(store ?? IntegrationCheckpoint()); return value
    }
}

@MainActor private final class IntegrationCheckpoint: PlanSnapshotStoring {
    var value: PlanSnapshot?
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot }
}
@MainActor private final class IntegrationCalendar: CalendarProviding {
    var authorization: CalendarAuthorization = .signedOut
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
@MainActor private final class PausedIntegrationSync: SyncTransport {
    var batches: [[SyncRecord]] = []
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func exchange(_ records: [SyncRecord]) async throws -> [SyncRecord] {
        batches.append(records)
        if batches.count == 1 {
            await withCheckedContinuation { paused = $0; observer?.resume(); observer = nil }
        }
        return records
    }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
}
