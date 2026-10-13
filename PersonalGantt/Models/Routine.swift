import Foundation
import CryptoKit

nonisolated enum RecurrenceRule: Codable, Equatable, Sendable {
    case daily
    case weekdays
    /// Foundation weekdays: Sunday = 1, Saturday = 7.
    case selectedWeekdays(Set<Int>)
    case weekly(weekday: Int)

    var isValid: Bool {
        switch self {
        case .daily, .weekdays: true
        case .selectedWeekdays(let days): !days.isEmpty && days.allSatisfy { (1...7).contains($0) }
        case .weekly(let day): (1...7).contains(day)
        }
    }

    func includes(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        switch self {
        case .daily: return true
        case .weekdays: return (2...6).contains(weekday)
        case .selectedWeekdays(let days): return days.contains(weekday)
        case .weekly(let day): return weekday == day
        }
    }
}

/// A per-occurrence requirement, separate from a one-off Task's total estimate.
nonisolated struct Routine: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var estimatedMinutesPerDay: Int
    var startDate: Date
    /// Inclusive local calendar date; occurrences end at the following midnight.
    var endDate: Date
    var recurrence: RecurrenceRule
    var completedOccurrenceIDs: Set<UUID> = []
    var skippedOccurrenceIDs: Set<UUID> = []
    var fixedStartMinuteOfDay: Int? = nil

    func validate() throws {
        _ = try TaskDraft(title: title, estimatedMinutesText: String(estimatedMinutesPerDay), deadline: endDate).validated()
        guard startDate.timeIntervalSinceReferenceDate.isFinite,
              startDate >= .distantPast, startDate <= .distantFuture,
              startDate <= endDate else { throw RoutineInputError.invalidDates }
        if let minute = fixedStartMinuteOfDay {
            guard (0..<1440).contains(minute), (1...1440).contains(estimatedMinutesPerDay) else { throw RoutineInputError.invalidFixedTime }
        }
        guard recurrence.isValid else { throw RoutineInputError.invalidWeekdays }
        guard completedOccurrenceIDs.isDisjoint(with: skippedOccurrenceIDs) else { throw RoutineInputError.invalidState }
    }
}

nonisolated struct RoutineOccurrence: Codable, Equatable, Sendable {
    let routineID: UUID
    let dayKey: String
    let dayStart: Date
    let dayEnd: Date
    var fixedStartMinuteOfDay: Int? = nil
    var fixedStart: Date? = nil

    /// Independent of launch, input ordering and time-zone offset for the same local date.
    var taskID: UUID {
        var bytes = Array(SHA256.hash(data: Data("\(routineID.uuidString)|\(dayKey)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated enum RoutineInputError: LocalizedError, Equatable {
    case invalidDates, invalidWeekdays, invalidState, editOccurrence, invalidFixedTime
    var errorDescription: String? {
        switch self {
        case .invalidDates: "開始日は終了日以前の有効な日付を選択してください。"
        case .invalidWeekdays: "繰り返す曜日を選択してください。"
        case .invalidState: "ルーティンの完了・スキップ状態を確認できません。"
        case .invalidFixedTime: "固定開始は0:00〜23:59、固定Routineの所要時間は1〜1440分で設定してください。"
        case .editOccurrence: "日ごとの作業要件は「作業量・ルーティン」で変更してください。"
        }
    }
}
