import Foundation

/// Local civil-time restrictions. Sunday = 1; an exclusive end of 1440 is next midnight.
nonisolated struct AvailabilityExclusion: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var weekdays: Set<Int> = Set(1...7)
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int
    var isValid: Bool {
        !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) } &&
        ActivityWindow(startMinute: startMinuteOfDay, endMinute: endMinuteOfDay).isValid
    }
    static func valid(_ values: [Self]) -> Bool {
        values.count <= 1000 && Set(values.map(\.id)).count == values.count && values.allSatisfy(\.isValid)
    }
    var weekdayDescription: String {
        if weekdays == Set(1...7) { return "毎日" }
        if weekdays == Set(2...6) { return "平日" }
        return [2, 3, 4, 5, 6, 7, 1].filter { weekdays.contains($0) }.map { Self.weekdayName($0) }.joined(separator: "・")
    }
    static func weekdayName(_ value: Int) -> String { ["日", "月", "火", "水", "木", "金", "土"][value - 1] }
    var timeDescription: String { ActivityWindow(startMinute: startMinuteOfDay, endMinute: endMinuteOfDay).displayName }
}
typealias TaskAvailabilityExclusion = AvailabilityExclusion
typealias GlobalAvailabilityExclusion = AvailabilityExclusion

nonisolated enum LocalSchedulingTime {
    static func date(_ minute: Int, on day: Date, calendar: Calendar, strict: Bool = false) -> Date? {
        guard (0...1440).contains(minute), let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        if minute == 1440 { return next }
        guard let result = calendar.nextDate(after: day.addingTimeInterval(-1),
            matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
            matchingPolicy: strict ? .strict : .nextTime, repeatedTimePolicy: .first, direction: .forward),
              result >= day, result < next else { return nil }
        return result
    }
}

nonisolated enum AvailabilityExclusionSlots {
    static func intervals(_ values: [AvailabilityExclusion], in range: DateInterval, calendar: Calendar) -> [DateInterval] {
        guard range.start < range.end else { return [] }
        var result: [DateInterval] = [], day = calendar.startOfDay(for: range.start)
        while day < range.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            let daily = values.filter { $0.isValid && $0.weekdays.contains(calendar.component(.weekday, from: day)) }
            if !daily.isEmpty && abs(next.timeIntervalSince(day) - 86400) > 0.001 {
                // A repeated civil hour must be excluded on both passes. Walking only
                // transition days also avoids excluding permitted minutes after a rollback.
                var cursor = day, opened: Date?
                while cursor < next {
                    let minute = calendar.component(.hour, from: cursor) * 60 + calendar.component(.minute, from: cursor)
                    let excluded = daily.contains { $0.startMinuteOfDay <= minute && minute < $0.endMinuteOfDay }
                    if excluded && opened == nil { opened = cursor }
                    if !excluded, let start = opened {
                        let lower = max(start, range.start), upper = min(cursor, range.end)
                        if lower < upper { result.append(DateInterval(start: lower, end: upper)) }; opened = nil
                    }
                    cursor = min(next, cursor.addingTimeInterval(60))
                }
                if let start = opened {
                    let lower = max(start, range.start), upper = min(next, range.end)
                    if lower < upper { result.append(DateInterval(start: lower, end: upper)) }
                }
                day = next; continue
            }
            for value in daily {
                guard let start = LocalSchedulingTime.date(value.startMinuteOfDay, on: day, calendar: calendar),
                      let end = LocalSchedulingTime.date(value.endMinuteOfDay, on: day, calendar: calendar), start < end else { continue }
                let lower = max(start, range.start), upper = min(end, range.end)
                if lower < upper { result.append(DateInterval(start: lower, end: upper)) }
            }
            day = next
        }
        return result
    }
    static func subtract(_ values: [AvailabilityExclusion], from slots: [AvailableSlot], calendar: Calendar) -> [AvailableSlot] {
        guard !values.isEmpty, let start = slots.map(\.start).min(), let end = slots.map(\.end).max(), start < end else { return slots }
        return IntervalSubtraction.subtract(intervals(values, in: DateInterval(start: start, end: end), calendar: calendar), from: slots)
    }
}
