import Foundation
import EventKit

@MainActor
final class EventKitReminderService: ReminderProviding {
    private let store: EKEventStore
    private let calendar: Calendar
    private var fetches: [UUID: (token: Any?, operation: ReminderFetchOperation)] = [:]

    init(store: EKEventStore = EKEventStore(), calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.calendar = calendar
    }

    var authorization: ReminderAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .restricted
        }
    }

    func requestAccess() async throws -> ReminderAuthorization {
        do { _ = try await store.requestFullAccessToReminders() }
        catch { throw ReminderServiceError.accessRequired }
        return authorization
    }

    func loadLists() async throws -> [ReminderList] {
        try requireAccess()
        return store.calendars(for: .reminder).map {
            ReminderList(id: $0.calendarIdentifier, title: $0.title, accountTitle: $0.source.title,
                         allowsCompletionChanges: $0.allowsContentModifications)
        }.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
    }

    func loadReminders(listIDs: Set<String>) async throws -> [ReminderRecord] {
        try requireAccess()
        guard !listIDs.isEmpty else { return [] }
        let lists = store.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        guard Set(lists.map(\.calendarIdentifier)) == listIDs else { throw ReminderServiceError.listUnavailable }
        let predicate = store.predicateForReminders(in: lists)
        let id = UUID()
        let conversionCalendar = calendar
        defer { fetches.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !_Concurrency.Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let operation = ReminderFetchOperation(continuation)
                fetches[id] = (nil, operation)
                let token = store.fetchReminders(matching: predicate,
                    completion: ReminderFetchCallbacks.make(operation, calendar: conversionCalendar))
                fetches[id] = (token, operation)
            }
        } onCancel: {
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, let request = self.fetches[id] else { return }
                if let token = request.token { self.store.cancelFetchRequest(token) }
                // EventKit does not invoke its callback after cancelFetchRequest.
                request.operation.finish(.failure(CancellationError()))
            }
        }
    }

    func setCompletion(identifier: String, listID: String, expected: Bool, completed: Bool) async throws -> ReminderRecord {
        try requireAccess()
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder,
              reminder.calendar.calendarIdentifier == listID else { throw ReminderServiceError.reminderUnavailable }
        guard reminder.calendar.allowsContentModifications else { throw ReminderServiceError.readOnly }
        guard reminder.isCompleted == expected else { throw ReminderServiceError.changedSinceRead }
        reminder.isCompleted = completed
        do { try store.save(reminder, commit: true) }
        catch {
            store.reset()
            throw ReminderServiceError.saveFailed
        }
        return ReminderEventKitConverter.record(from: reminder, calendar: calendar)
    }

    private func requireAccess() throws {
        guard authorization == .fullAccess else { throw ReminderServiceError.accessRequired }
    }
}

private nonisolated enum ReminderFetchCallbacks {
    static func make(_ operation: ReminderFetchOperation, calendar: Calendar) -> @Sendable ([EKReminder]?) -> Void {
        { reminders in
            guard let reminders else {
                operation.finish(.failure(ReminderServiceError.fetchFailed))
                return
            }
            let values = reminders.map { ReminderEventKitConverter.record(from: $0, calendar: calendar) }
            operation.finish(.success(values))
        }
    }
}

/// Synchronizes the callback/cancellation race; no EventKit object crosses this boundary.
private nonisolated final class ReminderFetchOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ReminderRecord], any Error>?
    init(_ continuation: CheckedContinuation<[ReminderRecord], any Error>) { self.continuation = continuation }
    func finish(_ result: Result<[ReminderRecord], any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
