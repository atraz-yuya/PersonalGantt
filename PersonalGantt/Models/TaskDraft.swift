import Foundation

/// Editable form values. Work placement remains exclusively the Scheduler's job.
nonisolated struct TaskDraft: Equatable, Sendable {
    var title: String
    var estimatedMinutesText: String
    var deadline: Date
    var priority: TaskPriority
    var availabilityExclusions: [TaskAvailabilityExclusion]

    init(title: String = "", estimatedMinutesText: String = "60", deadline: Date, priority: TaskPriority = .normal, availabilityExclusions: [TaskAvailabilityExclusion] = []) {
        self.title = title
        self.estimatedMinutesText = estimatedMinutesText
        self.deadline = deadline
        self.priority = priority
        self.availabilityExclusions = availabilityExclusions
    }

    init(task: Task) {
        title = task.title
        estimatedMinutesText = String(task.estimatedMinutes)
        deadline = task.deadline
        priority = task.priority
        availabilityExclusions = task.availabilityExclusions
    }

    /// Share the same validation between the form and all ViewModel mutations.
    func validated() throws -> ValidatedTaskInput {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw TaskInputError.emptyTitle }
        let minutesText = estimatedMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(minutesText), minutes > 0 else {
            throw TaskInputError.invalidMinutes
        }
        guard deadline.timeIntervalSinceReferenceDate.isFinite,
              deadline >= .distantPast, deadline <= .distantFuture else {
            throw TaskInputError.invalidDeadline
        }
        guard AvailabilityExclusion.valid(availabilityExclusions) else { throw TaskInputError.invalidAvailabilityExclusions }
        return ValidatedTaskInput(title: trimmedTitle, estimatedMinutes: minutes, deadline: deadline, priority: priority, availabilityExclusions: availabilityExclusions)
    }

    var validationMessage: String? {
        do {
            _ = try validated()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

nonisolated struct ValidatedTaskInput: Equatable, Sendable {
    let title: String
    let estimatedMinutes: Int
    let deadline: Date
    let priority: TaskPriority
    let availabilityExclusions: [TaskAvailabilityExclusion]
}

nonisolated enum TaskInputError: LocalizedError, Equatable {
    case emptyTitle
    case invalidMinutes
    case invalidDeadline
    case taskNotFound
    case invalidAvailabilityExclusions

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "タスク名を入力してください。"
        case .invalidMinutes: "所要時間は1分以上の整数で入力してください。"
        case .invalidDeadline: "有効な締切日時を選択してください。"
        case .invalidAvailabilityExclusions: "配置禁止時間の曜日と開始・終了時刻を確認してください。"
        case .taskNotFound: "このタスクは削除されています。一覧を確認してください。"
        }
    }
}
