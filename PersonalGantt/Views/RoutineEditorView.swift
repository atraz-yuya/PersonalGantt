import SwiftUI

struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routine: Routine
    @State private var minutesText: String
    @State private var frequency: RoutineFrequency
    @State private var weekdays: Set<Int>
    @State private var weeklyDay: Int
    @State private var fixedTime: String
    @State private var fixedEnabled: Bool
    @State private var error: String?
    let calendar: Calendar
    let onSave: (Routine) throws -> Routine

    init(routine: Routine, calendar: Calendar, onSave: @escaping (Routine) throws -> Routine) {
        _routine = State(initialValue: routine)
        _fixedEnabled = State(initialValue: routine.fixedStartMinuteOfDay != nil)
        _fixedTime = State(initialValue: ActivityWindow.time(routine.fixedStartMinuteOfDay ?? 1140))
        _minutesText = State(initialValue: String(routine.estimatedMinutesPerDay))
        switch routine.recurrence {
        case .daily:
            _frequency = State(initialValue: .daily); _weekdays = State(initialValue: [2, 3, 4, 5, 6]); _weeklyDay = State(initialValue: 2)
        case .weekdays:
            _frequency = State(initialValue: .weekdays); _weekdays = State(initialValue: [2, 3, 4, 5, 6]); _weeklyDay = State(initialValue: 2)
        case .selectedWeekdays(let days):
            _frequency = State(initialValue: .selected); _weekdays = State(initialValue: days); _weeklyDay = State(initialValue: 2)
        case .weekly(let day):
            _frequency = State(initialValue: .weekly); _weekdays = State(initialValue: [day]); _weeklyDay = State(initialValue: day)
        }
        self.calendar = calendar
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("各日の作業内容") {
                    TextField("ルーティン名", text: $routine.title).accessibilityIdentifier("routine-title")
                    TextField("1回の所要時間（分）", text: $minutesText).accessibilityIdentifier("routine-minutes")
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Picker("繰り返し", selection: $frequency) {
                        ForEach(RoutineFrequency.allCases) { Text($0.rawValue).tag($0) }
                    }.accessibilityIdentifier("routine-frequency")
                    if frequency == .selected {
                        ForEach(1...7, id: \.self) { day in
                            Toggle("\(weekdayName(day))曜日", isOn: Binding(
                                get: { weekdays.contains(day) },
                                set: { enabled in if enabled { weekdays.insert(day) } else { weekdays.remove(day) } }
                            ))
                        }
                    }
                    if frequency == .weekly {
                        Picker("曜日", selection: $weeklyDay) {
                            ForEach(1...7, id: \.self) { Text("\(weekdayName($0))曜日").tag($0) }
                        }
                    }
                    DatePicker("開始日", selection: $routine.startDate, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                    DatePicker("終了日（この日を含む）", selection: $routine.endDate, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                }
                Section("実行する時間") {
                    Toggle("固定時間で実行", isOn: $fixedEnabled).accessibilityIdentifier("routine-fixed-enabled")
                    if fixedEnabled {
                        ClockTimeTextField(title: "開始時刻（例: 1900）", text: $fixedTime).accessibilityIdentifier("routine-fixed-start")
                        if let start = ClockTime.minute(fixedTime), let minutes = Int(minutesText), (1...1440).contains(minutes) {
                            Text("予定: \(ActivityWindow.time(start))〜\(ActivityWindow.time((start + minutes) % 1440))" +
                                (start + minutes >= 1440 ? "（翌日）" : ""))
                        } else if ClockTime.minute(fixedTime) == nil {
                            Text("開始時刻を4桁（例: 1900）または19:00で入力してください。").foregroundStyle(.orange)
                        }
                        Text("予定・共通禁止時間・別の固定Routineと重なっても移動せず、競合を表示します。固定枠も日次上限に算入します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("選択した日ごとに必要時間を生成し、その日の空き時間へ配置します。配置できない分を翌日に持ち越しません。固定時間がOFFの場合は開始・終了時刻が自動で決まります。")
                        .foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }.font(.caption)
            }
            .formStyle(.grouped)
            .navigationTitle("ルーティンを設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard let minutes = Int(minutesText.trimmingCharacters(in: .whitespacesAndNewlines)), minutes > 0 else { throw TaskInputError.invalidMinutes }
                            var value = routine
                            value.estimatedMinutesPerDay = minutes
                            value.startDate = calendar.startOfDay(for: value.startDate)
                            value.endDate = calendar.startOfDay(for: value.endDate)
                            value.recurrence = recurrence
                            guard !fixedEnabled || ClockTime.minute(fixedTime) != nil else { throw RoutineInputError.invalidFixedTime }
                            value.fixedStartMinuteOfDay = fixedEnabled ? ClockTime.minute(fixedTime) : nil
                            _ = try onSave(value)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(fixedEnabled && ClockTime.minute(fixedTime) == nil)
                        .accessibilityIdentifier("save-routine")
                }
            }
        }
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        #if os(macOS)
        .frame(minWidth: 450, idealWidth: 500, minHeight: 500)
        #endif
    }

    private var recurrence: RecurrenceRule {
        switch frequency {
        case .daily: .daily
        case .weekdays: .weekdays
        case .selected: .selectedWeekdays(weekdays)
        case .weekly: .weekly(weekday: weeklyDay)
        }
    }
    private func weekdayName(_ day: Int) -> String { ["日", "月", "火", "水", "木", "金", "土"][day - 1] }
}

private enum RoutineFrequency: String, CaseIterable, Identifiable {
    case daily = "毎日", weekdays = "平日（月〜金）", selected = "曜日指定", weekly = "毎週"
    var id: String { rawValue }
}
