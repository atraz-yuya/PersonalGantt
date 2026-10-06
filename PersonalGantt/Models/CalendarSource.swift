import Foundation

nonisolated struct CalendarSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let accountTitle: String
}

nonisolated enum CalendarAuthorization: Equatable, Sendable {
    case signedOut, connected, insufficientScope, denied, restricted

    var description: String {
        switch self {
        case .signedOut: "Google Calendarにログインしていません。"
        case .connected: "Google Calendarの読み取りに接続しています。"
        case .insufficientScope: "Google Calendarの読み取り権限が不足しています。"
        case .denied: "Google Calendarの読み取りが許可されていません。再ログインしてください。"
        case .restricted: "Google Calendarへのアクセスが制限されています。"
        }
    }
}
