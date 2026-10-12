import Foundation
@testable import PersonalGantt

// Original regression cases explicitly exercise their historical 08/09–23 windows.
// Production defaults and the new configurable windows are covered by ActivityHoursTests.
nonisolated extension ActivitySettings {
    static var legacyFixture: Self {
        var value = Self()
        value.weekday = ActivityWindow(startMinute: 480, endMinute: 1380)
        value.weekend = ActivityWindow(startMinute: 540, endMinute: 1380)
        return value
    }
}
