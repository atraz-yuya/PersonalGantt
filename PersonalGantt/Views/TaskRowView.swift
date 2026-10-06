import SwiftUI

struct TaskRowView: View {
    let task: Task
    let scheduledMinutes: Double
    let unallocatedMinutes: Double
    let isUnscheduled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleCompletion: () -> Void
    var isReminderTask = false
    var isBusy = false
    var canToggleCompletion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.isCompleted)
                Spacer()
                status
            }
            if task.isCompleted {
                Text("必要 \(task.estimatedMinutes)分 ・ 完了済み")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("必要 \(task.estimatedMinutes)分 ・ 配置済み \(scheduledMinutes.formatted())分")
                    .font(.subheadline)
                if isUnscheduled {
                    Text("未配置 \(unallocatedMinutes.formatted())分")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            Text("締切: \(task.deadline.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isReminderTask {
                Label("Apple Reminders連携", systemImage: "checklist")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button(task.isCompleted ? "未完了に戻す" : "完了にする", action: onToggleCompletion)
                    .disabled(isBusy || !canToggleCompletion)
                    .accessibilityIdentifier("toggle-task-\(task.id)")
                Button("編集", action: onEdit)
                    .disabled(isBusy)
                    .accessibilityIdentifier("edit-task-\(task.id)")
                Spacer()
                Button(isReminderTask ? "配置対象から外す" : "削除", role: .destructive, action: onDelete)
                    .disabled(isBusy)
                    .accessibilityIdentifier("delete-task-\(task.id)")
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
    }

    @ViewBuilder private var status: some View {
        if task.isCompleted {
            Label("完了", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        } else if isUnscheduled {
            Label(scheduledMinutes > 0 ? "一部未配置" : "配置不能", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .font(.subheadline)
        } else {
            Label("配置済み", systemImage: "checkmark.circle").foregroundStyle(.green)
        }
    }
}
