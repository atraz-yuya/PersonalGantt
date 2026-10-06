import Foundation

/// A projection of scheduling results for display. It never changes the plan.
nonisolated struct ScheduleDay: Identifiable, Equatable, Sendable {
    let interval: DateInterval
    var id: Date { interval.start }
}

nonisolated struct DayWorkBlock: Identifiable, Equatable, Sendable {
    let source: ScheduledBlock
    let interval: DateInterval
    var id: ScheduledBlock.ID { .init(taskID: source.taskID, start: interval.start, end: interval.end) }
    var minutes: Double { interval.duration / 60 }
}

nonisolated struct DayFixedEvent: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable { let eventID: String; let day: Date }
    let source: FixedEvent
    let interval: DateInterval
    var id: ID { .init(eventID: source.id, day: interval.start) }
}

nonisolated enum DayTimelineItem: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable { case work(ScheduledBlock.ID), event(DayFixedEvent.ID) }
    case work(DayWorkBlock)
    case event(DayFixedEvent)
    var id: ID {
        switch self { case .work(let value): .work(value.id); case .event(let value): .event(value.id) }
    }
    var interval: DateInterval {
        switch self { case .work(let value): value.interval; case .event(let value): value.interval }
    }
}

nonisolated struct DaySchedule: Equatable, Sendable {
    let day: ScheduleDay
    var blocks: [DayWorkBlock]
    var events: [DayFixedEvent]
    var availableIntervals: [DateInterval]
    var workMinutes: Double { blocks.reduce(0) { $0 + $1.minutes } }
    var items: [DayTimelineItem] {
        // Fixed events win ties. Use stable source identity for equal start/end times.
        (events.map(DayTimelineItem.event) + blocks.map(DayTimelineItem.work)).sorted {
            if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
            switch ($0, $1) {
            case (.event(let a), .event(let b)): return a.source.id < b.source.id
            case (.work(let a), .work(let b)):
                if a.source.taskID != b.source.taskID { return a.source.taskID.uuidString < b.source.taskID.uuidString }
                return a.interval.end < b.interval.end
            case (.event, .work): return true
            case (.work, .event): return false
            }
        }
    }
}

nonisolated enum BlockTimePosition: String, Sendable {
    case past = "過去の時間枠"
    case current = "現在の時間枠"
    case future = "今後の時間枠"
    static func of(_ block: ScheduledBlock, now: Date) -> Self {
        if block.end <= now { return .past }
        return block.start <= now ? .current : .future
    }
}

nonisolated enum SchedulePresentation {
    static func day(containing date: Date, calendar: Calendar) -> ScheduleDay? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let interval = calendar.dateInterval(of: .day, for: date), interval.duration > 0 else { return nil }
        return ScheduleDay(interval: interval)
    }

    static func days(in range: DateInterval, calendar: Calendar) -> [ScheduleDay] {
        guard range.start.timeIntervalSinceReferenceDate.isFinite, range.end.timeIntervalSinceReferenceDate.isFinite,
              range.start < range.end else { return [] }
        var result: [ScheduleDay] = []
        var cursor = range.start
        while cursor < range.end, result.count < 367, let value = day(containing: cursor, calendar: calendar) {
            result.append(value)
            guard value.interval.end > cursor else { break }
            cursor = value.interval.end
        }
        return result
    }

    static func snapshot(on date: Date, blocks: [ScheduledBlock], events: [FixedEvent],
                         slots: [AvailableSlot], calendar: Calendar) -> DaySchedule? {
        guard let day = day(containing: date, calendar: calendar) else { return nil }
        let work = blocks.compactMap { block -> DayWorkBlock? in
            guard let interval = clipped(start: block.start, end: block.end, to: day.interval) else { return nil }
            return DayWorkBlock(source: block, interval: interval)
        }.sorted {
            $0.interval.start == $1.interval.start ? $0.source.taskID.uuidString < $1.source.taskID.uuidString : $0.interval.start < $1.interval.start
        }
        let fixed = events.compactMap { event -> DayFixedEvent? in
            // Use the same all-day/cancelled rules as availability, without merging display titles.
            guard let occupied = AvailabilityService().occupiedIntervals([event], calendar: calendar).first,
                  let interval = clipped(start: occupied.start, end: occupied.end, to: day.interval) else { return nil }
            return DayFixedEvent(source: event, interval: interval)
        }.sorted {
            $0.interval.start == $1.interval.start ? $0.source.id < $1.source.id : $0.interval.start < $1.interval.start
        }
        let available = slots.compactMap { clipped(start: $0.start, end: $0.end, to: day.interval) }.sorted { $0.start < $1.start }
        return DaySchedule(day: day, blocks: work, events: fixed, availableIntervals: available)
    }

    static func clipped(start: Date, end: Date, to range: DateInterval) -> DateInterval? {
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start < end, range.duration > 0 else { return nil }
        let lower = max(start, range.start), upper = min(end, range.end)
        return lower < upper ? DateInterval(start: lower, end: upper) : nil
    }
}

/// Fractions are based on actual start/end Dates, including 23/25-hour DST days.
nonisolated struct GanttPlacement: Equatable, Sendable {
    let startFraction: Double
    let lengthFraction: Double
    static func of(_ interval: DateInterval, in day: ScheduleDay) -> Self? {
        guard let visible = SchedulePresentation.clipped(start: interval.start, end: interval.end, to: day.interval) else { return nil }
        return Self(startFraction: visible.start.timeIntervalSince(day.interval.start) / day.interval.duration,
                    lengthFraction: visible.duration / day.interval.duration)
    }
}
