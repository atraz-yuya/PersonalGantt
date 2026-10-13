import Foundation

nonisolated enum AvailabilityError: LocalizedError, Equatable {
    case invalidSettings
    case invalidDateRange

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "活動可能時間または対象日数が不正です。"
        case .invalidDateRange: "対象期間を計算できません。"
        }
    }
}

/// Pure local-calendar arithmetic, independent of EventKit and the scheduler.
nonisolated struct AvailabilityService: Sendable {
    func planningInterval(referenceDate: Date, settings: ActivitySettings = .default, calendar: Calendar = .current) throws -> DateInterval {
        guard settings.isValid else { throw AvailabilityError.invalidSettings }
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { throw AvailabilityError.invalidDateRange }
        let start = calendar.startOfDay(for: referenceDate)
        guard let end = calendar.date(byAdding: .day, value: settings.planningDayCount, to: start), end > start else {
            throw AvailabilityError.invalidDateRange
        }
        return DateInterval(start: start, end: end)
    }

    func availableSlots(
        fixedEvents: [FixedEvent], settings: ActivitySettings = .default,
        referenceDate: Date, calendar: Calendar = .current
    ) throws -> [AvailableSlot] {
        let range = try planningInterval(referenceDate: referenceDate, settings: settings, calendar: calendar)
        return try availableSlots(fixedEvents: fixedEvents, in: range, settings: settings, referenceDate: referenceDate, calendar: calendar)
    }

    func availableSlots(
        fixedEvents: [FixedEvent], in range: DateInterval, settings: ActivitySettings = .default,
        referenceDate: Date, calendar: Calendar = .current
    ) throws -> [AvailableSlot] {
        guard settings.isValid else { throw AvailabilityError.invalidSettings }
        guard range.start < range.end, range.start.timeIntervalSinceReferenceDate.isFinite,
              range.end.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite else { throw AvailabilityError.invalidDateRange }
        var activity: [AvailableSlot] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw AvailabilityError.invalidDateRange
            }
            guard let window = settings.window(on: day, calendar: calendar) else {
                day = nextDay; continue
            }
            let start = try localTime(window.startMinute, on: day, nextDay: nextDay, calendar: calendar)
            let end = try localTime(window.endMinute, on: day, nextDay: nextDay, calendar: calendar)
            let clippedStart = max(start, referenceDate, range.start)
            let clippedEnd = min(end, range.end)
            if clippedStart < clippedEnd {
                activity.append(AvailableSlot(start: clippedStart, end: clippedEnd))
            }
            day = nextDay
        }
        let globalFree = AvailabilityExclusionSlots.subtract(settings.globalAvailabilityExclusions, from: activity, calendar: calendar)
        return IntervalSubtraction.subtract(occupiedIntervals(fixedEvents, calendar: calendar), from: globalFree)
    }

    /// Event end is exclusive; an all-day event ending at midnight doesn't block the next day.
    func occupiedIntervals(_ events: [FixedEvent], calendar: Calendar) -> [DateInterval] {
        events.compactMap { event in
            guard !event.isCancelled,
                  event.start.timeIntervalSinceReferenceDate.isFinite,
                  event.end.timeIntervalSinceReferenceDate.isFinite,
                  event.start < event.end else { return nil }
            if !event.isAllDay { return DateInterval(start: event.start, end: event.end) }
            let start = calendar.startOfDay(for: event.start)
            let endDay = calendar.startOfDay(for: event.end)
            let end: Date
            if event.end == endDay {
                end = endDay
            } else {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: endDay) else { return nil }
                end = nextDay
            }
            return DateInterval(start: start, end: end)
        }
    }

    private func localTime(_ minute: Int, on day: Date, nextDay: Date, calendar: Calendar) throws -> Date {
        if minute == 1440 { return nextDay }
        guard let date = calendar.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
        ) else { throw AvailabilityError.invalidDateRange }
        return min(date, nextDay)
    }
}

/// Half-open interval subtraction shared with protection of already-started work.
nonisolated enum IntervalSubtraction {
    static func subtract(_ occupied: [DateInterval], from slots: [AvailableSlot]) -> [AvailableSlot] {
        var merged: [DateInterval] = []
        for interval in occupied.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        var result: [AvailableSlot] = []
        for slot in slots.sorted(by: { $0.start < $1.start }) where slot.start < slot.end {
            var cursor = slot.start
            for busy in merged {
                if busy.end <= cursor { continue }
                if busy.start >= slot.end { break }
                if busy.start > cursor { result.append(AvailableSlot(start: cursor, end: busy.start)) }
                cursor = max(cursor, busy.end)
                if cursor >= slot.end { break }
            }
            if cursor < slot.end { result.append(AvailableSlot(start: cursor, end: slot.end)) }
        }
        return result
    }
}
