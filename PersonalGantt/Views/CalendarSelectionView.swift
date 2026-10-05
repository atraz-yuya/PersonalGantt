import SwiftUI

struct CalendarSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    @State private var selection: Set<String>

    init(model: ScheduleViewModel) {
        self.model = model
        _selection = State(initialValue: model.selectedCalendarIDs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("アクセス権限") {
                    Text(model.calendarAuthorization.description)
                    if model.calendarAuthorization == .notDetermined || model.calendarAuthorization == .writeOnly {
                        Button("カレンダーへのアクセスを許可") {
                            _Concurrency.Task { await model.requestCalendarAccess() }
                        }
                        .disabled(model.isLoadingCalendars)
                    }
                    Text("固定予定を読み取ります。Calendarのイベントは変更しません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.calendarAuthorization == .fullAccess {
                    Section("使用するカレンダー") {
                        if model.calendars.isEmpty {
                            Text("カレンダーがありません。標準Calendarのアカウント設定を確認してください。")
                        }
                        ForEach(model.calendars) { source in
                            Toggle(isOn: Binding(
                                get: { selection.contains(source.id) },
                                set: { selected in
                                    if selected { selection.insert(source.id) } else { selection.remove(source.id) }
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(source.title)
                                    Text(source.accountTitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.isLoadingCalendars)
                        }
                        Text("未選択の場合、活動可能時間だけを使います。選択はアプリ終了時に消えます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("一覧と固定予定を再読み込み") { model.refreshCalendars() }
                        .disabled(model.isLoadingCalendars)
                }
                if model.isLoadingCalendars { ProgressView("読み込み中…") }
                if let message = model.calendarMessage { Text(message).foregroundStyle(.orange) }
            }
            .navigationTitle("カレンダーを選択")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.disabled(model.isLoadingCalendars)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("反映") {
                        if model.applyCalendarSelection(selection) { dismiss() }
                    }
                    .disabled(model.calendarAuthorization != .fullAccess || model.isLoadingCalendars)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420)
        #endif
    }
}
