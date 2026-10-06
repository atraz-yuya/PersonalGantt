import Foundation

nonisolated struct AvailableSlot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var start: Date
    var end: Date

    init(id: UUID = UUID(), start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}
