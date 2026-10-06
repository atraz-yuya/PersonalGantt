import Foundation

nonisolated struct GoogleCalendarEvent: Decodable, Sendable {
    let id: String
    let summary: String?
    let status: String?
    let start: EventDate?
    let end: EventDate?
    nonisolated struct EventDate: Decodable, Sendable {
        let date: String?
        let dateTime: String?
        let timeZone: String?
    }

    func fixedEvent(calendarID: String, calendarTimeZone: String?, activityCalendar: Calendar) throws -> FixedEvent? {
        if status == "cancelled" { return nil }
        guard !id.isEmpty, let start, let end else { throw GoogleCalendarError.invalidResponse }
        let allDay = start.date != nil && end.date != nil && start.dateTime == nil && end.dateTime == nil
        let startDate: Date
        let endDate: Date
        if allDay {
            startDate = try Self.localDay(start.date!, calendar: activityCalendar)
            endDate = try Self.localDay(end.date!, calendar: activityCalendar)
        } else {
            guard start.date == nil, end.date == nil, let from = start.dateTime, let to = end.dateTime else {
                throw GoogleCalendarError.invalidResponse
            }
            startDate = try Self.instant(from, timeZone: start.timeZone ?? calendarTimeZone)
            endDate = try Self.instant(to, timeZone: end.timeZone ?? calendarTimeZone)
        }
        guard startDate < endDate else { throw GoogleCalendarError.invalidResponse }
        return FixedEvent(id: "\(calendarID):\(id):\(startDate.timeIntervalSinceReferenceDate.bitPattern)",
                          calendarID: calendarID, title: summary ?? "名称未設定",
                          start: startDate, end: endDate, isAllDay: allDay)
    }

    private static func localDay(_ text: String, calendar: Calendar) throws -> Date {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { throw GoogleCalendarError.invalidResponse }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard let result = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
              gregorian.dateComponents([.year, .month, .day], from: result) == DateComponents(year: year, month: month, day: day) else {
            throw GoogleCalendarError.invalidResponse
        }
        return result
    }

    private static func instant(_ text: String, timeZone: String?) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        guard let identifier = timeZone, let zone = TimeZone(identifier: identifier) else { throw GoogleCalendarError.invalidResponse }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
        }
        throw GoogleCalendarError.invalidResponse
    }
}
