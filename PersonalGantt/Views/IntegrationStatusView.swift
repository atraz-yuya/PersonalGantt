import SwiftUI

struct IntegrationStatusView: View {
    @Bindable var model: ScheduleViewModel
    let onCalendars: () -> Void
    let onReminders: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(model.availabilityDescription, systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu("連携", systemImage: "link") {
                    Button("使用するカレンダーを選択", action: onCalendars)
                    if model.reminders != nil { Button("使用するRemindersを選択", action: onReminders) }
                }.accessibilityIdentifier("integration-menu")
            }
            if let reminders = model.reminders {
                HStack {
                    Text("Reminders: \(reminders.importedTasks.count)件のTask")
                    if !reminders.waitingRecords.isEmpty {
                        Button("入力待ち\(reminders.waitingRecords.count)件を設定", action: onReminders)
                            .accessibilityIdentifier("reminder-pending-settings")
                    }
                }.font(.caption)
                if reminders.isLoading { ProgressView("Remindersを読み込み中…") }
                if let message = reminders.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            if let message = model.calendarMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            if model.protectedConflictCount > 0 {
                Label("開始済みの作業と固定予定が重なっています。時間枠を保持しています。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.isLoadingCalendars { ProgressView("Google Calendarを読み込み中…") }
            DisclosureGroup("接続状況と保存") {
                VStack(alignment: .leading, spacing: 6) {
                    if let range = model.planningInterval {
                        Text("対象: \(range.start.formatted(date: .abbreviated, time: .omitted)) 〜 \(range.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                    }
                    if let date = model.lastCalendarRefresh {
                        Text("Google最終取得: \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let date = model.reminders?.lastRefresh {
                        Text("Reminders最終取得: \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text("連携TaskはRemindersから復元します。所要時間と選択はこの端末に保存します。手動Taskと計画履歴はアプリ終了時に消えます。")
                }.font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(.horizontal).padding(.vertical, 10)
    }
}
