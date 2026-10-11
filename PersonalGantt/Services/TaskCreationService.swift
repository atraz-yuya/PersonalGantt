import Foundation

/// Uses the form's creation path, with durable success required for unattended use.
@MainActor
struct TaskCreationService {
    let model: ScheduleViewModel

    func create(title: String, estimatedMinutes: Int, deadline: Date) throws -> TaskCreationReceipt {
        let draft = TaskDraft(title: title, estimatedMinutesText: String(estimatedMinutes), deadline: deadline)
        let task = try model.addTask(draft, requirePersistence: true)
        return TaskCreationReceipt(task: task, unallocatedMinutes: model.unallocatedMinutes(for: task),
                                   isScheduleSaved: model.persistenceMessage == nil)
    }
}

nonisolated struct TaskCreationReceipt: Sendable {
    let task: Task
    let unallocatedMinutes: Double
    let isScheduleSaved: Bool

    var dialogText: String {
        let deadlineText = task.deadline.formatted(date: .abbreviated, time: .shortened)
        let confirmation = "\(task.title)を\(task.estimatedMinutes)分、\(deadlineText)締切で追加しました。"
        if !isScheduleSaved {
            return confirmation + "タスクは保存済みですが、作業予定の保存を再試行する必要があります。アプリで確認してください。"
        }
        if unallocatedMinutes > 0 {
            // Keep large, valid Int estimates out of an unsafe Double-to-Int cast.
            let minutes = unallocatedMinutes.formatted(.number.precision(.fractionLength(0)).grouping(.never))
            return confirmation + "現在の空き時間では締切までに\(minutes)分配置できませんでした。"
        }
        return confirmation
    }
}
