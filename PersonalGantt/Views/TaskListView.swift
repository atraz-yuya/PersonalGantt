import SwiftUI

struct TaskListView: View {
    @Bindable var model: ScheduleViewModel
    let onDetail: (UUID) -> Void
    let onEdit: (Task) -> Void
    let onDelete: (Task) -> Void
    let onReminders: () -> Void

    var body: some View {
        List {
            if let reminders = model.reminders, !reminders.waitingRecords.isEmpty {
                Section("入力待ち") {
                    Text("\(reminders.waitingRecords.count)件のReminderに所要時間・締切などの設定が必要です。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("必要項目を設定", action: onReminders)
                }
            }
            Section("未完了タスク") {
                let pending = model.tasks.filter { !$0.isCompleted && $0.routineOccurrence == nil }.sorted(by: taskOrder)
                if pending.isEmpty { Text("未完了のタスクはありません。") .foregroundStyle(.secondary) }
                ForEach(pending) { row($0) }
            }
            let occurrences = model.tasks.filter { !$0.isCompleted && $0.routineOccurrence != nil }.sorted(by: taskOrder)
            if !occurrences.isEmpty {
                Section("ルーティン（各日）") { ForEach(occurrences) { row($0) } }
            }
            let completed = model.tasks.filter(\.isCompleted).sorted(by: taskOrder)
            if !completed.isEmpty {
                Section("完了タスク") { ForEach(completed) { row($0) } }
            }
            if !model.unscheduledTasks.isEmpty {
                Section("未配置の作業") {
                    ForEach(model.unscheduledTasks, id: \.id.uuidString) { task in
                        Button { onDetail(task.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).foregroundStyle(.primary)
                                Text("未配置 \(model.unallocatedMinutes(for: task).formatted())分").foregroundStyle(.orange)
                                if let message = model.feasibilityMessage(for: task) { Text(message).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain)
                    }
                    Text("締切・対象期間の空き時間または日次上限が不足しています。所要時間・締切・日次上限を確認してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("task-list")
    }

    private func taskOrder(_ lhs: Task, _ rhs: Task) -> Bool {
        lhs.deadline == rhs.deadline ? lhs.id.uuidString < rhs.id.uuidString : lhs.deadline < rhs.deadline
    }

    private func row(_ task: Task) -> some View {
        TaskRowView(task: task, scheduledMinutes: model.scheduledMinutes(for: task.id),
                    unallocatedMinutes: model.unallocatedMinutes(for: task),
                    isUnscheduled: model.result.unscheduledTaskIDs.contains(task.id),
                    onEdit: { onEdit(task) }, onDelete: { onDelete(task) },
                    onToggleCompletion: { _Concurrency.Task { await model.toggleTaskCompletion(id: task.id) } },
                    isReminderTask: model.isReminderTask(task.id), isBusy: model.taskIsBusy(task.id),
                    canToggleCompletion: model.canToggleTask(task), onDetail: { onDetail(task.id) },
                    feasibilityMessage: model.feasibilityMessage(for: task))
    }
}
