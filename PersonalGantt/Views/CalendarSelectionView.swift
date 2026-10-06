import SwiftUI

struct CalendarSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    @State private var selection: Set<String>
    @State private var clientID: String

    init(model: ScheduleViewModel) {
        self.model = model
        _selection = State(initialValue: model.selectedCalendarIDs)
        _clientID = State(initialValue: model.googleClientID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Google OAuth設定") {
                    TextField("iOSタイプのOAuthクライアントID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isLoadingCalendars || model.calendarAuthorization == .connected)
                    Button("クライアントIDを保存") { model.configureGoogleClientID(clientID) }
                        .disabled(model.isLoadingCalendars || model.calendarAuthorization == .connected)
                    Text("Google CloudでCalendar APIを有効にし、iOSタイプのOAuthクライアントを作成します。Bundle ID: com.atraz.PersonalGantt。Client SecretやTokenは入力しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Google CloudのOAuth設定", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
                }
                Section("Googleアカウント") {
                    Text(model.calendarAuthorization.description)
                    if model.calendarAuthorization != .connected {
                        Button("Googleにログイン") {
                            _Concurrency.Task { await model.requestCalendarAccess() }
                        }
                        .disabled(model.isLoadingCalendars || model.googleClientID.isEmpty)
                    } else {
                        Button("この端末からログアウト", role: .destructive) {
                            model.disconnectGoogle()
                            selection = []
                        }.disabled(model.isLoadingCalendars)
                    }
                    Text("Calendar一覧とイベントの読み取りだけを要求します。TokenはKeychainに保存します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.calendarAuthorization == .connected {
                    Section("使用するGoogle Calendar") {
                        if model.calendars.isEmpty { Text("読み取り可能なCalendarがありません。再読み込みしてください。") }
                        ForEach(model.calendars) { source in
                            Toggle(isOn: Binding(
                                get: { selection.contains(source.id) },
                                set: { selected in
                                    if selected { selection.insert(source.id) } else { selection.remove(source.id) }
                                }
                            )) { Text(source.title) }
                            .disabled(model.isLoadingCalendars)
                        }
                        Text("未選択なら活動可能時間だけを使います。取得成功後に選択を保存し、次回起動時に復元します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("一覧と固定予定を再読み込み") {
                        _Concurrency.Task { await model.refreshCalendars() }
                    }.disabled(model.isLoadingCalendars)
                    Button("Google接続を確認") {
                        _Concurrency.Task { await model.verifyCalendarConnection() }
                    }.disabled(model.isLoadingCalendars)
                }
                if model.isLoadingCalendars { ProgressView("Google Calendarを読み込み中…") }
                if let message = model.calendarMessage { Text(message).foregroundStyle(.orange) }
            }
            .navigationTitle("Google Calendarを選択")
            .onChange(of: model.calendars) { _, sources in
                selection.formIntersection(Set(sources.map(\.id)))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }.disabled(model.isLoadingCalendars)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("反映") {
                        _Concurrency.Task {
                            if await model.applyCalendarSelection(selection) { dismiss() }
                        }
                    }.disabled(model.calendarAuthorization != .connected || model.isLoadingCalendars)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 600)
        #endif
    }
}
