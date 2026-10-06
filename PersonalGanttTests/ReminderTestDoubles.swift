import Foundation
@testable import PersonalGantt

@MainActor
final class MemoryReminderMetadata: ReminderMetadataStoring {
    var state = ReminderLocalState()
    var failLoad = false
    var failSave = false
    var saves = 0
    func load() throws -> ReminderLocalState {
        if failLoad { throw ReminderServiceError.localStorage }
        return state
    }
    func save(_ value: ReminderLocalState) throws {
        if failSave { throw ReminderServiceError.localStorage }
        try value.validate()
        state = value
        saves += 1
    }
}

@MainActor
final class FakeReminderProvider: ReminderProviding {
    var authorization: ReminderAuthorization = .fullAccess
    var nextAuthorization: ReminderAuthorization = .fullAccess
    var lists = [ReminderList(id: "list", title: "合成リスト", accountTitle: "テスト", allowsCompletionChanges: true),
                 ReminderList(id: "other", title: "合成別リスト", accountTitle: "テスト", allowsCompletionChanges: true)]
    var records: [ReminderRecord] = []
    var accessRequests = 0
    var listLoads = 0
    var requestedSelections: [Set<String>] = []
    var writes: [(String, String, Bool, Bool)] = []
    var failLists = false
    var failRecords = false
    var failCompletion = false
    var onCompletion: (() async -> Void)?
    var unfiltered = false
    var pausesNextLoad = false
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    var maxConcurrentReads = 0
    private var concurrentReads = 0

    func requestAccess() async throws -> ReminderAuthorization {
        accessRequests += 1
        authorization = nextAuthorization
        return authorization
    }
    func loadLists() async throws -> [ReminderList] {
        listLoads += 1
        if failLists { throw ReminderServiceError.fetchFailed }
        return lists
    }
    func loadReminders(listIDs: Set<String>) async throws -> [ReminderRecord] {
        requestedSelections.append(listIDs)
        concurrentReads += 1
        maxConcurrentReads = max(maxConcurrentReads, concurrentReads)
        defer { concurrentReads -= 1 }
        if pausesNextLoad {
            pausesNextLoad = false
            await withCheckedContinuation {
                paused = $0
                observer?.resume()
                observer = nil
            }
        }
        if failRecords { throw ReminderServiceError.fetchFailed }
        return unfiltered ? records : records.filter { listIDs.contains($0.listID) }
    }
    func setCompletion(identifier: String, listID: String, expected: Bool, completed: Bool) async throws -> ReminderRecord {
        writes.append((identifier, listID, expected, completed))
        if failCompletion { throw ReminderServiceError.saveFailed }
        guard let index = records.firstIndex(where: { $0.id == identifier && $0.listID == listID })
        else { throw ReminderServiceError.reminderUnavailable }
        guard records[index].allowsCompletionChanges else { throw ReminderServiceError.readOnly }
        guard records[index].isCompleted == expected else { throw ReminderServiceError.changedSinceRead }
        let old = records[index]
        records[index] = ReminderRecord(id: old.id, externalIdentifier: old.externalIdentifier, listID: old.listID,
            title: old.title, deadline: old.deadline, hasDateOnlyDeadline: old.hasDateOnlyDeadline,
            hasInvalidDeadline: old.hasInvalidDeadline, isCompleted: completed, allowsCompletionChanges: old.allowsCompletionChanges,
            isRecurring: old.isRecurring, occurrenceKey: old.occurrenceKey)
        await onCompletion?()
        return records[index]
    }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
}

nonisolated enum ReminderFixtures {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    static func date(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
    static func record(_ id: String = "r", list: String = "list", title: String = "合成Task",
                       deadline: Date? = date(23), completed: Bool = false, writable: Bool = true,
                       external: String? = "synthetic-external", recurring: Bool = false, occurrence: String? = nil) -> ReminderRecord {
        ReminderRecord(id: id, externalIdentifier: external, listID: list, title: title, deadline: deadline,
                       hasDateOnlyDeadline: false, hasInvalidDeadline: false, isCompleted: completed,
                       allowsCompletionChanges: writable, isRecurring: recurring, occurrenceKey: occurrence)
    }
    static func metadata(_ n: Int = 1, minutes: Int? = 60, override: Date? = nil, excluded: Bool = false,
                         external: String? = "synthetic-external", list: String = "list", occurrence: String? = nil) -> ReminderTaskMetadata {
        ReminderTaskMetadata(taskID: id(n), externalIdentifier: external, listID: list, estimatedMinutes: minutes,
                             deadlineOverride: override, isExcluded: excluded, occurrenceKey: occurrence)
    }
}
