import Foundation

nonisolated struct PublishedEvent: Codable, Equatable, Sendable {
    var id: String
    var taskID: UUID
    var start: Date
    var end: Date
    var title: String
    var etag: String
}
nonisolated struct WritebackState: Codable, Equatable, Sendable {
    var enabled = false
    var publisherID = UUID()
    var calendarID: String?
    var events: [String: PublishedEvent] = [:]
    func validate() throws {
        guard calendarID != "primary", calendarID.map({ !$0.isEmpty }) ?? true,
              events.allSatisfy({ key, event in (5...1024).contains(key.count) && key.allSatisfy({ "0123456789abcdefghijklmnopqrstuv".contains($0) }) && key == event.id && event.start < event.end && event.start >= .distantPast && event.end <= .distantFuture })
        else { throw WritebackError.invalidDestination }
    }
}
nonisolated enum WritebackError: LocalizedError { case disabled, insufficientScope, invalidDestination, externalEdit, network
    var errorDescription: String? {
        switch self {
        case .disabled: "書き戻しはOFFです。"
        case .insufficientScope: "書き戻しにはGoogleの追加同意が必要です。通常の読み取り連携は継続できます。"
        case .invalidDestination: "PersonalGantt専用Calendarであることを確認できません。書き込みを停止しました。"
        case .externalEdit: "Google側で編集・削除された予定を検出しました。上書きせず書き戻しを停止しています。"
        case .network: "書き戻しに失敗しました。次の試行でも同じイベントIDを使い、二重作成を防ぎます。"
        }
    }
}
@MainActor protocol CalendarWritebackProviding {
    func authorize() async throws
    func publish(blocks: [ScheduledBlock], titles: [UUID: String], state: WritebackState, now: Date, calendar: Calendar) async throws -> WritebackState
}
