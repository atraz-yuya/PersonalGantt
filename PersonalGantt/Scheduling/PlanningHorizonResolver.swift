import Foundation

nonisolated struct PlanningHorizonResolver: Sendable {
    func resolve(now: Date, tasks: [Task], routines: [Routine],
                 settings: PlanningHorizonSettings = .default,
                 calendar: Calendar = .current) throws -> PlanningHorizon {
        guard settings.isValid else { throw AvailabilityError.invalidSettings }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw AvailabilityError.invalidDateRange }
        let start = calendar.startOfDay(for: now)
        guard let minimum = calendar.date(byAdding: .day, value: settings.minimumDays, to: start),
              let maximum = calendar.date(byAdding: .day, value: settings.maximumDays, to: start)
        else { throw AvailabilityError.invalidDateRange }
        var needed = minimum
        for task in tasks where !task.isCompleted && task.routineOccurrence == nil {
            if task.deadline.timeIntervalSinceReferenceDate.isFinite { needed = max(needed, task.deadline) }
        }
        for routine in routines where (try? routine.validate()) != nil {
            // Routine's end date is inclusive; a normal Task's deadline is exact.
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: routine.endDate)), end > now else { continue }
            needed = max(needed, end)
        }
        return PlanningHorizon(start: start, end: min(needed, maximum), wasCapped: needed > maximum)
    }
}
