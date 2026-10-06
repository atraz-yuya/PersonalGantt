import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @State private var applicationIsActive = NSApplication.shared.isActive
    #endif
    @State private var model = ScheduleViewModel()
    @State private var editor: TaskEditorRoute?
    @State private var taskToDelete: Task?
    @State private var showsCalendarSelection = false

    private var isForeground: Bool {
        #if os(macOS)
        applicationIsActive && scenePhase == .active
        #else
        scenePhase == .active
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.availabilityDescription, systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Taskと計画はアプリ終了時に消えます。Calendar選択とGoogle接続は保存します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let range = model.planningInterval {
                        Text("対象: \(range.start.formatted(date: .abbreviated, time: .omitted)) 〜 \(range.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                    }
                    Button("使用するカレンダーを選択") { showsCalendarSelection = true }
                    if let refreshed = model.lastCalendarRefresh {
                        Text("最終読み込み: \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.calendarMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                    if model.protectedConflictCount > 0 {
                        Label("進行中の作業と固定予定が重なっています。開始済みの作業は保持しています。", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if model.isLoadingCalendars { ProgressView("カレンダーを読み込み中…") }
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
                Button("Google Calendarを再読み込み", systemImage: "calendar.badge.clock") {
                    _Concurrency.Task { await model.refreshCalendars() }
                }
                .disabled(model.isLoadingCalendars)
            }
            .task(id: isForeground) {
                guard isForeground else {
                    model.applicationDidBecomeInactive()
                    return
                }
                await model.applicationDidBecomeActive()
                // Only the active scene owns this timer. SwiftUI cancels it on backgrounding.
                while !_Concurrency.Task.isCancelled {
                    let delay = max(1, model.nextPlanningDay.timeIntervalSinceNow)
                    do { try await _Concurrency.Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    await model.refreshForDayChangeIfNeeded()
                }
            }
            .onChange(of: isForeground) { _, active in
                if !active { model.applicationDidBecomeInactive() }
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                applicationIsActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                applicationIsActive = false
                model.applicationDidBecomeInactive()
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                guard isForeground else { return }
                _Concurrency.Task { await model.refreshForDayChangeIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                guard isForeground else { return }
                _Concurrency.Task { await model.refreshCalendars() }
            }
            .sheet(isPresented: $showsCalendarSelection) {
                CalendarSelectionView(model: model)
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
