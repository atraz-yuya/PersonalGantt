import Foundation

/// Civil time input shared by scheduling settings and deadline editors.
nonisolated enum ClockTime {
    static func minute(_ text: String, allowsEndOfDay: Bool = false) -> Int? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [Substring]
        if input.count == 4, input.allSatisfy({ $0.isASCII && $0.isNumber }) {
            parts = [input.prefix(2), input.suffix(2)]
        } else {
            parts = input.split(separator: ":", omittingEmptySubsequences: false)
        }
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<60).contains(minute), (0...23).contains(hour) || allowsEndOfDay && hour == 24 && minute == 0 else { return nil }
        return hour * 60 + minute
    }
    static func normalized(_ text: String, allowsEndOfDay: Bool = false) -> String {
        guard let minute = minute(text, allowsEndOfDay: allowsEndOfDay) else { return text }
        return ActivityWindow.time(minute)
    }
    static func text(for date: Date, calendar: Calendar) -> String {
        ActivityWindow.time(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }
    static func date(_ text: String, on date: Date, calendar: Calendar) -> Date? {
        guard let minute = minute(text) else { return nil }
        return LocalSchedulingTime.date(minute, on: calendar.startOfDay(for: date), calendar: calendar, strict: true)
    }
}
