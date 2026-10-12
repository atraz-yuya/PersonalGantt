import SwiftUI

struct AddView: View {
    @Bindable var model: ScheduleViewModel
    let onAddTask: () -> Void
    @State private var routine: Routine?
    var body: some View {
        List {
            Section("新しい作業") {
                Button(action: onAddTask) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("タスクを追加", systemImage: "plus.circle").font(.headline)
                        Text("タスク名・所要時間・締切を指定して追加します。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.accessibilityIdentifier("add-task")
                Button {
                    let start = model.presentationCalendar.startOfDay(for: model.schedulingReferenceDate)
                    let end = model.presentationCalendar.date(byAdding: .month, value: 1, to: start) ?? start
                    routine = Routine(title: "", estimatedMinutesPerDay: 60, startDate: start, endDate: end, recurrence: .daily)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("ルーティンを追加", systemImage: "repeat").font(.headline)
                        Text("毎日・平日・指定曜日など、繰り返す作業を追加します。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.accessibilityIdentifier("add-routine")
            }.disabled(model.isBackupRecoveryRequired)
            Section {
                Text("追加すると予定を再計算します。作成したタスク・ルーティンは設定の「作成した作業の管理」から削除できます。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.persistenceMessage { Text(message).foregroundStyle(.orange) }
            }
        }.navigationTitle("追加").accessibilityIdentifier("add-screen")
            .sheet(item: $routine) { value in
                RoutineEditorView(routine: value, calendar: model.presentationCalendar) { try model.saveRoutine($0) }
            }
    }
}

struct CreatedWorkSettingsView: View {
    @Bindable var model: ScheduleViewModel
    @State private var deletingTask: Task?
    @State private var deletingRoutine: Routine?
    private var localTasks: [Task] {
        model.tasks.filter { $0.routineOccurrence == nil && !model.isReminderTask($0.id) }
    }
    var body: some View {
        List {
            Section("作成したタスク") {
                if localTasks.isEmpty { Text("作成したタスクはありません。").foregroundStyle(.secondary) }
                ForEach(localTasks) { task in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(task.title)
                            Text("\(task.estimatedMinutes)分・\(task.deadline.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("削除", role: .destructive) { deletingTask = task }
                            .accessibilityLabel("\(task.title)を削除")
                    }
                }
            }
            Section("作成したルーティン") {
                if model.routines.isEmpty { Text("作成したルーティンはありません。").foregroundStyle(.secondary) }
                ForEach(model.routines) { routine in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(routine.title)
                            Text("\(routine.recurrence.displayName)・各日\(routine.estimatedMinutesPerDay)分")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("削除", role: .destructive) { deletingRoutine = routine }
                            .accessibilityLabel("\(routine.title)を削除")
                    }
                }
            }
            Text("削除すると予定を再計算します。開始済みの時間枠と作業実績は保持します。")
                .font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.borderless).disabled(model.isBackupRecoveryRequired)
            .navigationTitle("作成した作業の管理")
            .alert("タスクを削除しますか？", isPresented: Binding(get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }), presenting: deletingTask) { task in
                Button("削除", role: .destructive) { model.deleteTask(id: task.id); deletingTask = nil }
                Button("キャンセル", role: .cancel) { deletingTask = nil }
            } message: { Text("「\($0.title)」を削除します。") }
            .alert("ルーティンを削除しますか？", isPresented: Binding(get: { deletingRoutine != nil }, set: { if !$0 { deletingRoutine = nil } }), presenting: deletingRoutine) { routine in
                Button("削除", role: .destructive) { model.deleteRoutine(id: routine.id); deletingRoutine = nil }
                Button("キャンセル", role: .cancel) { deletingRoutine = nil }
            } message: { Text("「\($0.title)」と未開始の繰り返し予定を削除します。") }
    }
}
