import Foundation
import Observation

@MainActor
@Observable
final class ReminderSyncViewModel {
    private(set) var authorization: ReminderAuthorization
    private(set) var lists: [ReminderList] = []
    private(set) var selectedListIDs: Set<String> = []
    private(set) var records: [ReminderRecord] = []
    private(set) var importedTasks: [Task] = []
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var lastOperationFailed = false
    private(set) var lastRefresh: Date?
    private(set) var isStorageAvailable = true
    private(set) var transferTaskIDs: [UUID: UUID] = [:]

    @ObservationIgnored private let provider: any ReminderProviding
    @ObservationIgnored private let storage: any ReminderMetadataStoring
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var state = ReminderLocalState()
    @ObservationIgnored private var pendingRefresh = false
    private var synchronizedRecords: [String: SyncRecord]?
    @ObservationIgnored private let onMetadataChanged: ((ReminderSyncMetadata) throws -> Bool)?
    @ObservationIgnored private var onTasksChanged: ([Task]) -> Void

    init(provider: any ReminderProviding, storage: any ReminderMetadataStoring,
         clock: @escaping () -> Date = { Date() },
         onMetadataChanged: ((ReminderSyncMetadata) throws -> Bool)? = nil, onTasksChanged: @escaping ([Task]) -> Void = { _ in }) {
        self.provider = provider
        self.storage = storage
        self.clock = clock
        self.onTasksChanged = onTasksChanged
        self.onMetadataChanged = onMetadataChanged
        authorization = provider.authorization
        do {
            state = try storage.load()
            try state.validate()
            selectedListIDs = state.selectedListIDs
        } catch {
            isStorageAvailable = false
            lastOperationFailed = true
            message = ReminderServiceError.localStorage.localizedDescription
        }
    }

    var waitingRecords: [ReminderRecord] {
        records.filter { !$0.isCompleted && !isExcluded($0.id) && task(for: $0.id) == nil }
    }

    func metadata(for id: String) -> ReminderTaskMetadata? {
        guard let local = state.metadata[id], let synchronizedRecords,
              let identity = portableValue(identifier: id, metadata: local), let synced = synchronizedRecords[identity.id]
        else { return state.metadata[id] }
        if let payload = synced.payload, let value = try? JSONDecoder().decode(ReminderSyncMetadata.self, from: payload) {
            return value.applying(to: local)
        }
        if synced.payload == nil {
            var reset = local; reset.estimatedMinutes = nil; reset.deadlineOverride = nil; reset.isExcluded = false; reset.availabilityExclusions = []
            return reset
        }
        return local
    }
    func record(for id: String) -> ReminderRecord? { records.first { $0.id == id } }
    func task(for id: String) -> Task? { importedTasks.first { $0.reminderIdentifier == id } }
    func isExcluded(_ id: String) -> Bool { metadata(for: id)?.isExcluded ?? false }
    var pendingTransferCount: Int { state.pendingTransfer?.count ?? 0 }
    func backupState() throws -> ReminderLocalState {
        guard isStorageAvailable, !isLoading else { throw BackupError.busy }
        try state.validate()
        return projectedState()
    }
    /// Storage has already committed as part of the backup transaction. No native write.
    func adoptRestoredState(_ restored: ReminderLocalState) {
        state = restored
        selectedListIDs = restored.selectedListIDs
        records = []
        importedTasks = []
        lastRefresh = nil
        transferTaskIDs = [:]
        message = "ファイルの設定を読み込みました。Remindersの再取得を待っています。"
        lastOperationFailed = false
    }
    func blockAfterInterruptedRestore() {
        isStorageAvailable = false
        message = BackupError.recoveryRequired.localizedDescription
        lastOperationFailed = true
    }

    func waitingDescription(for record: ReminderRecord) -> String {
        var missing: [String] = []
        if record.isRecurring && record.occurrenceKey == nil { return "繰り返しReminderは、Reminders側で有効な締切を設定してください。" }
        if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("Reminders側のタイトル") }
        if metadata(for: record.id)?.estimatedMinutes == nil { missing.append("所要時間") }
        if record.deadline == nil && metadata(for: record.id)?.deadlineOverride == nil {
            missing.append(record.hasInvalidDeadline ? "有効な締切" : "締切")
        }
        return missing.isEmpty ? "配置対象外" : missing.joined(separator: "・") + "を設定してください。"
    }

    /// Never request access during activation or notifications.
    func loadState() async {
        authorization = provider.authorization
        guard authorization == .fullAccess else {
            lastOperationFailed = !selectedListIDs.isEmpty
            if lastRefresh != nil { message = authorization.description + " 以前のタスクを保持しています。" }
            return
        }
        await refresh()
    }

    func requestAccess() async {
        guard !isLoading, isStorageAvailable else { return }
        await update(selection: nil, requestAccess: true)
    }

    func refresh() async {
        if isLoading {
            pendingRefresh = true
            return
        }
        await update(selection: nil)
    }

    @discardableResult
    func applySelection(_ selection: Set<String>) async -> Bool {
        guard !isLoading else { return false }
        return await update(selection: selection)
    }

    @discardableResult
    private func update(selection: Set<String>?, requestAccess: Bool = false) async -> Bool {
        guard !isLoading, isStorageAvailable else { return false }
        isLoading = true
        pendingRefresh = false
        defer { isLoading = false }
        var success = false
        do {
            authorization = provider.authorization
            if requestAccess { authorization = try await provider.requestAccess() }
            guard authorization == .fullAccess else {
                lastOperationFailed = !selectedListIDs.isEmpty
                message = authorization.description + " 以前のタスクを保持しています。"
                return false
            }
            try await readSnapshot(selection: selection ?? selectedListIDs)
            success = true
        } catch { report(error) }
        // Store-change notifications during a fetch/write are coalesced.
        while pendingRefresh && !_Concurrency.Task.isCancelled {
            pendingRefresh = false
            do { try await readSnapshot(selection: selectedListIDs) }
            catch { report(error) }
        }
        return success
    }

    private func readSnapshot(selection: Set<String>) async throws {
        guard provider.authorization == .fullAccess else { throw ReminderServiceError.accessRequired }
        let sources = try await provider.loadLists()
        guard Set(sources.map(\.id)).count == sources.count else { throw ReminderServiceError.invalidSnapshot }
        let effective = selection.intersection(Set(sources.map(\.id)))
        let fetched = effective.isEmpty ? [] : try await provider.loadReminders(listIDs: effective)
        try _Concurrency.Task.checkCancellation()
        guard provider.authorization == .fullAccess else { throw ReminderServiceError.accessRequired }
        guard fetched.allSatisfy({ effective.contains($0.listID) }) else { throw ReminderServiceError.invalidSnapshot }
        var updated = try ReminderTaskMapper.reconcile(fetched, state: projectedState())
        let transferred = try ReminderTransferMapper.resolve(updated, records: fetched)
        updated = transferred.state
        updated.selectedListIDs = effective
        // Save before publication: a storage failure cannot silently forget estimates.
        try storage.save(updated)
        state = updated
        // Metadata and the plan use separate stores: recover mappings after an interrupted publication.
        transferTaskIDs = updated.transferAliases ?? [:]
        selectedListIDs = effective
        lists = sources
        records = fetched.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
        authorization = provider.authorization
        lastRefresh = clock()
        lastOperationFailed = false
        message = effective == selection ? nil : "利用できなくなったReminderリストを選択から除外しました。"
        publishTasks()
    }

    func configure(identifier: String, estimatedMinutesText: String, deadlineOverride: Date?, availabilityExclusions: [TaskAvailabilityExclusion]? = nil) throws {
        guard !isLoading, isStorageAvailable, let record = record(for: identifier), var value = metadata(for: identifier)
        else { throw ReminderServiceError.reminderUnavailable }
        guard !record.isRecurring || record.occurrenceKey != nil else { throw TaskInputError.invalidDeadline }
        // Reuse the existing Task input validation. The source title remains authoritative.
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = record.deadline ?? deadlineOverride
        guard let deadline else { throw TaskInputError.invalidDeadline }
        let input = try TaskDraft(title: title, estimatedMinutesText: estimatedMinutesText, deadline: deadline).validated()
        value.estimatedMinutes = input.estimatedMinutes
        value.deadlineOverride = record.deadline == nil ? deadlineOverride : nil
        value.isExcluded = false
        if let availabilityExclusions {
            guard AvailabilityExclusion.valid(availabilityExclusions) else { throw TaskInputError.invalidAvailabilityExclusions }
            value.availabilityExclusions = availabilityExclusions
        }
        if try commitPortableMetadata(identifier: identifier, metadata: value) {
            message = nil; lastOperationFailed = false; return
        }
        var updated = state
        updated.metadata[identifier] = value
        try storage.save(updated)
        state = updated
        message = nil
        lastOperationFailed = false
        publishTasks()
    }

    @discardableResult
    func exclude(identifier: String) -> Bool {
        guard !isLoading, isStorageAvailable, var value = metadata(for: identifier) else { return false }
        var updated = state
        value.isExcluded = true
        updated.metadata[identifier] = value
        do {
            if try !commitPortableMetadata(identifier: identifier, metadata: value) {
                try storage.save(updated); state = updated; publishTasks()
            }
            message = "PersonalGanttの配置対象から外しました。"
            lastOperationFailed = false
            return true
        } catch { report(error); return false }
    }

    func toggleCompletion(identifier: String) async {
        guard !isLoading, isStorageAvailable, let record = record(for: identifier) else { return }
        guard record.allowsCompletionChanges else { report(ReminderServiceError.readOnly); return }
        isLoading = true
        pendingRefresh = false
        defer { isLoading = false }
        do {
            let updated = try await provider.setCompletion(identifier: identifier, listID: record.listID,
                                                           expected: record.isCompleted, completed: !record.isCompleted)
            guard updated.id == identifier, updated.listID == record.listID else { throw ReminderServiceError.invalidSnapshot }
            // The successful remote write is authoritative even if the scene became inactive.
            let refreshedRecords = records.map { $0.id == identifier ? updated : $0 }
            let refreshedState = try ReminderTaskMapper.reconcile(refreshedRecords, state: projectedState())
            // EventKit can advance a recurring Reminder as part of completion. Apply its
            // new work identity before publishing so protected time belongs to the old occurrence.
            if refreshedState != state { try storage.save(refreshedState) }
            state = refreshedState
            records = refreshedRecords
            message = nil
            lastOperationFailed = false
            publishTasks()
        } catch { report(error) }
        while pendingRefresh && !_Concurrency.Task.isCancelled {
            pendingRefresh = false
            do { try await readSnapshot(selection: selectedListIDs) }
            catch { report(error) }
        }
    }

    func reportSourceOwnedFields() { message = ReminderServiceError.sourceOwnedFields.localizedDescription }

    /// SyncState in the durable plan is authoritative for portable settings.
    /// Projecting it neither writes EventKit nor starts another metadata mutation.
    @discardableResult
    func applySynchronizedMetadata(_ values: [SyncRecord]) -> [Task]? {
        synchronizedRecords = Dictionary(uniqueKeysWithValues: values.filter { $0.kind == .reminderMetadata }.map { ($0.id, $0) })
        guard lastRefresh != nil, !isLoading else { return nil }
        importedTasks = ReminderTaskMapper.tasks(records: records, state: projectedState())
        return importedTasks
    }
    /// Migrate only configured, uniquely matched native items. Unconfigured defaults
    /// cannot overwrite another device's settings; absent items cannot imply deletion.
    func legacySyncMetadata() -> [ReminderSyncMetadata] {
        records.compactMap { record in
            guard let metadata = state.metadata[record.id],
                  let value = portableValue(identifier: record.id, metadata: metadata), value.hasSettings else { return nil }
            return value
        }
    }
    private func commitPortableMetadata(identifier: String, metadata: ReminderTaskMetadata) throws -> Bool {
        guard let onMetadataChanged, let value = portableValue(identifier: identifier, metadata: metadata) else { return false }
        // Keep the native-to-work UUID mapping durable before the plan references it.
        // A failing association store must leave the input queue unchanged.
        try storage.save(state)
        return try onMetadataChanged(value)
    }
    private func portableValue(identifier: String, metadata: ReminderTaskMetadata) -> ReminderSyncMetadata? {
        guard let value = ReminderSyncMetadata(metadata: metadata),
              records.filter({ $0.externalIdentifier == value.externalIdentifier && $0.occurrenceKey == value.occurrenceKey }).count == 1,
              records.contains(where: { $0.id == identifier && $0.externalIdentifier == value.externalIdentifier && $0.occurrenceKey == value.occurrenceKey && (!$0.isRecurring || $0.occurrenceKey != nil) })
        else { return nil }
        return value
    }
    private func projectedState() -> ReminderLocalState {
        guard synchronizedRecords != nil else { return state }
        var result = state
        for record in records {
            result.metadata[record.id] = metadata(for: record.id)
        }
        return result
    }

    private func publishTasks() {
        importedTasks = ReminderTaskMapper.tasks(records: records, state: projectedState())
        onTasksChanged(importedTasks)
    }
    private func report(_ error: Error) {
        lastOperationFailed = true
        authorization = provider.authorization
        let reason = (error as? ReminderServiceError)?.localizedDescription
            ?? (error as? TaskInputError)?.localizedDescription
            ?? "Remindersの処理に失敗しました。"
        message = reason + " 以前のタスクを保持しています。"
    }
}
