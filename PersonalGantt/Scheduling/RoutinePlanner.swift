import Foundation

/// Expand only the rolling planning window, never the entire routine lifetime.
nonisolated struct RoutinePlanner: Sendable {
    func tasks(for routines: [Routine], in range: DateInterval, calendar: Calendar) -> [Task] {
        let days = DailyWorkload.dayParts(start: range.start, end: range.end, calendar: calendar)
            .compactMap { calendar.dateInterval(of: .day, for: $0.start) }
        return routines.sorted { $0.id.uuidString < $1.id.uuidString }.flatMap { routine -> [Task] in
            guard (try? routine.validate()) != nil else { return [] }
            let first = calendar.startOfDay(for: routine.startDate)
            let last = calendar.startOfDay(for: routine.endDate)
            return days.compactMap { interval in
                guard interval.start >= first, interval.start <= last,
                      routine.recurrence.includes(interval.start, calendar: calendar) else { return nil }
                // Gregorian civil dates stay stable even if the user's calendar identifier changes.
                var civil = Calendar(identifier: .gregorian)
                civil.timeZone = calendar.timeZone
                let parts = civil.dateComponents([.era, .year, .month, .day], from: interval.start)
                let key = "\(parts.era ?? 1)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
                let occurrence = RoutineOccurrence(routineID: routine.id, dayKey: key,
                                                   dayStart: interval.start, dayEnd: interval.end)
                guard !routine.skippedOccurrenceIDs.contains(occurrence.taskID) else { return nil }
                return Task(id: occurrence.taskID, title: routine.title,
                            isCompleted: routine.completedOccurrenceIDs.contains(occurrence.taskID),
                            estimatedMinutes: routine.estimatedMinutesPerDay, deadline: interval.end,
                            routineOccurrence: occurrence)
            }
        }
    }
}
