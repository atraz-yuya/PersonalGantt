import SwiftUI

/// Shared form for global settings and a Task's unsaved draft.
struct AvailabilityExclusionList: View {
    let title: String
    let values: [AvailabilityExclusion]
    let onEdit: (AvailabilityExclusion) -> Void
    let onSave: ([AvailabilityExclusion]) throws -> Void
    @State private var error: String?
    var body: some View {
        Section(title) {
            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(value.weekdayDescription)　\(value.timeDescription)")
                    HStack {
                        Button("編集") { onEdit(value) }
                        Button("削除", role: .destructive) { commit(values.filter { $0.id != value.id }) }
                    }.buttonStyle(.borderless)
                }
            }
            Button("追加", systemImage: "plus") {
                onEdit(AvailabilityExclusion(startMinuteOfDay: 720, endMinuteOfDay: 780))
            }.accessibilityIdentifier("add-availability-exclusion")
            if values.isEmpty { Text("設定なし").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.orange) }
        }
    }
    private func commit(_ values: [AvailabilityExclusion]) {
        do { try onSave(values); error = nil } catch { self.error = error.localizedDescription }
    }
}

private enum ExclusionWeekdays: String, CaseIterable, Identifiable {
    case daily = "毎日", weekdays = "平日", selected = "曜日指定"
    var id: String { rawValue }
}
struct AvailabilityExclusionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: AvailabilityExclusion
    @State private var time: ActivityWindowDraft
    @State private var preset: ExclusionWeekdays
    @State private var error: String?
    let onSave: (AvailabilityExclusion) throws -> Void
    init(value: AvailabilityExclusion, onSave: @escaping (AvailabilityExclusion) throws -> Void) {
        _value = State(initialValue: value)
        _time = State(initialValue: ActivityWindowDraft(.init(startMinute: value.startMinuteOfDay, endMinute: value.endMinuteOfDay)))
        _preset = State(initialValue: value.weekdays == Set(1...7) ? .daily : value.weekdays == Set(2...6) ? .weekdays : .selected)
        self.onSave = onSave
    }
    var body: some View {
        Form {
            Section("配置しない曜日") {
                Picker("曜日", selection: $preset) {
                    ForEach(ExclusionWeekdays.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("exclusion-weekday-preset")
                if preset == .selected {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Toggle("\(AvailabilityExclusion.weekdayName(day))曜日", isOn: Binding(
                            get: { value.weekdays.contains(day) },
                            set: { if $0 { value.weekdays.insert(day) } else { value.weekdays.remove(day) } }))
                    }
                }
            }
            Section("配置しない時間") {
                ClockTimeTextField(title: "開始（例: 1800）", text: $time.start).accessibilityIdentifier("exclusion-start")
                ClockTimeTextField(title: "終了（例: 1900、24:00まで）", text: $time.end, allowsEndOfDay: true).accessibilityIdentifier("exclusion-end")
                Text("開始より後の終了時刻を指定してください。日をまたぐ禁止時間は、24:00までと翌日の0:00からに分けて設定します。")
                    .font(.caption).foregroundStyle(.secondary)
                if time.window == nil || value.weekdays.isEmpty { Text("有効な曜日と時間範囲を設定してください。").foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).navigationTitle("配置禁止時間")
            .onChange(of: preset) { _, next in
                if next == .daily { value.weekdays = Set(1...7) }
                if next == .weekdays { value.weekdays = Set(2...6) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let window = time.window else { return }
                        value.startMinuteOfDay = window.startMinute; value.endMinuteOfDay = window.endMinute
                        do { try onSave(value); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(time.window == nil || value.weekdays.isEmpty).accessibilityIdentifier("save-availability-exclusion")
                }
            }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
    }
}
