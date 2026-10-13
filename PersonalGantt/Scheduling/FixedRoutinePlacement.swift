import Foundation

nonisolated enum FixedRoutineConflictReason: String, Codable, Sendable {
    case calendarEvent, anotherFixedRoutine, globalExclusion, outsideActivityHours, unavailableCalendarRange
    case protectedWork, dailyCap, nonexistentLocalTime, missedStart, outsidePlanningHorizon
    var message: String {
        switch self {
        case .calendarEvent: "Calendarの固定予定と重複しています。"
        case .anotherFixedRoutine: "別の固定Routineと重複しています。"
        case .globalExclusion: "共通の配置禁止時間と重複しています。"
        case .outsideActivityHours: "稼働時間の外に固定されています。"
        case .unavailableCalendarRange: "固定時刻のCalendar情報または空き時間を確認できません。"
        case .protectedWork: "開始済みの作業枠と重複しています。"
        case .dailyCap: "固定Routineによって日次上限を超えています。"
        case .nonexistentLocalTime: "夏時間の切替により、この日の固定開始時刻が存在しません。"
        case .missedStart: "固定開始時刻を過ぎています。別の時刻には移動しません。"
        case .outsidePlanningHorizon: "固定枠が計画期間の上限を越えています。別の時刻には移動しません。"
        }
    }
}
nonisolated struct FixedRoutineConflict: Codable, Equatable, Sendable {
    var taskID: UUID
    var reason: FixedRoutineConflictReason
}

nonisolated struct FixedRoutinePlacement {
    var blocks: [ScheduledBlock] = []
    var conflicts: [FixedRoutineConflict] = []
    var unscheduled: [UUID] = []
    var dailySeconds: [Date: Double]
    var remainingSlots: [AvailableSlot]

    init(tasks: [Task], slots: [AvailableSlot], dailySeconds: [Date: Double], allocated: [UUID: Double],
         completed: [UUID: Double], workload: WorkloadSettings, calendar: Calendar,
         activity: ActivitySettings?, events: [FixedEvent], protectedBlocks: [ScheduledBlock], now: Date?, coverage: CalendarCoverage?, requiresCoverage: Bool, planningRange: DateInterval? = nil) {
        self.dailySeconds = dailySeconds; remainingSlots = slots
        func overlaps(_ a: ScheduledBlock, _ b: DateInterval) -> Bool { a.start < b.end && b.start < a.end }
        let occupied = AvailabilityService().occupiedIntervals(events, calendar: calendar)
        let fixed = tasks.filter { $0.isFixedRoutine && !$0.isCompleted }.sorted {
            let a = $0.routineOccurrence?.fixedStart ?? $0.routineOccurrence?.dayStart ?? .distantPast
            let b = $1.routineOccurrence?.fixedStart ?? $1.routineOccurrence?.dayStart ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        // Protected fixed blocks still participate in conflicts, without charging their cap twice.
        var reservations = protectedBlocks.filter { block in tasks.contains { $0.id == block.taskID && $0.isFixedRoutine } }
        for task in fixed {
            guard (completed[task.id] ?? 0) < Double(task.estimatedMinutes) else { continue }
            guard let block = task.fixedRoutineBlock else {
                conflicts.append(.init(taskID: task.id, reason: .nonexistentLocalTime)); unscheduled.append(task.id); continue
            }
            let isProtected = (allocated[task.id] ?? 0) > 0 || protectedBlocks.contains { $0.taskID == task.id }
            if let now, block.start < now && !isProtected {
                conflicts.append(.init(taskID: task.id, reason: .missedStart)); unscheduled.append(task.id); continue
            }
            if let planningRange, !isProtected,
               block.start < planningRange.start || block.end > planningRange.end {
                conflicts.append(.init(taskID: task.id, reason: .outsidePlanningHorizon)); unscheduled.append(task.id); continue
            }
            if requiresCoverage && !isProtected && coverage?.contains(DateInterval(start: block.start, end: block.end)) != true {
                conflicts.append(.init(taskID: task.id, reason: .unavailableCalendarRange)); unscheduled.append(task.id); continue
            }
            var reasons: Set<FixedRoutineConflictReason> = []
            if occupied.contains(where: { overlaps(block, $0) }) { reasons.insert(.calendarEvent) }
            if reservations.contains(where: { $0.taskID != task.id && overlaps(block, DateInterval(start: $0.start, end: $0.end)) }) {
                reasons.insert(.anotherFixedRoutine)
                for other in reservations where other.taskID != task.id && overlaps(block, DateInterval(start: other.start, end: other.end)) {
                    let conflict = FixedRoutineConflict(taskID: other.taskID, reason: .anotherFixedRoutine)
                    if !conflicts.contains(conflict) { conflicts.append(conflict) }
                }
            }
            if protectedBlocks.contains(where: { $0.taskID != task.id && overlaps(block, DateInterval(start: $0.start, end: $0.end)) }) { reasons.insert(.protectedWork) }
            if let activity {
                let interval = DateInterval(start: block.start, end: block.end)
                if AvailabilityExclusionSlots.intervals(activity.globalAvailabilityExclusions, in: interval, calendar: calendar).contains(where: { overlaps(block, $0) }) { reasons.insert(.globalExclusion) }
                var hours = activity; hours.globalAvailabilityExclusions = []
                let hoursSlots = (try? AvailabilityService().availableSlots(fixedEvents: [], in: interval, settings: hours, referenceDate: block.start, calendar: calendar)) ?? []
                if !IntervalSubtraction.subtract(hoursSlots.map { DateInterval(start: $0.start, end: $0.end) }, from: [AvailableSlot(start: block.start, end: block.end)]).isEmpty { reasons.insert(.outsideActivityHours) }
            }
            if reasons.isEmpty && !isProtected && !IntervalSubtraction.subtract(slots.map { DateInterval(start: $0.start, end: $0.end) }, from: [AvailableSlot(start: block.start, end: block.end)]).isEmpty { reasons.insert(.unavailableCalendarRange) }
            if !isProtected {
                blocks.append(block); reservations.append(block)
                for part in DailyWorkload.dayParts(start: block.start, end: block.end, calendar: calendar) {
                    let day = calendar.startOfDay(for: part.start)
                    self.dailySeconds[day, default: 0] += part.duration
                }
            }
            if let cap = workload.maxScheduledMinutesPerDay,
               DailyWorkload.dayParts(start: block.start, end: block.end, calendar: calendar).contains(where: { (self.dailySeconds[calendar.startOfDay(for: $0.start)] ?? 0) > Double(cap) * 60 + 0.000001 }) { reasons.insert(.dailyCap) }
            for reason in reasons.sorted(by: { $0.rawValue < $1.rawValue }) {
                let conflict = FixedRoutineConflict(taskID: task.id, reason: reason)
                if !conflicts.contains(conflict) { conflicts.append(conflict) }
            }
        }
        remainingSlots = IntervalSubtraction.subtract(blocks.map { DateInterval(start: $0.start, end: $0.end) }, from: slots)
        conflicts.sort { $0.taskID == $1.taskID ? $0.reason.rawValue < $1.reason.rawValue : $0.taskID.uuidString < $1.taskID.uuidString }
    }
}
