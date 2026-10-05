import Foundation

nonisolated struct ScheduledBlock: Identifiable, Codable, Equatable, Sendable {
    /// A natural key keeps both identity and equality stable across recalculation.
    struct ID: Hashable, Codable, Sendable {
        let taskID: UUID
        let start: Date
        let end: Date
    }

    let taskID: UUID
    var start: Date
    var end: Date

    var id: ID { ID(taskID: taskID, start: start, end: end) }
    var durationMinutes: Double { end.timeIntervalSince(start) / 60 }
}
