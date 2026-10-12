import SwiftUI

struct ActivitySettingsView: View {
    @Bindable var model: ScheduleViewModel
    @State private var normal: ActivityWindowDraft
    @State private var weekend: ActivityWindowDraft
    @State private var selectedDay: Date
    @State private var message: String?
    init(model: ScheduleViewModel) {
        self.model = model
        _normal = State(initialValue: ActivityWindowDraft(model.activitySettings.weekday))
        _weekend = State(initialValue: ActivityWindowDraft(model.activitySettings.weekend))
        _selectedDay = State(initialValue: model.schedulingReferenceDate)
    }
    var body: some View {
        Form {
            Section("通常の稼働時間（平日）") { ActivityTimeFields(draft: $normal) }
            Section("通常の稼働時間（土・日）") { ActivityTimeFields(draft: $weekend) }
            Section {
                Button("通常の時間を保存して再計算") {
                    guard let weekday = normal.window, let weekend = weekend.window else { return }
                    var settings = model.activitySettings
                    settings.weekday = weekday; settings.weekend = weekend
                    do { try model.setActivitySettings(settings); message = "通常の稼働時間を保存し、再計算しました。" }
                    catch { message = error.localizedDescription }
                }.disabled(normal.window == nil || weekend.window == nil || model.isBackupRecoveryRequired)
                    .accessibilityIdentifier("save-normal-activity")
                Text("初期設定は毎日10:00〜24:00です。24:00はその日の終わり（翌日の0:00）です。日付ごとの変更を優先します。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption) }
            }
            Section("日付ごとの稼働時間") {
                DatePicker("日付", selection: $selectedDay, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                NavigationLink("この日の稼働時間を変更") {
                    DayActivityView(model: model, day: selectedDay)
                }.accessibilityIdentifier("edit-day-activity")
                ForEach(model.activitySettings.dayOverrides.keys.sorted(), id: \.self) { key in
                    if let day = ActivitySettings.date(for: key, calendar: model.presentationCalendar), let value = model.activitySettings.dayOverrides[key] {
                        NavigationLink {
                            DayActivityView(model: model, day: day)
                        } label: {
                            HStack { Text(key); Spacer(); Text(value.window?.displayName ?? "稼働なし").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("稼働時間")
            .environment(\.calendar, model.presentationCalendar).environment(\.timeZone, model.presentationCalendar.timeZone)
    }
}

struct DayActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    let day: Date
    @State private var draft: ActivityWindowDraft
    @State private var isOff: Bool
    @State private var error: String?
    init(model: ScheduleViewModel, day: Date) {
        self.model = model; self.day = day
        let window = model.activitySettings.window(on: day, calendar: model.presentationCalendar)
        _draft = State(initialValue: ActivityWindowDraft(window ?? model.activitySettings.weekday))
        _isOff = State(initialValue: window == nil)
    }
    private var hasOverride: Bool {
        model.activitySettings.dayOverrides[ActivitySettings.dayKey(day, calendar: model.presentationCalendar)] != nil
    }
    var body: some View {
        Form {
            Section(day.formatted(date: .complete, time: .omitted)) {
                Toggle("稼働しない日", isOn: $isOff).accessibilityIdentifier("day-activity-off")
                if !isOff { ActivityTimeFields(draft: $draft) }
                Text("この日だけに適用します。保存すると、取得済みの固定予定と新しい稼働時間で直ちに再計算します。開始済みの時間枠は保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("保存して再計算") {
                    guard isOff || draft.window != nil else { return }
                    save { try model.setActivityWindow(isOff ? nil : draft.window, on: day) }
                }.disabled((!isOff && draft.window == nil) || model.isBackupRecoveryRequired)
                    .accessibilityIdentifier("save-day-activity")
                if hasOverride {
                    Button("この日の変更を解除して通常に戻す") { save { try model.clearActivityOverride(on: day) } }
                        .disabled(model.isBackupRecoveryRequired).accessibilityIdentifier("reset-day-activity")
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).navigationTitle("この日の稼働時間")
            .environment(\.calendar, model.presentationCalendar).environment(\.timeZone, model.presentationCalendar.timeZone)
    }
    private func save(_ action: () throws -> Void) {
        do { try action(); dismiss() } catch { self.error = error.localizedDescription }
    }
}

private struct ActivityTimeFields: View {
    @Binding var draft: ActivityWindowDraft
    var body: some View {
        TextField("開始（HH:mm）", text: $draft.start).accessibilityIdentifier("activity-start")
        TextField("終了（HH:mm、24:00まで）", text: $draft.end).accessibilityIdentifier("activity-end")
        if draft.window == nil {
            Text("10:00、24:00のように入力し、開始より後の終了時刻を指定してください。")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
