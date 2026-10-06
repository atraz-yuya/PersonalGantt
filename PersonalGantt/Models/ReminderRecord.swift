import Foundation

nonisolated struct ReminderList: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let accountTitle: String
    let allowsCompletionChanges: Bool
}

nonisolated struct ReminderRecord: Identifiable, Equatable, Sendable {
    let id: String
    let externalIdentifier: String?
    let listID: String
    let title: String
    let deadline: Date?
    let hasDateOnlyDeadline: Bool
    let hasInvalidDeadline: Bool
    let isCompleted: Bool
    let allowsCompletionChanges: Bool
    var isRecurring = false
    var occurrenceKey: String?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "タイトル未設定" : title
    }
}

nonisolated enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined, fullAccess, denied, restricted
    var description: String {
        switch self {
        case .notDetermined: "Apple Remindersへのアクセスを許可してください。"
        case .fullAccess: "Apple Remindersに接続しています。"
        case .denied: "Remindersへのアクセスが拒否されています。システム設定で許可してください。"
        case .restricted: "Remindersへのアクセスが制限されています。"
        }
    }
}
