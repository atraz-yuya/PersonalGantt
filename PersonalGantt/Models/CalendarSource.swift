import Foundation

nonisolated struct CalendarSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let accountTitle: String
}

nonisolated enum CalendarAuthorization: Equatable, Sendable {
    case notDetermined, fullAccess, writeOnly, denied, restricted

    var description: String {
        switch self {
        case .notDetermined: "カレンダーへのアクセスは未許可です。"
        case .fullAccess: "カレンダーを読み取れます。"
        case .writeOnly: "イベントの読み取りにはフルアクセスが必要です。"
        case .denied: "アクセスが拒否されています。OSの設定でカレンダーへのアクセスを許可してください。"
        case .restricted: "OSの制限によりカレンダーへアクセスできません。"
        }
    }
}
