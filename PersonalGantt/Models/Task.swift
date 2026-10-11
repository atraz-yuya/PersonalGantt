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
    var priority: TaskPriority
    var routineOccurrence: RoutineOccurrence?

    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        estimatedMinutes: Int,
        deadline: Date,
        reminderIdentifier: String? = nil,
        routineOccurrence: RoutineOccurrence? = nil,
        priority: TaskPriority = .normal
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.estimatedMinutes = estimatedMinutes
        self.deadline = deadline
        self.reminderIdentifier = reminderIdentifier
        self.routineOccurrence = routineOccurrence
        self.priority = priority
    }
    enum CodingKeys: String, CodingKey { case id, title, isCompleted, estimatedMinutes, deadline, reminderIdentifier, routineOccurrence, priority }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        isCompleted = try c.decode(Bool.self, forKey: .isCompleted)
        estimatedMinutes = try c.decode(Int.self, forKey: .estimatedMinutes)
        deadline = try c.decode(Date.self, forKey: .deadline)
        reminderIdentifier = try c.decodeIfPresent(String.self, forKey: .reminderIdentifier)
        routineOccurrence = try c.decodeIfPresent(RoutineOccurrence.self, forKey: .routineOccurrence)
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .normal
    }
}
