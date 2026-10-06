import Foundation

/// A user's work requirement. Start/end times belong to ScheduledBlock.
nonisolated struct Task: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var isCompleted: Bool
    var estimatedMinutes: Int
    var deadline: Date
    /// Local association; estimatedMinutes stays in PersonalGantt.
    var reminderIdentifier: String?

    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        estimatedMinutes: Int,
        deadline: Date,
        reminderIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.estimatedMinutes = estimatedMinutes
        self.deadline = deadline
        self.reminderIdentifier = reminderIdentifier
    }
}
