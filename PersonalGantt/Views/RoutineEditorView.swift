import SwiftUI

struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routine: Routine
    @State private var minutesText: String
    @State private var frequency: RoutineFrequency
    @State private var weekdays: Set<Int>
    @State private var weeklyDay: Int
    @State private var error: String?
    let calendar: Calendar
    let onSave: (Routine) throws -> Routine

    init(routine: Routine, calendar: Calendar, onSave: @escaping (Routine) throws -> Routine) {
        _routine = State(initialValue: routine)
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
                Section {
                    Text("選択した日ごとに必要時間を生成し、その日の空き時間へ配置します。配置できない分を翌日に持ち越しません。開始・終了時刻は自動で決まります。")
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
                            _ = try onSave(value)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-routine")
                }
            }
        }
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
