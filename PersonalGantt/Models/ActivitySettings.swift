import Foundation

nonisolated struct ActivityWindow: Codable, Equatable, Sendable {
    /// Local minutes after midnight. End may be 1440 (next midnight).
    var startMinute: Int
    var endMinute: Int
    var isValid: Bool {
        (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute
    }
    var displayName: String { "\(Self.time(startMinute))〜\(Self.time(endMinute))" }
    static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

/// A nil window explicitly represents a non-working day.
nonisolated struct ActivityDayOverride: Codable, Equatable, Sendable {
    var window: ActivityWindow?
}

nonisolated struct ActivitySettings: Codable, Equatable, Sendable {
    var weekday = ActivityWindow(startMinute: 10 * 60, endMinute: 1440)
    var weekend = ActivityWindow(startMinute: 10 * 60, endMinute: 1440)
    var planningDayCount = 14
    /// Gregorian local date keys survive time-zone offset changes without shifting the chosen date.
    var dayOverrides: [String: ActivityDayOverride] = [:]
    var globalAvailabilityExclusions: [GlobalAvailabilityExclusion] = []
    static let `default` = ActivitySettings()
    var isValid: Bool {
        weekday.isValid && weekend.isValid && planningDayCount > 0 && AvailabilityExclusion.valid(globalAvailabilityExclusions) && dayOverrides.allSatisfy {
            Self.date(for: $0.key) != nil && ($0.value.window?.isValid ?? true)
        }
    }
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])), dayKey(date, calendar: gregorian) == key else { return nil }
        return date
    }
    func window(on date: Date, calendar: Calendar) -> ActivityWindow? {
        if let override = dayOverrides[Self.dayKey(date, calendar: calendar)] { return override.window }
        let day = calendar.component(.weekday, from: date)
        return day == 1 || day == 7 ? weekend : weekday
    }
}

/// Time text accepts HH:mm, with 24:00 allowed only for the end of a day.
nonisolated struct ActivityWindowDraft {
    var start: String
    var end: String
    init(_ window: ActivityWindow) {
        start = ActivityWindow.time(window.startMinute); end = ActivityWindow.time(window.endMinute)
    }
    var window: ActivityWindow? {
        guard let start = Self.minute(start), let end = Self.minute(end) else { return nil }
        let value = ActivityWindow(startMinute: start, endMinute: end)
        return value.isValid ? value : nil
    }
    private static func minute(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...24).contains(hour), (0..<60).contains(minute), hour < 24 || minute == 0 else { return nil }
        return hour * 60 + minute
    }
}

nonisolated extension ActivitySettings {
    enum CodingKeys: String, CodingKey { case weekday, weekend, planningDayCount, dayOverrides, globalAvailabilityExclusions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekday = try c.decode(ActivityWindow.self, forKey: .weekday)
        weekend = try c.decode(ActivityWindow.self, forKey: .weekend)
        planningDayCount = try c.decode(Int.self, forKey: .planningDayCount)
        dayOverrides = try c.decodeIfPresent([String: ActivityDayOverride].self, forKey: .dayOverrides) ?? [:]
        globalAvailabilityExclusions = try c.decodeIfPresent([GlobalAvailabilityExclusion].self, forKey: .globalAvailabilityExclusions) ?? []
    }
}
