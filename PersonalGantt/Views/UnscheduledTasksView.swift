import SwiftUI

struct UnscheduledTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    let onDetail: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("計画全体の未配置の作業です。今日以外の作業や、一部だけ配置されたタスクも含みます。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.unscheduledTasks.isEmpty {
                        Label("未配置の作業はありません。", systemImage: "checkmark.circle")
                    }
                    ForEach(model.unscheduledTasks.sorted {
                        $0.deadline == $1.deadline ? $0.id.uuidString < $1.id.uuidString : $0.deadline < $1.deadline
                    }) { task in
                        UnscheduledTaskRow(model: model, task: task, onDetail: onDetail)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("未配置の作業（\(model.unscheduledTasks.count)件）")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .accessibilityIdentifier("unscheduled-task-list")
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 420)
        #endif
    }
}

struct UnscheduledTaskRow: View {
    @Bindable var model: ScheduleViewModel
    let task: Task
    let onDetail: (UUID) -> Void

    var body: some View {
        Button { onDetail(task.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.headline).foregroundStyle(.primary)
                    Text("未配置 \(model.unallocatedMinutes(for: task).rounded(.up).formatted())分")
                        .foregroundStyle(.orange)
                    Text("締切: \(task.deadline.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = model.feasibilityMessage(for: task) {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("タスク詳細を開きます")
        .accessibilityIdentifier("unscheduled-task-\(task.id)")
    }
}
