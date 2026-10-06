import Foundation
import EventKit

/// Copies EventKit objects into values on the fetch callback's queue.
nonisolated enum ReminderEventKitConverter {
    static func record(from reminder: EKReminder, calendar: Calendar) -> ReminderRecord {
        let converted = deadline(from: reminder.dueDateComponents, calendar: calendar)
        return ReminderRecord(id: reminder.calendarItemIdentifier,
            externalIdentifier: reminder.calendarItemExternalIdentifier,
            listID: reminder.calendar.calendarIdentifier, title: reminder.title ?? "",
            deadline: converted.date, hasDateOnlyDeadline: converted.isDateOnly,
            hasInvalidDeadline: converted.isInvalid, isCompleted: reminder.isCompleted,
            allowsCompletionChanges: reminder.calendar.allowsContentModifications,
            isRecurring: reminder.hasRecurrenceRules,
            occurrenceKey: reminder.hasRecurrenceRules && converted.date != nil ? occurrenceKey(reminder.dueDateComponents!) : nil)
    }

    static func deadline(from components: DateComponents?, calendar: Calendar) -> (date: Date?, isDateOnly: Bool, isInvalid: Bool) {
        guard let components else { return (nil, false, false) }
        guard let year = components.year, let month = components.month, let day = components.day,
              components.hour != nil || (components.minute == nil && components.second == nil)
        else { return (nil, false, true) }
        // EventKit stores Gregorian due components. Floating dates follow the activity time zone.
        var effective = Calendar(identifier: .gregorian)
        effective.timeZone = components.timeZone ?? calendar.timeZone
        let dateOnly = components.hour == nil
        let hour = dateOnly ? 23 : components.hour!
        let minute = dateOnly ? 59 : components.minute ?? 0
        let second = dateOnly ? 0 : components.second ?? 0
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              let date = effective.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        else { return (nil, dateOnly, true) }
        let actual = effective.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard date >= .distantPast, date <= .distantFuture,
              actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second
        else { return (nil, dateOnly, true) }
        return (date, dateOnly, false)
    }

    private static func occurrenceKey(_ components: DateComponents) -> String {
        // Floating due dates retain identity when the device time zone changes.
        [components.year, components.month, components.day, components.hour, components.minute, components.second]
            .map { $0.map(String.init) ?? "_" }.joined(separator: ":") + "|" + (components.timeZone?.identifier ?? "floating")
    }
}
