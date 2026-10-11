import SwiftUI

struct WorkloadRoutineView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    @State private var limitEnabled: Bool
    @State private var limitText: String
    @State private var message: String?
    @State private var editor: RoutineEditorRoute?
    @State private var deleting: Routine?

    init(model: ScheduleViewModel) {
        self.model = model
        _limitEnabled = State(initialValue: model.workloadSettings.maxScheduledMinutesPerDay != nil)
        _limitText = State(initialValue: String(model.workloadSettings.maxScheduledMinutesPerDay ?? 300))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("計画対象期間") {
                    Text(model.planningPeriodDescription)
                    Text("タスクの締切・ルーティンの終了日に応じて、最低14日・最長90暦日まで自動で延長します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = model.horizonCapMessage { Text(message).foregroundStyle(.orange) }
                    if let message = model.coverageMessage { Text(message).foregroundStyle(.orange) }
                }
                Section("1日の自動配置上限") {
                    Toggle("日次上限を使う", isOn: $limitEnabled).accessibilityIdentifier("workload-limit-enabled")
                    if limitEnabled {
                        TextField("上限（分）", text: $limitText)
                            .accessibilityIdentifier("workload-limit-minutes")
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                    Button("日次上限を保存") {
                        do {
                            if limitEnabled {
                                guard let minutes = Int(limitText.trimmingCharacters(in: .whitespacesAndNewlines)), minutes > 0
                                else { throw WorkloadInputError.invalidLimit }
                                try model.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: minutes))
                            } else { try model.setWorkloadSettings(.unlimited) }
                            message = model.persistenceMessage ?? "日次上限を反映しました。"
                        } catch { message = error.localizedDescription }
                    }.disabled(model.isBackupRecoveryRequired).accessibilityIdentifier("save-workload-limit")
                    Text("通常タスクとルーティンの合計が対象です。Googleの固定予定は含めません。上限を超えて締切を優先する配置は行いません。開始済みの時間枠は保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if model.workloadLimitExceededDays > 0 {
                        Label("開始済みの時間枠が上限を超える日は、新しい作業を追加配置しません。", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("ルーティン") {
                    if model.routines.isEmpty { Text("ルーティンはありません。") .foregroundStyle(.secondary) }
                    ForEach(model.routines) { routine in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(routine.title).font(.headline)
                            Text("\(routine.recurrence.displayName)・各日\(routine.estimatedMinutesPerDay)分")
                            Text("\(routine.startDate.formatted(date: .abbreviated, time: .omitted)) 〜 \(routine.endDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("編集") { editor = RoutineEditorRoute(routine: routine) }
                                if !routine.skippedOccurrenceIDs.isEmpty {
                                    Button("スキップを解除") { model.resetRoutineSkippedDays(id: routine.id) }
                                }
                                Spacer()
                                Button("削除", role: .destructive) { deleting = routine }
                            }.buttonStyle(.borderless).disabled(model.isBackupRecoveryRequired)
                        }.padding(.vertical, 4)
                    }
                    Button("ルーティンを追加", systemImage: "plus") {
                        let start = model.presentationCalendar.startOfDay(for: Date())
                        let end = model.presentationCalendar.date(byAdding: .month, value: 1, to: start) ?? start
                        editor = RoutineEditorRoute(routine: Routine(title: "", estimatedMinutesPerDay: 60,
                                                                    startDate: start, endDate: end, recurrence: .daily))
                    }.disabled(model.isBackupRecoveryRequired).accessibilityIdentifier("add-routine")
                    Text("計画対象期間内の各日の作業要件を自動生成します。完了・スキップはその日だけに適用します。終了日を含め、最長90暦日まで計画します。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("日ごとの配置時間") {
                    let totals = model.dailyScheduledMinutes
                    ForEach(model.displayDays(referenceDate: Date())) { day in
                        let minutes = totals[day.interval.start] ?? 0
                        LabeledContent(day.interval.start.formatted(date: .abbreviated, time: .omitted)) {
                            if let limit = model.workloadSettings.maxScheduledMinutesPerDay {
                                Text("\(minutes.formatted()) / \(limit)分")
                                    .foregroundStyle(minutes > Double(limit) ? .orange : .secondary)
                            } else { Text("\(minutes.formatted())分") }
                        }
                    }
                    Text("配置時間の集計です。実際の作業実績ではありません。対象期間より先の作業は、日付が進むと計画されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("作業量・ルーティン")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(item: $editor) { route in
                RoutineEditorView(routine: route.routine, calendar: model.presentationCalendar) { try model.saveRoutine($0) }
            }
            .alert("ルーティンを削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("削除", role: .destructive) {
                    if let deleting { model.deleteRoutine(id: deleting.id) }
                    deleting = nil
                }
                Button("キャンセル", role: .cancel) { deleting = nil }
            } message: { Text("今後の日ごとの作業要件を削除します。開始済みの時間枠は保持します。") }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 600, minHeight: 580)
        #endif
    }
}

private struct RoutineEditorRoute: Identifiable {
    let routine: Routine
    var id: UUID { routine.id }
}

extension RecurrenceRule {
    var displayName: String {
        let symbols = ["日", "月", "火", "水", "木", "金", "土"]
        switch self {
        case .daily: return "毎日"
        case .weekdays: return "平日（月〜金）"
        case .selectedWeekdays(let days): return days.sorted().filter { (1...7).contains($0) }.map { symbols[$0 - 1] }.joined(separator: "・")
        case .weekly(let day): return (1...7).contains(day) ? "毎週\(symbols[day - 1])曜日" : "曜日未設定"
        }
    }
}
