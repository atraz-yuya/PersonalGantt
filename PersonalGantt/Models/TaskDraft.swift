import Foundation

/// Editable form values. Work placement remains exclusively the Scheduler's job.
nonisolated struct TaskDraft: Equatable, Sendable {
    var title: String
    var estimatedMinutesText: String
    var deadline: Date

    init(title: String = "", estimatedMinutesText: String = "60", deadline: Date) {
        self.title = title
        self.estimatedMinutesText = estimatedMinutesText
        self.deadline = deadline
    }

    init(task: Task) {
        title = task.title
        estimatedMinutesText = String(task.estimatedMinutes)
        deadline = task.deadline
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
        return ValidatedTaskInput(title: trimmedTitle, estimatedMinutes: minutes, deadline: deadline)
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
}

nonisolated enum TaskInputError: LocalizedError, Equatable {
    case emptyTitle
    case invalidMinutes
    case invalidDeadline
    case taskNotFound

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "タスク名を入力してください。"
        case .invalidMinutes: "所要時間は1分以上の整数で入力してください。"
        case .invalidDeadline: "有効な締切日時を選択してください。"
        case .taskNotFound: "このタスクは削除されています。一覧を確認してください。"
        }
    }
}
