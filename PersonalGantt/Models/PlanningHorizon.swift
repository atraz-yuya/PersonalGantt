import Foundation

nonisolated struct PlanningHorizonSettings: Codable, Equatable, Sendable {
    var minimumDays = 14
    var maximumDays = 90
    static let `default` = PlanningHorizonSettings()
    var isValid: Bool { minimumDays > 0 && maximumDays >= minimumDays && maximumDays <= 90 }
}

/// Half-open range. Starting at local midnight keeps API requests stable while
/// availability separately clips elapsed time to now.
nonisolated struct PlanningHorizon: Equatable, Sendable {
    var start: Date
    var end: Date
    var wasCapped: Bool
    var interval: DateInterval { DateInterval(start: start, end: end) }
}

/// Successful event retrieval for one calendar selection/account. Never inferred
/// from the desired horizon once the explicit coverage field is available.
nonisolated struct CalendarCoverage: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var interval: DateInterval { DateInterval(start: start, end: end) }
    func contains(_ range: DateInterval) -> Bool { start <= range.start && end >= range.end }
    func intersection(with range: DateInterval) -> DateInterval? {
        let lower = max(start, range.start), upper = min(end, range.end)
        return lower < upper ? DateInterval(start: lower, end: upper) : nil
    }
}

nonisolated enum UnscheduledReason: Equatable, Sendable {
    case insufficientCapacityBeforeDeadline
    case deadlineBeyondPlanningHorizon
    case calendarCoveragePending
    case dailyWorkloadLimit
    case noAvailability
}
