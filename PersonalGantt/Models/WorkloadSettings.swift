import Foundation

/// Applies to automatically scheduled work, never to fixed Calendar events.
nonisolated struct WorkloadSettings: Codable, Equatable, Sendable {
    var maxScheduledMinutesPerDay: Int?
    static let unlimited = WorkloadSettings(maxScheduledMinutesPerDay: nil)

    func validate() throws {
        if let limit = maxScheduledMinutesPerDay, limit <= 0 { throw WorkloadInputError.invalidLimit }
    }
}

nonisolated enum WorkloadInputError: LocalizedError, Equatable {
    case invalidLimit
    var errorDescription: String? { "日次上限は1分以上の整数で入力してください。" }
}
