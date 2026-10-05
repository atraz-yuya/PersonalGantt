import SwiftUI

struct ContentView: View {
    @State private var model = ScheduleViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("サンプルのタスクと空き時間から自動配置しています。", systemImage: "info.circle")
                        .font(.subheadline)
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
                    ForEach(model.tasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(task.title).font(.headline)
                                Spacer()
                                if task.isCompleted {
                                    Label("完了", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                } else if model.result.unscheduledTaskIDs.contains(task.id) {
                                    Label(model.scheduledMinutes(for: task.id) > 0 ? "一部未配置" : "未配置", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.orange)
                                } else {
                                    Label("配置済み", systemImage: "checkmark.circle")
                                        .foregroundStyle(.green)
                                }
                            }
                            .font(.subheadline)
                            Text("必要 \(task.estimatedMinutes)分 ・ 配置済み \(model.scheduledMinutes(for: task.id).formatted())分")
                                .font(.subheadline)
                            Text("締切: \(task.deadline.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
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
                        Text("締切前の空き時間が不足しています。")
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
                Button("再計算", systemImage: "arrow.clockwise") {
                    model.recalculate()
                }
            }
        }
        .frame(minWidth: 320, minHeight: 480)
    }
}

#Preview {
    ContentView()
}
