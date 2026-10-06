import EventKit

/// Identity boundary reserved for a future Reminders provider.
/// No permission request, reminder fetch, or Task synchronization is implemented here.
@MainActor
enum ReminderIdentity {
    static func identifier(of reminder: EKReminder) -> String {
        reminder.calendarItemIdentifier
    }
}
