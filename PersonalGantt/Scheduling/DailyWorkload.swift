import Foundation

/// Real elapsed seconds in each local calendar day, including 23/25-hour DST days.
nonisolated enum DailyWorkload {
    static func secondsByDay(blocks: [ScheduledBlock], calendar: Calendar) -> [Date: TimeInterval] {
        var totals: [Date: TimeInterval] = [:]
        for block in blocks {
            for part in dayParts(start: block.start, end: block.end, calendar: calendar) {
                totals[calendar.startOfDay(for: part.start), default: 0] += part.duration
            }
        }
        return totals
    }

    static func dayParts(start: Date, end: Date, calendar: Calendar) -> [DateInterval] {
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start < end else { return [] }
        var parts: [DateInterval] = []
        var cursor = start
        while cursor < end, let day = calendar.dateInterval(of: .day, for: cursor) {
            let upper = min(end, day.end)
            guard upper > cursor else { break }
            parts.append(DateInterval(start: cursor, end: upper))
            cursor = upper
        }
        return parts
    }
}
