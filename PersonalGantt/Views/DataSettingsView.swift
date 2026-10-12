import SwiftUI
import UniformTypeIdentifiers

struct DataSettingsView: View {
    @Bindable var model: ScheduleViewModel
    @State private var showsExport = false
    @State private var showsImport = false
    @State private var document: BackupFileDocument?
    @State private var importedBackup: PersonalGanttBackup?
    @State private var errorMessage: String?
    var body: some View {
        List {
            Section("バックアップ") {
                Button("バックアップを書き出す", systemImage: "square.and.arrow.up") {
                    do { document = try BackupFileDocument(backup: model.makeBackup()); showsExport = true }
                    catch { errorMessage = (error as? BackupError)?.localizedDescription ?? BackupError.unavailable.localizedDescription }
                }.disabled(!model.canUseBackup).accessibilityIdentifier("export-backup")
                Button("バックアップを読み込む", systemImage: "square.and.arrow.down") { showsImport = true }
                    .disabled(!model.canUseBackup).accessibilityIdentifier("import-backup")
                Text("Task・設定・実績をJSONファイルで受け渡せます。Google Tokenは含めません。Task名や予定を含むファイルは、ご自身で管理してください。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.backupMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let count = model.reminders?.pendingTransferCount, count > 0 {
                    Text("Reminder設定\(count)件が対応確認待ちです。使用リストを選び、Remindersを更新してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("端末内の保存") {
                if let date = model.lastPlanSave {
                    LabeledContent("最終保存", value: date.formatted(date: .abbreviated, time: .shortened))
                } else { Text("保存日時はまだありません。") .foregroundStyle(.secondary) }
                if let message = model.persistenceMessage {
                    Text(message).foregroundStyle(.orange)
                    if !model.isPlanStorageBlocked {
                        Button("保存を再試行") { model.retryPlanSave() }.accessibilityIdentifier("retry-plan-save")
                    }
                }
                Text("計画と開始済みの時間枠をこの端末に保存します。予定枠と実績は別々に保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("同期状態") {
                LabeledContent("iCloud同期", value: model.syncState.isEnabled ? "ON" : "OFF")
                if let date = model.syncState.lastSync {
                    LabeledContent("最終同期", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let message = model.syncMessage { Text(message).font(.caption) }
                Text("同期の有効化と競合履歴は、設定の「端末間の同期」で確認できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("バックアップと保存").accessibilityIdentifier("data-settings")
        .fileExporter(isPresented: $showsExport, document: document, contentType: .json,
            defaultFilename: "PersonalGantt-Backup-" + Date().formatted(.iso8601.year().month().day())) { outcome in
            if case .failure(let error) = outcome, !isCancellation(error) { errorMessage = "ファイルを書き出せませんでした。保存先を確認してください。" }
        }
        .fileImporter(isPresented: $showsImport, allowedContentTypes: [.json]) { outcome in
            do {
                let url = try outcome.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= PersonalGanttBackup.maximumBytes else { throw BackupError.tooLarge }
                importedBackup = try PersonalGanttBackup.decode(Data(contentsOf: url))
            } catch {
                if !isCancellation(error) { errorMessage = (error as? BackupError)?.localizedDescription ?? "ファイルを読み込めませんでした。現在のデータは変更していません。" }
            }
        }
        .sheet(isPresented: Binding(get: { importedBackup != nil }, set: { if !$0 { importedBackup = nil } })) {
            if let importedBackup {
                BackupPreviewView(model: model, backup: importedBackup) {
                    do {
                        try model.restoreBackup(importedBackup)
                        self.importedBackup = nil
                        _Concurrency.Task { await model.reminders?.loadState(); await model.refreshCalendars() }
                    } catch {
                        self.importedBackup = nil
                        errorMessage = (error as? BackupError)?.localizedDescription ?? BackupError.unavailable.localizedDescription
                    }
                }
            }
        }
        .alert("バックアップ", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("閉じる") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func isCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError
    }
}
