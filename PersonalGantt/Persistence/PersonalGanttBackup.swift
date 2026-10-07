import Foundation

/// Portable user data only. OAuth tokens, Keychain contents and OS permissions are excluded.
nonisolated struct PersonalGanttBackup: Codable, Equatable, Sendable {
    var format = "PersonalGanttBackup"
    var version = 1
    var createdAt: Date
    var sourceDeviceID: UUID
    var plan: PlanSnapshot
    var reminders: ReminderLocalState

    func validate() throws {
        guard format == "PersonalGanttBackup", version == 1,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt >= .distantPast, createdAt <= .distantFuture else { throw BackupError.invalidFile }
        do { try plan.validate(); try reminders.validate() }
        catch { throw BackupError.invalidFile }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    static let maximumBytes = 50_000_000
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate()
            return value
        } catch let error as BackupError { throw error }
        catch { throw BackupError.invalidFile }
    }
}

nonisolated enum BackupError: LocalizedError, Equatable {
    case invalidFile, tooLarge, unavailable, busy, writeFailed, recoveryRequired
    var errorDescription: String? {
        switch self {
        case .invalidFile: "PersonalGanttの有効なバックアップファイルではありません。現在のデータは変更していません。"
        case .tooLarge: "バックアップは50MB以下のファイルを使用してください。"
        case .unavailable: "保存先を利用できません。バックアップの復元は行っていません。"
        case .busy: "連携の読み込み中です。完了してからバックアップを操作してください。"
        case .writeFailed: "復元に失敗したため、復元前のデータへ戻しました。"
        case .recoveryRequired: "復元が中断しました。追加の変更を止め、アプリを再起動してください。起動時に復元前のデータへ戻します。"
        }
    }
}

/// A rollback journal makes the JSON + SwiftData replacement recoverable across a crash.
@MainActor
protocol BackupJournalStoring {
    func load() throws -> PersonalGanttBackup?
    func save(_ backup: PersonalGanttBackup) throws
    func remove() throws
}

@MainActor
final class FileBackupJournal: BackupJournalStoring {
    let url: URL
    init(url: URL) { self.url = url }
    static func live() -> FileBackupJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileBackupJournal(url: base.appendingPathComponent("PersonalGantt/BackupRollback.json"))
    }
    func load() throws -> PersonalGanttBackup? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PersonalGanttBackup.decode(Data(contentsOf: url))
    }
    func save(_ backup: PersonalGanttBackup) throws {
        let data = try backup.encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func remove() throws { try FileManager.default.removeItem(at: url) }
}

@MainActor
enum BackupRestoration {
    static func recover(planStore: any PlanSnapshotStoring, reminderStore: any ReminderMetadataStoring,
                        journal: any BackupJournalStoring) throws {
        guard let previous = try journal.load() else { return }
        try previous.validate()
        try reminderStore.save(previous.reminders)
        try planStore.save(previous.plan)
        try journal.remove()
    }

    static func replace(with target: PersonalGanttBackup, previous: PersonalGanttBackup,
                        planStore: any PlanSnapshotStoring, reminderStore: any ReminderMetadataStoring,
                        journal: any BackupJournalStoring) throws {
        try target.validate(); try previous.validate()
        guard try journal.load() == nil else { throw BackupError.recoveryRequired }
        // Do not change either destination unless the old state is durably recoverable.
        do { try journal.save(previous) } catch { throw BackupError.unavailable }
        do {
            try reminderStore.save(target.reminders)
            try planStore.save(target.plan)
            try journal.remove()
        } catch {
            do { try recover(planStore: planStore, reminderStore: reminderStore, journal: journal) }
            catch { throw BackupError.recoveryRequired }
            throw BackupError.writeFailed
        }
    }
}
