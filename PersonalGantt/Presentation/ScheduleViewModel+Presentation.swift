import Foundation

@MainActor
extension ScheduleViewModel {
    func daySchedule(on date: Date) -> DaySchedule? {
        SchedulePresentation.snapshot(on: date, blocks: result.blocks, events: fixedEvents,
                                      slots: availableSlots, calendar: presentationCalendar)
    }

    func displayDays(referenceDate: Date) -> [ScheduleDay] {
        let range = planningInterval ?? (try? PlanningHorizonResolver().resolve(now: referenceDate, tasks: tasks,
            routines: routines, settings: horizonSettings, calendar: presentationCalendar).interval)
        return range.map { SchedulePresentation.days(in: $0, calendar: presentationCalendar) } ?? []
    }

    func task(for id: UUID) -> Task? { tasks.first { $0.id == id } }

    var planningPeriodDescription: String {
        guard let range = planningInterval else { return "計画期間を計算中" }
        return "\(range.start.formatted(date: .abbreviated, time: .omitted)) 〜 \(range.end.formatted(date: .abbreviated, time: .shortened))"
    }

    var horizonCapMessage: String? {
        planningHorizon?.wasCapped == true
            ? "最長\(horizonSettings.maximumDays)暦日まで計画しています。さらに先の締切・ルーティン終了日があります。" : nil
    }

    func deadlineDaysRemaining(for task: Task, now: Date? = nil) -> Int {
        max(0, presentationCalendar.dateComponents([.day], from: presentationCalendar.startOfDay(for: now ?? schedulingReferenceDate),
            to: presentationCalendar.startOfDay(for: task.deadline)).day ?? 0)
    }

    func unscheduledReason(for task: Task) -> UnscheduledReason? {
        guard unallocatedMinutes(for: task) > 0 else { return nil }
        if let range = planningInterval, task.deadline > range.end { return .deadlineBeyondPlanningHorizon }
        if coverageMessage != nil, task.deadline > schedulingReferenceDate,
           calendarCoverage.map({ task.deadline > $0.end }) ?? true { return .calendarCoveragePending }
        let taskSlots = AvailabilityExclusionSlots.subtract(task.availabilityExclusions, from: availableSlots, calendar: presentationCalendar)
        let eligible = taskSlots.filter { slot in
            guard max(slot.start, task.notBefore ?? slot.start) < min(slot.end, task.deadline) else { return false }
            if let occurrence = task.routineOccurrence {
                return slot.end > occurrence.dayStart && slot.start < occurrence.dayEnd
            }
            return true
        }
        if eligible.isEmpty { return .noAvailability }
        if let limit = workloadSettings.maxScheduledMinutesPerDay {
            let totals = dailyScheduledMinutes
            if eligible.contains(where: { slot in
                DailyWorkload.dayParts(start: slot.start, end: min(slot.end, task.deadline), calendar: presentationCalendar)
                    .contains { (totals[presentationCalendar.startOfDay(for: $0.start)] ?? 0) >= Double(limit) }
            }) { return .dailyWorkloadLimit }
        }
        return .insufficientCapacityBeforeDeadline
    }

    func feasibilityMessage(for task: Task) -> String? {
        let conflicts = result.fixedRoutineConflicts.filter { $0.taskID == task.id }
        if !conflicts.isEmpty { return conflicts.map { $0.reason.message }.joined(separator: " ") }
        if !task.isCompleted, let range = planningInterval, task.deadline > range.end {
            return "締切は現在の計画期間より先です。対象期間内の未配置だけでは、締切に間に合うか判断できません。"
        }
        switch unscheduledReason(for: task) {
        case .deadlineBeyondPlanningHorizon:
            return "締切は現在の計画期間より先です。"
        case .calendarCoveragePending:
            return "締切までのCalendar情報を未取得です。未配置時間は再読み込み後に確認してください。"
        case .dailyWorkloadLimit:
            return "現在の空き時間と日次上限では、締切までに\(unallocatedMinutes(for: task).formatted())分配置できません。"
        case .noAvailability:
            return "対象日時の空き時間がないため、\(unallocatedMinutes(for: task).formatted())分未配置です。"
        case .insufficientCapacityBeforeDeadline:
            return "現在の空き時間では、締切までに\(unallocatedMinutes(for: task).formatted())分不足します。"
        case nil: return nil
        }
    }
    func taskIsBusy(_ id: UUID) -> Bool {
        if isBackupRecoveryRequired { return true }
        guard isReminderTask(id) else { return false }
        return (reminders?.isLoading ?? false) ||
            task(for: id)?.reminderIdentifier.flatMap { reminders?.record(for: $0) } == nil
    }
    func canToggleTask(_ task: Task) -> Bool {
        !isBackupRecoveryRequired && (!isReminderTask(task.id) ||
            (reminders?.isStorageAvailable == true && (task.reminderIdentifier.flatMap { reminders?.record(for: $0)?.allowsCompletionChanges } ?? false)))
    }
}
