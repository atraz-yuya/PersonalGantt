import Foundation
import EventKit

/// Injection boundary: tests can provide calendar snapshots without OS permissions.
@MainActor
protocol CalendarProviding {
    var authorization: CalendarAuthorization { get }
    func requestAccess() async throws -> CalendarAuthorization
    func loadCalendars() throws -> [CalendarSource]
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) throws -> [FixedEvent]
}

nonisolated enum CalendarServiceError: LocalizedError, Equatable {
    case accessRequired
    case calendarUnavailable

    var errorDescription: String? {
        switch self {
        case .accessRequired: "カレンダーを読み取る権限がありません。"
        case .calendarUnavailable: "選択したカレンダーが見つかりません。一覧を再読み込みしてください。"
        }
    }
}

@MainActor
final class CalendarService: CalendarProviding {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) { self.store = store }

    var authorization: CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAccess() async throws -> CalendarAuthorization {
        if authorization == .notDetermined || authorization == .writeOnly {
            _ = try await store.requestFullAccessToEvents()
        }
        return authorization
    }

    func loadCalendars() throws -> [CalendarSource] {
        guard authorization == .fullAccess else { throw CalendarServiceError.accessRequired }
        // Drop cached EK objects and refetch after an explicit refresh.
        store.reset()
        return store.calendars(for: .event).map {
            CalendarSource(id: $0.calendarIdentifier, title: $0.title, accountTitle: $0.source.title)
        }.sorted {
            if $0.accountTitle != $1.accountTitle { return $0.accountTitle < $1.accountTitle }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) throws -> [FixedEvent] {
        guard authorization == .fullAccess else { throw CalendarServiceError.accessRequired }
        // Never pass nil calendars: nil would read every calendar.
        guard !calendarIDs.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard calendars.count == calendarIDs.count else { throw CalendarServiceError.calendarUnavailable }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            guard let calendarID = event.calendar?.calendarIdentifier else { return nil }
            return Self.fixedEvent(from: event, calendarID: calendarID)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    static func fixedEvent(from event: EKEvent, calendarID: String) -> FixedEvent? {
        guard event.status != .canceled,
              let start = event.startDate, let end = event.endDate,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, start < end else { return nil }
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let occurrenceID = "\(calendarID):\(identifier):\(start.timeIntervalSinceReferenceDate.bitPattern):\(end.timeIntervalSinceReferenceDate.bitPattern)"
        return FixedEvent(id: occurrenceID, calendarID: calendarID, title: event.title ?? "名称未設定",
                          start: start, end: end, isAllDay: event.isAllDay)
    }
}
