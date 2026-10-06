import EventKit

/// Calendar item identity used to associate a Reminder with local Task requirements.
@MainActor
enum ReminderIdentity {
    static func identifier(of reminder: EKReminder) -> String {
        reminder.calendarItemIdentifier
    }
}
