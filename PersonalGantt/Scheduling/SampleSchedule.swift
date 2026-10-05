import Foundation

nonisolated enum SampleSchedule {
    /// Relative dates keep the demo readable when opened on a later day.
    static func make(referenceDate: Date = Date(), calendar: Calendar = .current) -> (tasks: [Task], slots: [AvailableSlot]) {
        let today = calendar.startOfDay(for: referenceDate)
        func date(dayOffset: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }

        return (
            tasks: [
                Task(title: "卒論", estimatedMinutes: 90, deadline: date(dayOffset: 1, hour: 21)),
                Task(title: "AtCoder", estimatedMinutes: 120, deadline: date(dayOffset: 3, hour: 21)),
                Task(title: "Kaggle", estimatedMinutes: 150, deadline: date(dayOffset: 2, hour: 21))
            ],
            slots: [
                AvailableSlot(start: date(dayOffset: 1, hour: 18), end: date(dayOffset: 1, hour: 20)),
                AvailableSlot(start: date(dayOffset: 2, hour: 18), end: date(dayOffset: 2, hour: 19)),
                AvailableSlot(start: date(dayOffset: 3, hour: 18), end: date(dayOffset: 3, hour: 20))
            ]
        )
    }
}
