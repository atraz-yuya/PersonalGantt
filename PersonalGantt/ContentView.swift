import SwiftUI

struct ContentView: View {
    @State private var model = ScheduleViewModel()
    @State private var editor: TaskEditorRoute?
    @State private var taskToDelete: Task?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("空き時間はサンプルです。タスクを操作すると予定が自動で更新されます。", systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("データはアプリ終了時に消えます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("作業スケジュール") {
                    if model.result.blocks.isEmpty {
                        Text("配置できる作業がありません。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.result.blocks) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.title(for: block.taskID)).font(.headline)
                            Text(block.start, format: .dateTime.month().day().weekday())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(block.start, style: .time)
                                Text("–")
                                Text(block.end, style: .time)
                                Spacer()
                                Text("\(block.durationMinutes.formatted())分")
                            }
                            .font(.subheadline.monospacedDigit())
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("タスク") {
                    if model.tasks.isEmpty {
                        Text("タスクがありません。「タスクを追加」から登録してください。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.tasks) { task in
                        TaskRowView(
                            task: task,
                            scheduledMinutes: model.scheduledMinutes(for: task.id),
                            unallocatedMinutes: model.unallocatedMinutes(for: task),
                            isUnscheduled: model.result.unscheduledTaskIDs.contains(task.id),
                            onEdit: { editor = TaskEditorRoute(task: task) },
                            onDelete: { taskToDelete = task },
                            onToggleCompletion: { model.toggleCompletion(id: task.id) }
                        )
                    }
                }

                if !model.result.unscheduledTaskIDs.isEmpty {
                    Section("締切までに配置できない作業") {
                        // Use a different identity type from the task list above.
                        // macOS List otherwise reuses those rows across sections.
                        ForEach(model.unscheduledTasks, id: \.id.uuidString) { task in
                            HStack {
                                Text(task.title)
                                Spacer()
                                Text("残り \(model.unallocatedMinutes(for: task).formatted())分")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("締切前の空き時間が不足しているか、締切までに利用できる枠がありません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("配置に使用した空き時間") {
                    ForEach(model.availableSlots) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(slot.start, format: .dateTime.month().day().weekday())
                            HStack {
                                Text(slot.start, style: .time)
                                Text("–")
                                Text(slot.end, style: .time)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("PersonalGantt")
            .toolbar {
                Button("タスクを追加", systemImage: "plus") {
                    editor = TaskEditorRoute(task: nil)
                }
                .accessibilityIdentifier("add-task")
                Button("再計算", systemImage: "arrow.clockwise") {
                    model.recalculate()
                }
            }
            .sheet(item: $editor) { route in
                TaskEditorView(
                    task: route.task,
                    defaultDeadline: model.availableSlots.last?.end ?? Date().addingTimeInterval(86_400)
                ) { draft in
                    if let task = route.task {
                        try model.updateTask(id: task.id, draft: draft)
                    } else {
                        try model.addTask(draft)
                    }
                }
            }
            .alert(
                "タスクを削除しますか？",
                isPresented: Binding(
                    get: { taskToDelete != nil },
                    set: { if !$0 { taskToDelete = nil } }
                ),
                presenting: taskToDelete
            ) { task in
                Button("削除", role: .destructive) {
                    model.deleteTask(id: task.id)
                    taskToDelete = nil
                }
                Button("キャンセル", role: .cancel) { taskToDelete = nil }
            } message: { task in
                Text("「\(task.title)」を削除し、スケジュールを再計算します。")
            }
        }
        .frame(minWidth: 320, minHeight: 480)
    }
}

private struct TaskEditorRoute: Identifiable {
    let id = UUID()
    let task: Task?
}

#Preview {
    ContentView()
}
