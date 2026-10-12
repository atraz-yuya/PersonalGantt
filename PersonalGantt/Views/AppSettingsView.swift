import SwiftUI

struct AppSettingsView: View {
    @Bindable var model: ScheduleViewModel
    var body: some View {
        List {
            Section("連携") {
                NavigationLink {
                    CalendarSelectionView(model: model, embedded: true)
                } label: {
                    settingsRow("Google Calendar", symbol: "calendar", status: model.calendarAuthorization == .connected ? "接続済み" : "未接続")
                }.accessibilityIdentifier("settings-google")
                if let reminders = model.reminders {
                    NavigationLink {
                        ReminderSelectionView(model: reminders, embedded: true)
                    } label: {
                        settingsRow("Reminders", symbol: "checklist", status: "\(reminders.selectedListIDs.count)リスト")
                    }.accessibilityIdentifier("settings-reminders")
                    if let date = reminders.lastRefresh {
                        LabeledContent("Reminders最終更新", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                NavigationLink {
                    WorkloadRoutineView(model: model, page: .sync, embedded: true)
                } label: {
                    settingsRow("端末間の同期", symbol: "icloud", status: model.syncState.isEnabled ? "ON" : "OFF")
                }.accessibilityIdentifier("settings-sync")
            }
            Section("カレンダー") {
                Text(model.availabilityDescription).font(.subheadline).foregroundStyle(.secondary)
                if let date = model.lastCalendarRefresh {
                    LabeledContent("最終更新", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("カレンダーを更新", systemImage: "arrow.triangle.2.circlepath") {
                    _Concurrency.Task { await model.refreshCalendars() }
                }.disabled(model.isLoadingCalendars || model.isBackupRecoveryRequired)
                    .accessibilityIdentifier("settings-refresh-calendar")
                if model.isLoadingCalendars { ProgressView("カレンダーを更新中…") }
                if let message = model.calendarMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                NavigationLink {
                    WorkloadRoutineView(model: model, page: .writeback, embedded: true)
                } label: {
                    settingsRow("専用Calendarへの書き戻し", symbol: "calendar.badge.plus", status: model.writebackState.enabled ? "ON" : "OFF")
                }.accessibilityIdentifier("settings-writeback")
                Text("Googleの変更は再取得後に反映します。バックグラウンド更新の実行時刻はOSが決めます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("タスク・計画") {
                NavigationLink {
                    WorkloadRoutineView(model: model, page: .planning, embedded: true)
                } label: { Label("作業量・ルーティン・配置", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("workload-routine-settings")
                LabeledContent("配置モード", value: model.schedulingSettings.distributionMode.displayName)
                Text("計画期間: " + model.planningPeriodDescription).font(.caption).foregroundStyle(.secondary)
                if let date = model.lastRecalculation {
                    LabeledContent("再計算", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("データ") {
                NavigationLink { DataSettingsView(model: model) } label: { Label("バックアップと保存", systemImage: "externaldrive") }
                    .accessibilityIdentifier("settings-data")
            }
            Section("Siri・ショートカット") {
                NavigationLink { SiriSettingsGuide() } label: { Label("Siriでタスクを追加", systemImage: "mic") }
                    .accessibilityIdentifier("settings-siri")
            }
        }.navigationTitle("設定").accessibilityIdentifier("app-settings")
    }
    private func settingsRow(_ title: String, symbol: String, status: String) -> some View {
        HStack { Label(title, systemImage: symbol); Spacer(); Text(status).font(.subheadline).foregroundStyle(.secondary) }
    }
}

private struct SiriSettingsGuide: View {
    var body: some View {
        List {
            Section("話しかける例") {
                Text("Siri、PersonalGanttにタスクを追加")
                Text("PersonalGanttでタスクを追加")
                Text("PersonalGanttに新しいタスクを追加")
            }
            Section("入力する項目") {
                Text("タスク名、所要時間（分）、締切の日時を指定します。")
                Text("ショートカットアプリのPersonalGantt「タスクを追加」からも利用できます。")
                Text("追加したタスクは端末内に保存し、現在の予定に合わせて配置します。")
            }
        }.navigationTitle("Siri・ショートカット")
    }
}
