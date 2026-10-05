import Foundation

/// A copied occurrence. No EventKit object escapes the calendar service.
nonisolated struct FixedEvent: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var isCancelled: Bool = false
}
