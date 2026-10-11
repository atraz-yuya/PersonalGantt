import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(backup: PersonalGanttBackup) throws { data = try backup.encoded() }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.invalidFile }
        _ = try PersonalGanttBackup.decode(data)
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ScheduleViewModel
    let backup: PersonalGanttBackup
    let onRestore: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("読み込むファイル") {
                    LabeledContent("書き出し日時", value: backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Task", value: "\(backup.plan.tasks.count)件")
                    LabeledContent("ルーティン", value: "\(backup.plan.routines?.count ?? 0)件")
                    LabeledContent("日次上限", value: backup.plan.workloadSettings?.maxScheduledMinutesPerDay.map { "\($0)分" } ?? "上限なし")
                    LabeledContent("時間枠・履歴", value: "\(backup.plan.blocks.count)件")
                    LabeledContent("所要時間の設定", value: "\(backup.reminders.metadata.values.filter { $0.estimatedMinutes != nil }.count)件")
                }
                Section("読み込み後の動作") {
                    Text("手動Taskをファイルの状態へ戻し、Reminder設定と履歴を引き継ぎます。現在の内容を残したい場合は、先にバックアップを書き出してください。")
                    Text("開始済みの端末内の時間枠は保持します。未来の作業は連携先の最新予定に合わせて再計算します。")
                    Text("Googleへのログイン、使用Calendar、Remindersへの許可と使用リストは各端末で設定してください。")
                    Text("別の端末では、同じReminderを確認できた設定だけを引き継ぎます。対応が不明な設定は保留として残します。")
                    Text("Google CalendarやApple Remindersの内容を書き換える操作は行いません。")
                }
            }
            .navigationTitle("バックアップを確認")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("このファイルを読み込む", action: onRestore).disabled(!model.canUseBackup)
                        .accessibilityIdentifier("restore-backup")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}
