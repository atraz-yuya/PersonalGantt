import SwiftUI

struct TaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    let taskID: UUID
    let onEdit: (Task) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("作業内容") {
                    Text(model.title(for: taskID)).font(.title2.bold())
                    if let task = model.task(for: taskID) {
                        LabeledContent("状態", value: task.isCompleted ? "完了" : "未完了")
                        LabeledContent("必要時間", value: "\(task.estimatedMinutes)分")
                        LabeledContent("締切", value: task.deadline.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("配置時間", value: "\(model.scheduledMinutes(for: taskID).formatted())分")
                        if let occurrence = task.routineOccurrence {
                            Label("ルーティン・\(occurrence.dayStart.formatted(date: .abbreviated, time: .omitted))", systemImage: "repeat")
                            Text("完了はこの日の作業だけに適用します。編集ではルーティン全体の設定を変更します。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !task.isCompleted {
                            LabeledContent("未配置時間", value: "\(model.unallocatedMinutes(for: task).formatted())分")
                            if model.result.unscheduledTaskIDs.contains(taskID) {
                                Label("締切・対象期間の空き時間または日次上限が不足しています。", systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                            }
                        }
                        if model.isReminderTask(taskID) {
                            Label("Apple Reminders連携", systemImage: "checklist")
                            Text("タイトルとReminders側の締切は、Apple Remindersで変更してください。所要時間はこの端末で設定します。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(task.isCompleted ? "未完了に戻す" : "Taskを完了にする") {
                            _Concurrency.Task { await model.toggleTaskCompletion(id: taskID) }
                        }.disabled(model.taskIsBusy(taskID) || !model.canToggleTask(task))
                    } else {
                        Text("このTaskは配置対象から外れています。開始済みの時間枠を表示します。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("配置された時間枠") {
                    let blocks = model.result.blocks.filter { $0.taskID == taskID }.sorted { $0.start < $1.start }
                    if blocks.isEmpty { Text("配置された時間枠はありません。") .foregroundStyle(.secondary) }
                    ForEach(blocks) { block in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(block.start.formatted(date: .abbreviated, time: .shortened)) – \(block.end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline.monospacedDigit())
                            Text("\(block.durationMinutes.formatted())分").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("配置時間は作業実績ではありません。開始・終了時刻はSchedulerが決定します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.reminders?.message, model.isReminderTask(taskID) {
                    Text(message).foregroundStyle(.orange)
                }
            }
            .navigationTitle("タスク詳細")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let task = model.task(for: taskID) {
                        Button("編集") { onEdit(task) }
                            .disabled(model.taskIsBusy(taskID))
                            .accessibilityIdentifier("detail-edit-task")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 520)
        #endif
    }
}

struct TaskEditingSheet: View {
    @Bindable var model: ScheduleViewModel
    let task: Task?
    var body: some View {
        if let occurrence = task?.routineOccurrence, let routine = model.routines.first(where: { $0.id == occurrence.routineID }) {
            RoutineEditorView(routine: routine, calendar: model.presentationCalendar) { try model.saveRoutine($0) }
        } else {
            TaskEditorView(task: task, defaultDeadline: model.availableSlots.last?.end ?? Date().addingTimeInterval(86_400),
                           ownsTitle: task.map { !model.isReminderTask($0.id) } ?? true,
                           ownsDeadline: task.map { value in
                               !model.isReminderTask(value.id) || value.reminderIdentifier.flatMap { model.reminders?.record(for: $0)?.deadline } == nil
                           } ?? true) { draft in
                if let task { try model.updateTask(id: task.id, draft: draft) }
                else { try model.addTask(draft) }
            }
        }
    }
}
