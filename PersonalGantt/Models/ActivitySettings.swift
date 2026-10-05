import Foundation

nonisolated struct ActivityWindow: Equatable, Sendable {
    /// Local minutes after midnight. End may be 1440 (next midnight).
    var startMinute: Int
    var endMinute: Int

    var isValid: Bool {
        (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute
    }
}

nonisolated struct ActivitySettings: Equatable, Sendable {
    var weekday = ActivityWindow(startMinute: 8 * 60, endMinute: 23 * 60)
    var weekend = ActivityWindow(startMinute: 9 * 60, endMinute: 23 * 60)
    /// Today is day 1; the interval ends at midnight after day 14.
    var planningDayCount = 14

    static let `default` = ActivitySettings()

    var isValid: Bool { weekday.isValid && weekend.isValid && planningDayCount > 0 }
}
