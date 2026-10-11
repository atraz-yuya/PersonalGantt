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
            if let limit = model.workloadSettings.maxScheduledMinutesPerDay {
                Label("自動配置の上限: 1日\(limit)分", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.workloadLimitExceededDays > 0 {
                Text("開始済みの時間枠が日次上限を超えています。保持し、同じ日の追加配置を止めています。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let message = model.backupMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let count = model.reminders?.pendingTransferCount, count > 0 {
                Text("受け渡したReminder設定\(count)件が対応確認待ちです。使用リストを選んで再読み込みしてください。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let message = model.persistenceMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                if !model.isPlanStorageBlocked {
                    Button("保存を再試行") { model.retryPlanSave() }
                }
            }
            if model.tasks.contains(where: { model.isReminderTask($0.id) && model.taskIsBusy($0.id) }) {
                Text("保存済みのReminders Taskを表示しています。編集・完了操作にはRemindersの再読み込みが必要です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    if let date = model.lastPlanSave {
                        Text("端末内の最終保存: \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text("手動Task・計画・開始済みの時間枠をこの端末に保存します。履歴は自動削除しません。バックアップファイルをMac・iPhone・iPad間で手動で受け渡せます。自動同期は行いません。ファイルにはTask名や予定を含むので、ご自身で管理してください。")
                }.font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(.horizontal).padding(.vertical, 10)
    }
}
