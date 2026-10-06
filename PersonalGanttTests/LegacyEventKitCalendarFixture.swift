import Foundation
import EventKit
@testable import PersonalGantt

/// Only the in-memory Phase 4 conversion regression remains; no EventKit Calendar provider.
@MainActor
enum LegacyEventKitCalendarFixture {
    static func fixedEvent(from event: EKEvent, calendarID: String) -> FixedEvent? {
        guard event.status != .canceled,
              let start = event.startDate, let end = event.endDate,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, start < end else { return nil }
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let occurrenceID = "\(calendarID):\(identifier):\(start.timeIntervalSinceReferenceDate.bitPattern):\(end.timeIntervalSinceReferenceDate.bitPattern)"
        return FixedEvent(id: occurrenceID, calendarID: calendarID, title: event.title ?? "名称未設定",
                          start: start, end: end, isAllDay: event.isAllDay)
    }
}
