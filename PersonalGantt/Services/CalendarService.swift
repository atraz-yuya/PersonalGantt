import Foundation

/// Calendar retrieval boundary; implementations own authentication and transport.
@MainActor
protocol CalendarProviding {
    var authorization: CalendarAuthorization { get }
    func requestAccess() async throws -> CalendarAuthorization
    func loadCalendars() async throws -> [CalendarSource]
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent]
}

nonisolated enum CalendarServiceError: LocalizedError, Equatable {
    case accessRequired
    case calendarUnavailable
    var errorDescription: String? {
        switch self {
        case .accessRequired: "Google Calendarへのログインが必要です。"
        case .calendarUnavailable: "選択したカレンダーが見つかりません。一覧を再読み込みしてください。"
        }
    }
}
