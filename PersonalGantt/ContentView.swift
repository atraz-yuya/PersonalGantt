import SwiftUI
import EventKit
import UniformTypeIdentifiers
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
    @State private var showsCalendarSelection = false
    @State private var showsReminderSelection = false
    @State private var showsBackupExport = false
    @State private var showsBackupImport = false
    @State private var backupDocument: BackupFileDocument?
    @State private var importedBackup: PersonalGanttBackup?
    @State private var backupError: String?

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
            .sheet(isPresented: $showsCalendarSelection) { CalendarSelectionView(model: model) }
            .sheet(isPresented: $showsReminderSelection) {
                if let reminders = model.reminders { ReminderSelectionView(model: reminders) }
            }
            .fileExporter(isPresented: $showsBackupExport, document: backupDocument, contentType: .json,
                          defaultFilename: "PersonalGantt-Backup-" + Date().formatted(.iso8601.year().month().day())) { outcome in
                if case .failure(let error) = outcome, !isFileCancellation(error) {
                    backupError = "ファイルを書き出せませんでした。保存先を確認してください。"
                }
            }
            .fileImporter(isPresented: $showsBackupImport, allowedContentTypes: [.json]) { outcome in
                do {
                    let url = try outcome.get()
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= PersonalGanttBackup.maximumBytes else { throw BackupError.tooLarge }
                    importedBackup = try PersonalGanttBackup.decode(Data(contentsOf: url))
                } catch {
                    if !isFileCancellation(error) {
                        backupError = (error as? BackupError)?.localizedDescription ?? "ファイルを読み込めませんでした。現在のデータは変更していません。"
                    }
                }
            }
            .sheet(isPresented: Binding(get: { importedBackup != nil }, set: { if !$0 { importedBackup = nil } })) {
                if let importedBackup {
                    BackupPreviewView(model: model, backup: importedBackup) {
                        do {
                            try model.restoreBackup(importedBackup)
                            self.importedBackup = nil
                            _Concurrency.Task {
                                await model.reminders?.loadState()
                                await model.refreshCalendars()
                            }
                        } catch {
                            self.importedBackup = nil
                            backupError = (error as? BackupError)?.localizedDescription ?? BackupError.unavailable.localizedDescription
                        }
                    }
                }
            }
            .alert("バックアップ", isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })) {
                Button("閉じる") { backupError = nil }
            } message: { Text(backupError ?? "") }
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
        #if os(macOS)
            .frame(minWidth: 900, minHeight: 640)
        #else
            .frame(minWidth: 320, minHeight: 480)
        #endif
    }

    @ViewBuilder private var workspace: some View {
        if usesCompactLayout {
            TabView {
                NavigationStack {
                    screen { TodayView(model: model, onDetail: showDetail) }
                        .navigationTitle("今日").toolbar { actions }
                }.tabItem { Label("今日", systemImage: "sun.max") }
                NavigationStack {
                    screen { ScheduleWorkspaceView(model: model, includesToday: false, onDetail: showDetail) }
                        .navigationTitle("日別予定").toolbar { actions }
                }.tabItem { Label("日別", systemImage: "calendar") }
                NavigationStack {
                    screen { tasks }
                        .navigationTitle("タスク").toolbar { actions }
                }.tabItem { Label("タスク", systemImage: "checklist") }
            }
        } else {
            NavigationSplitView {
                tasks.navigationTitle("タスク")
                    .navigationSplitViewColumnWidth(min: 320, ideal: 370, max: 460)
            } detail: {
                NavigationStack {
                    screen { ScheduleWorkspaceView(model: model, onDetail: showDetail) }
                        .navigationTitle("PersonalGantt").toolbar { actions }
                }
            }
        }
    }

    private func screen<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            IntegrationStatusView(model: model, onCalendars: { showsCalendarSelection = true },
                                  onReminders: { showsReminderSelection = true })
            Divider()
            content()
        }
    }

    private var tasks: some View {
        TaskListView(model: model, onDetail: showDetail, onEdit: { editor = TaskEditorRoute(task: $0) },
                     onDelete: { taskToDelete = $0 }, onReminders: { showsReminderSelection = true })
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItemGroup {
            Button("タスクを追加", systemImage: "plus") { editor = TaskEditorRoute(task: nil) }
                .disabled(model.isBackupRecoveryRequired)
                .accessibilityIdentifier("add-task")
            Button("再計算", systemImage: "arrow.clockwise") { model.recalculate() }
                .disabled(model.isBackupRecoveryRequired)
            Menu("再読み込み", systemImage: "arrow.triangle.2.circlepath") {
                Button("Google Calendarを再読み込み") { _Concurrency.Task { await model.refreshCalendars() } }
                    .disabled(model.isLoadingCalendars)
                if let reminders = model.reminders {
                    Button("Remindersを再読み込み") { _Concurrency.Task { await reminders.refresh() } }
                        .disabled(reminders.isLoading)
                }
            }
            Menu("バックアップ", systemImage: "externaldrive") {
                Button("バックアップを書き出す") {
                    do {
                        backupDocument = try BackupFileDocument(backup: model.makeBackup())
                        showsBackupExport = true
                    } catch { backupError = (error as? BackupError)?.localizedDescription ?? BackupError.unavailable.localizedDescription }
                }.disabled(!model.canUseBackup)
                Button("ファイルから読み込む") { showsBackupImport = true }.disabled(!model.canUseBackup)
            }.accessibilityIdentifier("backup-menu")
        }
    }

    private func showDetail(_ id: UUID) { detail = TaskDetailRoute(id: id) }
    private func isFileCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError
    }
}

private struct TaskEditorRoute: Identifiable {
    let id = UUID()
    let task: Task?
}
private struct TaskDetailRoute: Identifiable { let id: UUID }

#Preview { ContentView(model: ScheduleViewModel(tasks: [], availableSlots: [])) }
