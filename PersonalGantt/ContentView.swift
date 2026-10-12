import SwiftUI
import EventKit
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    #if os(macOS)
    @State private var applicationIsActive = NSApplication.shared.isActive
    #endif
    @Bindable var model: ScheduleViewModel
    @State private var editor: TaskEditorRoute?
    @State private var detail: TaskDetailRoute?
    @State private var editorAfterDetail: TaskEditorRoute?
    @State private var taskToDelete: Task?
    @State private var destination: AppDestination = .today
    @State private var primaryTab: AppDestination = .today
    @State private var showsMenu = false
    @State private var pendingCommand: WorkspaceCommand?
    @State private var auxiliaryDestination: AppDestination?

    private var isForeground: Bool {
        #if os(macOS)
        applicationIsActive && scenePhase == .active
        #else
        scenePhase == .active
        #endif
    }

    private var usesCompactLayout: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        workspace
            .task(id: isForeground) {
                guard isForeground else { return }
                while !_Concurrency.Task.isCancelled {
                    do { try await _Concurrency.Task.sleep(for: .seconds(120)) } catch { return }
                    await model.synchronizeIfActive()
                }
            }
            .onChange(of: model.syncState.isEnabled) { _, enabled in
                if enabled { _Concurrency.Task { await model.synchronizeIfActive() } }
            }
            .onChange(of: model.result.blocks) { _, _ in
                _Concurrency.Task { await model.publishScheduleIfActive() }
            }
            .onChange(of: model.tasks) { _, _ in
                _Concurrency.Task { await model.publishScheduleIfActive() }
            }
            .onChange(of: model.syncState.records) { _, _ in
                _Concurrency.Task { await model.synchronizeIfActive() }
            }
            .onChange(of: model.planningInterval) { _, _ in
                _Concurrency.Task { await model.refreshPlanningCoverageIfNeeded() }
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
            .sheet(isPresented: $showsMenu, onDismiss: {
                if let command = pendingCommand { pendingCommand = nil; perform(command) }
            }) {
                NavigationStack {
                    AppSidebarView(model: model, selection: auxiliaryDestination ?? primaryTab) { command in
                        pendingCommand = command; showsMenu = false
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showsMenu = false } } }
                }
            }
            .sheet(item: $auxiliaryDestination) { route in
                NavigationStack {
                    selectedScreen(route)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { auxiliaryDestination = nil } } }
                }.id(route)
            }
            .sheet(item: $editor) { TaskEditingSheet(model: model, task: $0.task) }
            .sheet(item: $detail, onDismiss: {
                if let pending = editorAfterDetail {
                    editorAfterDetail = nil
                    editor = pending
                }
            }) { route in
                TaskDetailView(model: model, taskID: route.id) { task in
                    editorAfterDetail = TaskEditorRoute(task: task)
                    detail = nil
                }
            }
            .alert(
                taskToDelete.map { $0.routineOccurrence != nil ? "この日のルーティンをスキップしますか？" : model.isReminderTask($0.id) ? "配置対象から外しますか？" : "タスクを削除しますか？" } ?? "タスクを削除しますか？",
                isPresented: Binding(
                    get: { taskToDelete != nil },
                    set: { if !$0 { taskToDelete = nil } }
                ),
                presenting: taskToDelete
            ) { task in
                Button(task.routineOccurrence != nil ? "この日をスキップ" : model.isReminderTask(task.id) ? "配置対象から外す" : "削除", role: .destructive) {
                    model.deleteTask(id: task.id)
                    taskToDelete = nil
                }
                Button("キャンセル", role: .cancel) { taskToDelete = nil }
            } message: { task in
                Text(task.routineOccurrence != nil
                     ? "この日の作業要件だけを配置対象から外します。ルーティンと開始済みの時間枠は保持します。"
                     : model.isReminderTask(task.id)
                     ? "「\(task.title)」をPersonalGanttの配置対象から外し、スケジュールを再計算します。Apple Remindersの内容は残ります。"
                     : "「\(task.title)」を削除し、スケジュールを再計算します。")
            }
        #if os(macOS)
            .frame(minWidth: 900, minHeight: 640)
        #else
            .frame(minWidth: 320, minHeight: 480)
        #endif
    }

    @ViewBuilder private var workspace: some View {
        if usesCompactLayout {
            TabView(selection: $primaryTab) {
                ForEach([AppDestination.today, .day, .tasks]) { route in
                    NavigationStack {
                        selectedScreen(route)
                            .navigationTitle(route.title)
                            .toolbar {
                                ToolbarItem(placement: .navigation) {
                                    Button { showsMenu = true } label: { Label("メニュー", systemImage: "line.3.horizontal") }
                                        .labelStyle(.iconOnly).accessibilityLabel("サイドメニューを開く")
                                        .accessibilityIdentifier("open-sidebar")
                                }
                            }
                    }.tabItem { Label(route.title, systemImage: route.symbol) }.tag(route)
                }
            }
        } else {
            NavigationSplitView {
                AppSidebarView(model: model, selection: destination, onCommand: perform)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 300)
            } detail: {
                NavigationStack {
                    selectedScreen(destination).navigationTitle(destination.title)
                }.id(destination)
            }
        }
    }

    @ViewBuilder private func selectedScreen(_ route: AppDestination) -> some View {
        switch route {
        case .today:
            TodayView(model: model, onDetail: showDetail, onInputQueue: { perform(.show(.inputQueue)) }, onSettings: { perform(.show(.settings)) })
        case .day: ScheduleWorkspaceView(model: model, includesToday: false, onDetail: showDetail)
        case .tasks:
            TaskListView(model: model, onDetail: showDetail, onEdit: { editor = TaskEditorRoute(task: $0) },
                onDelete: { taskToDelete = $0 }, onInputQueue: { perform(.show(.inputQueue)) })
        case .inputQueue: InputQueueView(model: model, onSettings: { perform(.show(.settings)) })
        case .settings: AppSettingsView(model: model)
        }
    }

    private func perform(_ command: WorkspaceCommand) {
        switch command {
        case .show(let route):
            if route.isPrimaryTab { primaryTab = route; destination = route; auxiliaryDestination = nil }
            else if usesCompactLayout { auxiliaryDestination = route }
            else { destination = route }
        case .addTask: editor = TaskEditorRoute(task: nil)
        case .refreshCalendar: _Concurrency.Task { await model.refreshCalendars() }
        case .recalculate: model.recalculate()
        }
    }

    private func showDetail(_ id: UUID) { detail = TaskDetailRoute(id: id) }

}

private struct TaskEditorRoute: Identifiable {
    let id = UUID()
    let task: Task?
}
private struct TaskDetailRoute: Identifiable { let id: UUID }

#Preview { ContentView(model: ScheduleViewModel(tasks: [], availableSlots: [])) }
