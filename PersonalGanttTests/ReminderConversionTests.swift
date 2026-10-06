import Foundation
import Testing
@testable import PersonalGantt

struct ReminderConversionTests {
    @Test func dateOnlyBecomes2359AndFloatingDateUsesActivityTimezone() {
        let parts = DateComponents(year: 2026, month: 10, day: 7)
        let utc = ReminderEventKitConverter.deadline(from: parts, calendar: ReminderFixtures.calendar)
        #expect(utc.date == ReminderFixtures.date(23, 59))
        #expect(utc.isDateOnly && !utc.isInvalid)
        var tokyo = ReminderFixtures.calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let local = ReminderEventKitConverter.deadline(from: parts, calendar: tokyo)
        #expect(local.date == ReminderFixtures.date(14, 59))
    }

    @Test func explicitTimezoneAndTimeArePreserved() {
        var parts = DateComponents(year: 2026, month: 10, day: 7, hour: 10, minute: 30, second: 15)
        parts.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let result = ReminderEventKitConverter.deadline(from: parts, calendar: ReminderFixtures.calendar)
        #expect(result.date == ReminderFixtures.date(1, 30).addingTimeInterval(15))
        #expect(!result.isDateOnly && !result.isInvalid)
    }

    @Test func noDeadlineIsInputWaitingRatherThanInvalidDate() {
        let result = ReminderEventKitConverter.deadline(from: nil, calendar: ReminderFixtures.calendar)
        #expect(result.date == nil && !result.isInvalid)
    }

    @Test(arguments: [
        DateComponents(year: 2026, month: 2, day: 30),
        DateComponents(year: 2026, month: 13, day: 1),
        DateComponents(year: 2026, month: 10, day: 7, hour: 24),
        DateComponents(year: 2026, month: 10, day: 7, hour: 10, minute: 60),
        DateComponents(year: 2026, month: 10, day: 7, minute: 30),
        DateComponents(month: 10, day: 7)
    ])
    func invalidOrIncompleteDatesAreNotNormalizedIntoDifferentDeadlines(parts: DateComponents) {
        let result = ReminderEventKitConverter.deadline(from: parts, calendar: ReminderFixtures.calendar)
        #expect(result.isInvalid && result.date == nil)
    }

    @Test func nonexistentDSTTimeIsRejected() {
        var parts = DateComponents(year: 2026, month: 3, day: 8, hour: 2, minute: 30)
        parts.timeZone = TimeZone(identifier: "America/Los_Angeles")
        #expect(ReminderEventKitConverter.deadline(from: parts, calendar: ReminderFixtures.calendar).isInvalid)
    }

    @Test func invalidMinutesMissingDeadlineAndEmptyTitleStayOutsideScheduler() {
        let r = ReminderFixtures.record()
        #expect(ReminderTaskMapper.task(for: r, metadata: ReminderFixtures.metadata(minutes: nil)) == nil)
        #expect(ReminderTaskMapper.task(for: r, metadata: ReminderFixtures.metadata(minutes: 0)) == nil)
        #expect(ReminderTaskMapper.task(for: ReminderFixtures.record(deadline: nil), metadata: ReminderFixtures.metadata()) == nil)
        #expect(ReminderTaskMapper.task(for: ReminderFixtures.record(title: " \n "), metadata: ReminderFixtures.metadata()) == nil)
    }

    @Test func localRequirementsMakeAStableTaskAndSourceDeadlineWins() throws {
        let metadata = ReminderFixtures.metadata(minutes: 90, override: ReminderFixtures.date(12))
        let task = try #require(ReminderTaskMapper.task(for: ReminderFixtures.record(title: " 卒論 "), metadata: metadata))
        #expect(task.id == metadata.taskID && task.title == "卒論")
        #expect(task.deadline == ReminderFixtures.date(23) && task.estimatedMinutes == 90)
        #expect(task.reminderIdentifier == "r")
        let withoutDue = try #require(ReminderTaskMapper.task(for: ReminderFixtures.record(deadline: nil), metadata: metadata))
        #expect(withoutDue.deadline == ReminderFixtures.date(12))
    }

    @Test func exclusionAndCompletionAreKeptSeparate() throws {
        #expect(ReminderTaskMapper.task(for: ReminderFixtures.record(), metadata: ReminderFixtures.metadata(excluded: true)) == nil)
        let completed = try #require(ReminderTaskMapper.task(for: ReminderFixtures.record(completed: true), metadata: ReminderFixtures.metadata()))
        #expect(completed.isCompleted)
        #expect(Scheduler().schedule(tasks: [completed], availableSlots: []).unscheduledTaskIDs.isEmpty)
    }

    @Test func uniqueExternalIdentityMigratesEstimateAndUUIDAcrossLocalIDChanges() throws {
        var old = ReminderLocalState()
        old.metadata["old"] = ReminderFixtures.metadata(minutes: 120)
        let next = try ReminderTaskMapper.reconcile([ReminderFixtures.record("new")], state: old)
        #expect(next.metadata["old"] == nil)
        #expect(next.metadata["new"]?.taskID == old.metadata["old"]?.taskID)
        #expect(next.metadata["new"]?.estimatedMinutes == 120)
    }

    @Test func duplicateExternalIDsAndCrossListChangesNeverGuessAnAssociation() throws {
        var old = ReminderLocalState()
        old.metadata["old"] = ReminderFixtures.metadata(minutes: 120)
        var n = 10
        let next = try ReminderTaskMapper.reconcile([ReminderFixtures.record("a"), ReminderFixtures.record("b")], state: old) {
            n += 1
            return ReminderFixtures.id(n)
        }
        #expect(next.metadata["a"]?.estimatedMinutes == nil && next.metadata["b"]?.estimatedMinutes == nil)
        #expect(next.metadata["old"]?.estimatedMinutes == 120)
        let moved = try ReminderTaskMapper.reconcile([ReminderFixtures.record("new", list: "other")], state: old) { ReminderFixtures.id(20) }
        #expect(moved.metadata["new"]?.estimatedMinutes == nil)
    }

    @Test func exactIDAndRepeatedReadsKeepTaskIdentity() throws {
        var old = ReminderLocalState()
        old.metadata["r"] = ReminderFixtures.metadata(minutes: 120)
        let next = try ReminderTaskMapper.reconcile([ReminderFixtures.record(title: "変更", deadline: ReminderFixtures.date(20))], state: old)
        #expect(next.metadata["r"]?.taskID == old.metadata["r"]?.taskID)
        #expect(next.metadata["r"]?.estimatedMinutes == 120)
    }

    @Test func repeatedReminderGetsANewWorkIdentityForNextOccurrence() throws {
        var old = ReminderLocalState()
        old.metadata["r"] = ReminderFixtures.metadata(minutes: 90, occurrence: "first")
        let same = try ReminderTaskMapper.reconcile([ReminderFixtures.record(recurring: true, occurrence: "first")], state: old)
        #expect(same.metadata["r"]?.taskID == ReminderFixtures.id(1))
        let next = try ReminderTaskMapper.reconcile([ReminderFixtures.record(recurring: true, occurrence: "second")], state: old) { ReminderFixtures.id(2) }
        #expect(next.metadata["r"]?.taskID == ReminderFixtures.id(2))
        #expect(next.metadata["r"]?.estimatedMinutes == 90)
        #expect(ReminderTaskMapper.task(for: ReminderFixtures.record(recurring: true), metadata: ReminderFixtures.metadata()) == nil)
    }

    @Test func duplicateLocalIDsRejectTheEntireSnapshot() {
        #expect(throws: ReminderServiceError.invalidSnapshot) {
            try ReminderTaskMapper.reconcile([ReminderFixtures.record(), ReminderFixtures.record()], state: ReminderLocalState())
        }
    }

    @Test func reusedLocalIDWithDifferentExternalIdentityStartsUnconfigured() throws {
        var old = ReminderLocalState()
        old.metadata["r"] = ReminderFixtures.metadata(minutes: 120)
        let next = try ReminderTaskMapper.reconcile([ReminderFixtures.record(external: "different")], state: old) { ReminderFixtures.id(2) }
        #expect(next.metadata["r"]?.taskID == ReminderFixtures.id(2))
        #expect(next.metadata["r"]?.estimatedMinutes == nil)
    }

    @Test func emptyExternalIdentifierCannotMigrateAnAssociation() throws {
        var old = ReminderLocalState()
        old.metadata["old"] = ReminderFixtures.metadata(minutes: 120, external: "")
        let next = try ReminderTaskMapper.reconcile([ReminderFixtures.record("new", external: "")], state: old) { ReminderFixtures.id(2) }
        #expect(next.metadata["new"]?.estimatedMinutes == nil)
        #expect(next.metadata["old"]?.estimatedMinutes == 120)
    }
}
