import Foundation

@MainActor
extension ScheduleViewModel {
    func daySchedule(on date: Date) -> DaySchedule? {
        SchedulePresentation.snapshot(on: date, blocks: result.blocks, events: fixedEvents,
                                      slots: availableSlots, calendar: presentationCalendar)
    }

    func displayDays(referenceDate: Date) -> [ScheduleDay] {
        let range = planningInterval ?? (try? AvailabilityService().planningInterval(referenceDate: referenceDate, calendar: presentationCalendar))
        return range.map { SchedulePresentation.days(in: $0, calendar: presentationCalendar) } ?? []
    }

    func task(for id: UUID) -> Task? { tasks.first { $0.id == id } }
    func taskIsBusy(_ id: UUID) -> Bool {
        guard isReminderTask(id) else { return false }
        return (reminders?.isLoading ?? false) ||
            task(for: id)?.reminderIdentifier.flatMap { reminders?.record(for: $0) } == nil
    }
    func canToggleTask(_ task: Task) -> Bool {
        !isReminderTask(task.id) || (task.reminderIdentifier.flatMap { reminders?.record(for: $0)?.allowsCompletionChanges } ?? false)
    }
}
