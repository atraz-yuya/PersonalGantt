import SwiftUI
import EventKit
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
    @State private var showsReminderSelection = false

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
                    Text("連携TaskはRemindersから復元します。所要時間と選択はこの端末に保存します。手動Taskと計画履歴はアプリ終了時に消えます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let range = model.planningInterval {
                        Text("対象: \(range.start.formatted(date: .abbreviated, time: .omitted)) 〜 \(range.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                    }
                    Button("使用するカレンダーを選択") { showsCalendarSelection = true }
                    if let reminders = model.reminders {
                        Button("使用するRemindersを選択") { showsReminderSelection = true }
                        Text("Reminders: \(reminders.importedTasks.count)件のTask・\(reminders.waitingRecords.count)件が入力待ち")
                            .font(.caption).foregroundStyle(.secondary)
                        if reminders.isLoading { ProgressView("Remindersを読み込み中…") }
                        if let message = reminders.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    }
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
                        Text("タスクがありません。Remindersを選択して所要時間を設定するか、「タスクを追加」から登録してください。")
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
                            onToggleCompletion: {
                                _Concurrency.Task { await model.toggleTaskCompletion(id: task.id) }
                            },
                            isReminderTask: model.isReminderTask(task.id),
                            isBusy: model.isReminderTask(task.id) && (model.reminders?.isLoading ?? false),
                            canToggleCompletion: !model.isReminderTask(task.id) ||
                                (task.reminderIdentifier.flatMap { model.reminders?.record(for: $0)?.allowsCompletionChanges } ?? false)
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
                if let reminders = model.reminders {
                    Button("Remindersを再読み込み", systemImage: "checklist") {
                        _Concurrency.Task { await reminders.refresh() }
                    }.disabled(reminders.isLoading)
                }
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
                _Concurrency.Task {
                    await model.reminders?.loadState()
                    await model.refreshCalendars()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                guard isForeground else { return }
                _Concurrency.Task { await model.reminders?.refresh() }
            }
            .sheet(isPresented: $showsCalendarSelection) {
                CalendarSelectionView(model: model)
            }
            .sheet(isPresented: $showsReminderSelection) {
                if let reminders = model.reminders { ReminderSelectionView(model: reminders) }
            }
            .sheet(item: $editor) { route in
                TaskEditorView(
                    task: route.task,
                    defaultDeadline: model.availableSlots.last?.end ?? Date().addingTimeInterval(86_400),
                    ownsTitle: route.task.map { !model.isReminderTask($0.id) } ?? true,
                    ownsDeadline: route.task.map { task in
                        !model.isReminderTask(task.id) || task.reminderIdentifier.flatMap { model.reminders?.record(for: $0)?.deadline } == nil
                    } ?? true
                ) { draft in
                    if let task = route.task {
                        try model.updateTask(id: task.id, draft: draft)
                    } else {
                        try model.addTask(draft)
                    }
                }
            }
            .alert(
                taskToDelete.map { model.isReminderTask($0.id) ? "配置対象から外しますか？" : "タスクを削除しますか？" } ?? "タスクを削除しますか？",
                isPresented: Binding(
                    get: { taskToDelete != nil },
                    set: { if !$0 { taskToDelete = nil } }
                ),
                presenting: taskToDelete
            ) { task in
                Button(model.isReminderTask(task.id) ? "配置対象から外す" : "削除", role: .destructive) {
                    model.deleteTask(id: task.id)
                    taskToDelete = nil
                }
                Button("キャンセル", role: .cancel) { taskToDelete = nil }
            } message: { task in
                Text(model.isReminderTask(task.id)
                     ? "「\(task.title)」をPersonalGanttの配置対象から外し、スケジュールを再計算します。Apple Remindersの内容は残ります。"
                     : "「\(task.title)」を削除し、スケジュールを再計算します。")
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
