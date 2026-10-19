import Foundation

nonisolated struct TodaySummary: Equatable, Sendable {
    var blocks: [ScheduledBlock]
    var schedule: DaySchedule?
    var nextWork: ScheduledBlock?
    var remainingPlannedMinutes: Double
    var actualMinutes: Double
    var allDayEvents: [DayFixedEvent] { schedule?.events.filter { $0.source.isAllDay } ?? [] }
    var timelineItems: [DayTimelineItem] {
        schedule?.items.filter {
            if case .event(let event) = $0 { return !event.source.isAllDay }
            return true
        } ?? []
    }
    static func make(now: Date, tasks: [Task], blocks: [ScheduledBlock], events: [FixedEvent] = [],
                     sessions: [WorkSession], calendar: Calendar) -> Self {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return Self(blocks: [], remainingPlannedMinutes: 0, actualMinutes: 0) }
        let active = Set(tasks.filter { !$0.isCompleted }.map(\.id))
        // Preserved planned history belongs to the timeline, not today's to-do cards.
        let today = blocks.filter { active.contains($0.taskID) && $0.start < day.end && $0.end > day.start }.sorted { $0.start < $1.start }
        let upcoming = today.filter { $0.end > now }
        let planned = upcoming.reduce(0.0) { $0 + max(0, min($1.end, day.end).timeIntervalSince(max($1.start, now))) / 60 }
        let actual = sessions.reduce(0.0) { sum, session in
            let overlap = max(0, min(session.end, day.end).timeIntervalSince(max(session.start, day.start)))
            return sum + overlap / session.end.timeIntervalSince(session.start) * Double(session.actualMinutes)
        }
        let schedule = SchedulePresentation.snapshot(on: now, blocks: today, events: events, slots: [], calendar: calendar)
        return Self(blocks: today, schedule: schedule, nextWork: upcoming.first, remainingPlannedMinutes: planned, actualMinutes: actual)
    }
}
