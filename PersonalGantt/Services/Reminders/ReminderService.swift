import Foundation

@MainActor
protocol ReminderProviding {
    var authorization: ReminderAuthorization { get }
    func requestAccess() async throws -> ReminderAuthorization
    func loadLists() async throws -> [ReminderList]
    func loadReminders(listIDs: Set<String>) async throws -> [ReminderRecord]
    func setCompletion(identifier: String, listID: String, expected: Bool, completed: Bool) async throws -> ReminderRecord
}

nonisolated enum ReminderServiceError: LocalizedError, Equatable {
    case accessRequired, fetchFailed, listUnavailable, reminderUnavailable
    case readOnly, changedSinceRead, saveFailed, localStorage, invalidSnapshot, sourceOwnedFields
    var errorDescription: String? {
        switch self {
        case .accessRequired: "Apple Remindersへのアクセス許可が必要です。"
        case .fetchFailed: "Remindersを読み込めませんでした。再読み込みしてください。"
        case .listUnavailable: "選択したReminderリストが見つかりません。再読み込みしてください。"
        case .reminderUnavailable: "対象のReminderが見つかりません。再読み込みしてください。"
        case .readOnly: "このリストのReminderは変更できません。"
        case .changedSinceRead: "Reminderの完了状態が変更されています。再読み込みしてから操作してください。"
        case .saveFailed: "Remindersへの完了状態の保存に失敗しました。"
        case .localStorage: "所要時間・関連付け設定の保存先を読み書きできません。以前の設定を保持します。"
        case .invalidSnapshot: "Remindersの取得結果を確認できませんでした。以前のタスクを保持します。"
        case .sourceOwnedFields: "連携したタスクのタイトルと設定済みの締切は、Apple Remindersで変更してください。"
        }
    }
}
