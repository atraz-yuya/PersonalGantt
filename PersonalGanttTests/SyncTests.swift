import Foundation
import Testing
@testable import PersonalGantt

struct SyncTests {
    private let now = ReminderFixtures.date(0)
    @Test func offlineChangesAndDeletionMergeWithoutResurrection() throws {
        var a = SyncState(), b = SyncState()
        a.capture(kind: .task, values: ["synthetic": Data("initial".utf8)], now: now)
        try b.merge(Array(a.records.values))
        a.capture(kind: .task, values: [:], now: now.addingTimeInterval(10))
        try b.merge(Array(a.records.values))
        #expect(b.records["task_synthetic"]?.payload == nil)
        let stale = SyncRecord(kind: .task, id: "synthetic", revision: SyncRevision(date: now, counter: 0, deviceID: UUID()), baseRevision: nil, payload: Data("old".utf8))
        try b.merge([stale]); #expect(b.records["task_synthetic"]?.payload == nil)
    }
    @Test func concurrentEditsConvergeAndDetectConflict() throws {
        var a = SyncState(), b = SyncState()
        a.capture(kind: .task, values: ["id": Data("initial".utf8)], now: now)
        try b.merge(Array(a.records.values))
        a.capture(kind: .task, values: ["id": Data("A".utf8)], now: now.addingTimeInterval(1))
        b.capture(kind: .task, values: ["id": Data("B".utf8)], now: now.addingTimeInterval(1))
        let aa = a, bb = b
        try a.merge(Array(bb.records.values)); try b.merge(Array(aa.records.values))
        #expect(a.records == b.records && a.conflictKeys == ["task_id"])
    }
    @Test func sequentialUpdateIsNotConflictAndSameTimestampUsesCounter() throws {
        var a = SyncState(), b = SyncState()
        a.capture(kind: .workload, values: ["settings": Data("A".utf8)], now: now)
        try b.merge(Array(a.records.values))
        b.capture(kind: .workload, values: ["settings": Data("B".utf8)], now: now)
        try a.merge(Array(b.records.values))
        #expect(a.conflictKeys.isEmpty && a.records["workload_settings"]?.revision.counter == 1)
    }
    @Test func invalidBatchCannotPartiallyMerge() {
        var state = SyncState()
        let good = SyncRecord(kind: .task, id: "id", revision: SyncRevision(date: now, counter: 0, deviceID: UUID()), payload: nil)
        var bad = good; bad.id = ""
        #expect(throws: SyncError.self) { try state.merge([good, bad]) }
        #expect(state.records.isEmpty)
    }
}
@MainActor struct SyncIntegrationTests {
    @Test func taskAndWorkloadSyncExcludesCredentialsAndDeviceCalendar() throws {
        let a = model(), b = model()
        let work = try a.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        try a.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        try b.mergeSyncRecords(Array(a.syncState.records.values))
        #expect(b.task(for: work.id) == work && b.workloadSettings.maxScheduledMinutesPerDay == 300)
        #expect(b.calendarCoverage == nil && b.selectedCalendarIDs.isEmpty)
        let data = try SyncState.payloadData(a.syncState)
        #expect(!String(decoding: data, as: UTF8.self).contains("accessToken"))
        a.deleteTask(id: work.id); try b.mergeSyncRecords(Array(a.syncState.records.values))
        #expect(b.task(for: work.id) == nil && b.syncState.records["task_" + work.id.uuidString]?.payload == nil)
    }
    @Test func disabledSyncNeverExchangesAndFailureKeepsLocalEdits() async throws {
        let value = model(); let transport = MemorySyncTransport(); value.attachSyncTransport(transport)
        let work = try value.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        await value.synchronize(); #expect(transport.calls == 0)
        value.setSyncEnabled(true); transport.fail = true
        await value.synchronize(); #expect(transport.calls == 1 && value.task(for: work.id) == work && value.syncMessage != nil)
        transport.fail = false; await value.synchronize()
        #expect(value.syncState.lastSync != nil)
    }
    @Test func invalidIncomingTaskDoesNotReplaceVisibleState() throws {
        let value = model(); let work = try value.addTask(TaskDraft(title: "Keep", deadline: ReminderFixtures.date(23)))
        let bad = SyncRecord(kind: .task, id: work.id.uuidString,
            revision: SyncRevision(date: .distantFuture, counter: 0, deviceID: UUID()), payload: Data("bad".utf8))
        #expect(throws: (any Error).self) { try value.mergeSyncRecords([bad]) }
        #expect(value.task(for: work.id) == work)
    }
    @Test(arguments: [1,2,3]) func oldPayloadsRemainReadableAndBecomeVersionFour(version: Int) throws {
        let store = SyncPlanStore(); let value = model(store)
        _ = try value.addTask(TaskDraft(title: "Legacy", deadline: ReminderFixtures.date(23)))
        var old = try #require(store.value); old.version = version; old.syncState = nil; old.workSessions = nil
        if version == 1 { old.workloadSettings = nil; old.routines = nil }
        store.value = old
        let restored = model(store); #expect(restored.tasks == value.tasks)
        restored.recalculate(); #expect(store.value?.version == 4 && store.value?.syncState != nil)
    }
    private func model(_ store: SyncPlanStore? = nil) -> ScheduleViewModel {
        let value = ScheduleViewModel(tasks: [], availableSlots: [])
        value.attachPlanStore(store ?? SyncPlanStore()); return value
    }
}
@MainActor private final class SyncPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot }
}
@MainActor private final class MemorySyncTransport: SyncTransport {
    var calls = 0, fail = false
    func exchange(_ records: [SyncRecord]) async throws -> [SyncRecord] { calls += 1; if fail { throw SyncError.network }; return records }
}
