import Foundation

/// Calendar retrieval boundary; implementations own authentication and transport.
@MainActor
protocol CalendarProviding {
    var authorization: CalendarAuthorization { get }
    func requestAccess() async throws -> CalendarAuthorization
    func loadCalendars() async throws -> [CalendarSource]
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent]
    func validateConnection() async throws
}

extension CalendarProviding {
    func validateConnection() async throws {
        guard authorization == .connected else { throw CalendarServiceError.accessRequired }
    }
}

nonisolated enum CalendarServiceError: LocalizedError, Equatable {
    case accessRequired
    case calendarUnavailable
    case planningPeriodChanged
    var errorDescription: String? {
        switch self {
        case .accessRequired: "Google Calendarへのログインが必要です。"
        case .calendarUnavailable: "選択したカレンダーが見つかりません。一覧を再読み込みしてください。"
        case .planningPeriodChanged: "読み込み中に日付が変わりました。もう一度再読み込みしてください。"
        }
    }
}
