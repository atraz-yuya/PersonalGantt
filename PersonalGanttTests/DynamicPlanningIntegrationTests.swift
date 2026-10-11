import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct DynamicPlanningIntegrationTests {
    private var calendar: Calendar { ReminderFixtures.calendar }
    private var now: Date { ReminderFixtures.date(0) }
    private func day(_ offset: Int, _ hour: Int = 0) -> Date {
        let base = calendar.date(byAdding: .day, value: offset, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }
    private func model(_ provider: HorizonCalendarProvider? = nil,
                       store: (any PlanSnapshotStoring)? = nil, clock: HorizonClock? = nil) -> ScheduleViewModel {
        let value = ScheduleViewModel(tasks: [], calendarProvider: provider ?? HorizonCalendarProvider(), calendar: calendar,
            clock: { clock?.now ?? now }, planStore: store ?? HorizonPlanStore())
        value.configureBackup(reminderStore: MemoryReminderMetadata(), journal: HorizonJournal(), deviceID: UUID())
        return value
    }
    @discardableResult private func add(_ model: ScheduleViewModel, days: Int = 30, minutes: Int = 6000) throws -> PersonalGantt.Task {
        try model.addTask(TaskDraft(title: "合成資格勉強", estimatedMinutesText: String(minutes), deadline: day(days)))
    }
    private func routine(days: Int = 45) -> Routine {
        Routine(title: "合成英語", estimatedMinutesPerDay: 30, startDate: now, endDate: day(days), recurrence: .weekdays)
    }

    @Test(arguments: [30, 120]) func googleRequestsDynamicRangeAcrossEveryPage(days: Int) async throws {
        let http = MockGoogleHTTP()
        http.responses = [
            (200, #"{"items":[{"id":"work","summary":"Synthetic","accessRole":"reader"}]}"#),
            (200, #"{"nextPageToken":"synthetic-page-2","items":[]}"#),
            (200, #"{"items":[{"id":"third-week","summary":"Synthetic","start":{"dateTime":"2026-10-28T08:00:00Z"},"end":{"dateTime":"2026-10-28T23:00:00Z"}}]}"#)
        ]
        let value = ScheduleViewModel(tasks: [], calendarProvider: GoogleCalendarService(tokens: MockGoogleTokens(),
            transport: http, calendar: calendar), calendar: calendar, clock: { now })
        try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        _ = try add(value, days: days, minutes: 9000)
        #expect(await value.applyCalendarSelection(["work"]))
        let formatter = ISO8601DateFormatter()
        let requests = http.requests.filter { $0.url?.path.hasSuffix("/events") == true }
        #expect(requests.count == 2 && http.requests.allSatisfy { $0.httpMethod == "GET" })
        for request in requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first { $0.name == "timeMin" }?.value == formatter.string(from: now))
            #expect(query.first { $0.name == "timeMax" }?.value == formatter.string(from: day(min(days, 90))))
        }
        #expect(value.fixedEvents.count == 1 && value.calendarCoverage?.end == day(min(days, 90)))
        let busy = try #require(value.fixedEvents.first)
        #expect(value.result.blocks.allSatisfy { $0.end <= busy.start || $0.start >= busy.end })
    }

    @Test func manualRefreshFailureAfterMidnightReevaluatesTargetWithoutInventingCoverage() async throws {
        let provider = HorizonCalendarProvider(); let clock = HorizonClock(now); let value = model(provider, clock: clock)
        #expect(await value.applyCalendarSelection(["work"]))
        _ = try add(value, days: 7, minutes: 60)
        let begun = try #require(value.result.blocks.first)
        clock.now = day(1); provider.fail = true
        await value.refreshCalendars()
        #expect(value.planningInterval == DateInterval(start: day(1), end: day(15)))
        #expect(value.calendarCoverage?.interval == DateInterval(start: now, end: day(14)))
        #expect(value.result.blocks.contains(begun) && value.coverageMessage != nil)
    }

    @Test func hundredHoursOverThirtyDaysUsesTwentyDaysAtFiveHours() async throws {
        let provider = HorizonCalendarProvider(); let value = model(provider)
        try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        let work = try add(value)
        #expect(value.planningInterval == DateInterval(start: now, end: day(30)))
        #expect(await value.applyCalendarSelection(["work"]))
        #expect(provider.ranges == [DateInterval(start: now, end: day(30))])
        #expect(value.calendarCoverage?.contains(value.planningInterval!) == true)
        #expect(value.scheduledMinutes(for: work.id) == 6000 && value.unallocatedMinutes(for: work) == 0)
        #expect(value.dailyScheduledMinutes.count == 20 && value.dailyScheduledMinutes.values.allSatisfy { $0 <= 300 })
        #expect(value.result.blocks.contains { $0.start >= day(14) })
    }
    @Test func insufficientCapacityIsDistinctFromDeadlineBeyondMaximum() async throws {
        let value = model(); try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 60))
        let work = try add(value, minutes: 6000)
        #expect(await value.applyCalendarSelection(["work"]))
        #expect(value.scheduledMinutes(for: work.id) == 1800 && value.unallocatedMinutes(for: work) == 4200)
        #expect(value.unscheduledReason(for: work) == .dailyWorkloadLimit)
        #expect(value.feasibilityMessage(for: work)?.contains("締切までに") == true)
        try value.updateTask(id: work.id, draft: TaskDraft(title: work.title, estimatedMinutesText: "6000", deadline: day(120)))
        let updated = try #require(value.task(for: work.id))
        #expect(value.planningInterval?.end == day(90) && value.planningHorizon?.wasCapped == true)
        #expect(value.unscheduledReason(for: updated) == .deadlineBeyondPlanningHorizon)
        #expect(value.feasibilityMessage(for: updated)?.contains("判断できません") == true)
        #expect(value.horizonCapMessage != nil)
    }
    @Test func offlineExtensionNeverSchedulesInUnfetchedDaysAndPersistsRequirements() async throws {
        let provider = HorizonCalendarProvider(); let store = HorizonPlanStore(); let value = model(provider, store: store)
        #expect(await value.applyCalendarSelection(["work"]))
        let coverage = try #require(value.calendarCoverage)
        provider.fail = true
        try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        let work = try add(value)
        await value.refreshCalendars()
        #expect(value.planningInterval?.end == day(30) && value.calendarCoverage == coverage)
        #expect(value.result.blocks.allSatisfy { $0.end <= day(14) })
        #expect(value.unallocatedMinutes(for: work) == 1800)
        #expect(value.unscheduledReason(for: work) == .calendarCoveragePending)
        #expect(value.coverageMessage != nil && value.calendarMessage != nil)
        #expect(store.value?.tasks.contains(work) == true && value.persistenceMessage == nil)
        let restored = model(provider, store: store)
        #expect(restored.calendarCoverage == coverage && restored.result == value.result)
        restored.recalculate()
        #expect(restored.result.blocks.allSatisfy { $0.end <= day(14) })
    }
    @Test func successfulRefreshExtendsCoverageAndAvoidsThirdWeekFixedEvent() async throws {
        let provider = HorizonCalendarProvider(); let value = model(provider)
        #expect(await value.applyCalendarSelection(["work"]))
        try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        let work = try add(value, minutes: 9000)
        let busy = FixedEvent(id: "third-week", calendarID: "work", title: "合成固定予定", start: day(21, 8), end: day(21, 23))
        provider.events = [busy]
        await value.refreshCalendars()
        #expect(value.calendarCoverage?.end == day(30) && value.coverageMessage == nil)
        #expect(value.result.blocks.allSatisfy { $0.end <= busy.start || $0.start >= busy.end })
        #expect(value.scheduledMinutes(for: work.id) == 8700 && value.unallocatedMinutes(for: work) == 300)
        #expect(value.dailyScheduledMinutes.values.allSatisfy { $0 <= 300 })
    }
    @Test func deadlineShrinkReplansFutureButPreservesBegunAndReusesWiderCache() async throws {
        let provider = HorizonCalendarProvider(); let clock = HorizonClock(now); let value = model(provider, clock: clock)
        try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        let work = try add(value)
        #expect(await value.applyCalendarSelection(["work"]))
        let begun = try #require(value.result.blocks.first)
        clock.now = day(0, 9)
        try value.updateTask(id: work.id, draft: TaskDraft(title: work.title, estimatedMinutesText: "6000", deadline: day(7)))
        #expect(value.planningInterval?.end == day(14) && value.calendarCoverage?.end == day(30))
        #expect(value.result.blocks.contains(begun))
        #expect(value.result.blocks.filter { $0 != begun }.allSatisfy { $0.end <= day(7) })
        let reads = provider.ranges.count
        try value.updateTask(id: work.id, draft: TaskDraft(title: work.title, estimatedMinutesText: "6000", deadline: day(30)))
        #expect(value.result.blocks.contains(begun) && value.unallocatedMinutes(for: value.task(for: work.id)!) == 0)
        #expect(value.coverageMessage == nil && provider.ranges.count == reads)
    }
    @Test func completionDeletionAndRoutineEditReevaluateHorizon() throws {
        let value = model(); let work = try add(value, days: 60, minutes: 60)
        modelCheck(value, end: day(60))
        modelCheckAfterCompletion(value, work: work)
        var rule = try value.saveRoutine(routine())
        modelCheck(value, end: day(46))
        rule.endDate = day(20); try value.saveRoutine(rule)
        modelCheck(value, end: day(21))
        value.deleteRoutine(id: rule.id); modelCheck(value, end: day(14))
        value.toggleCompletion(id: work.id); modelCheck(value, end: day(60))
        value.deleteTask(id: work.id); modelCheck(value, end: day(14))
    }
    private func modelCheck(_ value: ScheduleViewModel, end: Date) { #expect(value.planningInterval?.end == end) }
    private func modelCheckAfterCompletion(_ value: ScheduleViewModel, work: PersonalGantt.Task) {
        value.toggleCompletion(id: work.id); modelCheck(value, end: day(14))
    }
    @Test func routineAndOrdinaryTaskShareLongRangeAndCapWithoutDuplicateOccurrences() async throws {
        let value = model(); try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        try value.saveRoutine(routine())
        let work = try add(value, minutes: 6000)
        #expect(value.planningInterval?.end == day(46))
        let ids = Set(value.tasks.map(\.id))
        #expect(ids.count == value.tasks.count)
        #expect(value.tasks.contains { ($0.routineOccurrence?.dayStart ?? now) >= day(30) })
        #expect(await value.applyCalendarSelection(["work"]))
        value.recalculate()
        #expect(Set(value.tasks.map(\.id)) == ids)
        #expect(value.dailyScheduledMinutes.values.allSatisfy { $0 <= 300 })
        #expect(value.unallocatedMinutes(for: work) == 0)
    }
    @Test func longRoutineGenerationStopsAtNinetyDaysEvenOffline() async throws {
        let provider = HorizonCalendarProvider(); let value = model(provider)
        #expect(await value.applyCalendarSelection(["work"]))
        provider.fail = true
        var rule = routine(days: 200); rule.recurrence = .daily
        try value.saveRoutine(rule); await value.refreshCalendars()
        #expect(value.tasks.count == 90 && Set(value.tasks.map(\.id)).count == 90)
        #expect(value.tasks.allSatisfy { $0.deadline <= day(90) })
        #expect(value.result.blocks.allSatisfy { $0.end <= day(14) })
        #expect(value.routines == [rule] && value.persistenceMessage == nil)
    }
    @Test func foregroundExtensionFetchesButBackgroundSiriDoesNotRequireNetwork() async throws {
        let provider = HorizonCalendarProvider(); let value = model(provider)
        #expect(await value.applyCalendarSelection(["work"]))
        await value.applicationDidBecomeActive()
        try value.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        _ = try add(value)
        await value.refreshPlanningCoverageIfNeeded()
        #expect(provider.ranges.last?.end == day(30) && value.calendarCoverage?.end == day(30))
        value.applicationDidBecomeInactive(); provider.fail = true
        let reads = provider.ranges.count
        let receipt = try TaskCreationService(model: value).create(title: "合成長期", estimatedMinutes: 12000, deadline: day(60))
        await value.refreshPlanningCoverageIfNeeded()
        #expect(provider.ranges.count == reads && receipt.isScheduleSaved)
        #expect(receipt.dialogText.contains("まだ取得できていません"))
        #expect(value.result.blocks.allSatisfy { $0.end <= day(30) })
    }
    @Test func editDuringFetchRetriesNewHorizonBeforePublishing() async throws {
        let provider = HorizonCalendarProvider(); let value = model(provider)
        let work = try add(value)
        provider.onLoad = {
            provider.onLoad = nil
            try! value.updateTask(id: work.id, draft: TaskDraft(title: work.title, estimatedMinutesText: "6000", deadline: day(60)))
        }
        #expect(await value.applyCalendarSelection(["work"]))
        #expect(provider.ranges.map(\.end) == [day(30), day(60)])
        #expect(value.calendarCoverage?.end == day(60) && value.planningInterval?.end == day(60))
    }
    @Test func backupRestoresIncomingHorizonAndPartialCoverageInsteadOfTargetOldHorizon() async throws {
        let provider = HorizonCalendarProvider(); let source = model(provider)
        #expect(await source.applyCalendarSelection(["work"]))
        try source.setWorkloadSettings(WorkloadSettings(maxScheduledMinutesPerDay: 300))
        _ = try add(source, days: 60)
        try source.saveRoutine(routine())
        let backup = try PersonalGanttBackup.decode(source.makeBackup().encoded())
        #expect(backup.plan.version == 3 && backup.plan.calendarCoverage?.end == day(14))
        let target = model(); #expect(await target.applyCalendarSelection(["work"]))
        try target.restoreBackup(backup)
        #expect(target.planningInterval?.end == day(60) && target.calendarCoverage?.end == day(14))
        #expect(target.tasks == source.tasks && target.result.blocks.allSatisfy { $0.end <= day(14) })
    }
    @Test(arguments: [1, 2]) func legacyBackupInfersOnlyHistoricallyFetchedCoverage(version: Int) async throws {
        let value = model(); #expect(await value.applyCalendarSelection(["work"]))
        var backup = try value.makeBackup()
        backup.plan.version = version; backup.plan.calendarCoverage = nil
        if version == 1 { backup.plan.workloadSettings = nil; backup.plan.routines = nil }
        let target = model(); #expect(await target.applyCalendarSelection(["work"]))
        try target.restoreBackup(PersonalGanttBackup.decode(backup.encoded()))
        #expect(target.calendarCoverage?.end == day(14))
        _ = try add(target)
        #expect(target.result.blocks.allSatisfy { $0.end <= day(14) })
    }
    @Test(arguments: Array(0..<5)) func invalidCoverageAndUnknownVersionsAreRejected(kind: Int) async throws {
        let value = model(); #expect(await value.applyCalendarSelection(["work"]))
        var snapshot = try value.makeBackup().plan
        switch kind {
        case 0: snapshot.calendarCoverage = CalendarCoverage(start: day(30), end: now)
        case 1: snapshot.calendarCoverage = CalendarCoverage(start: now, end: day(1))
        case 2: snapshot.lastCalendarRefresh = nil
        case 3: snapshot.calendarCoverage = CalendarCoverage(start: now, end: Date(timeIntervalSinceReferenceDate: .infinity))
        default: snapshot.version = 999
        }
        #expect(throws: (kind == 4 ? PlanStorageError.unsupportedVersion : .invalidSnapshot)) { try snapshot.validate() }
    }
    @Test func noSlotsAndUnlimitedCapacityShortfallHaveSeparateReasons() async throws {
        let provider = HorizonCalendarProvider(); let value = model(provider)
        let work = try add(value, days: 30, minutes: 100000)
        #expect(await value.applyCalendarSelection(["work"]))
        #expect(value.unscheduledReason(for: work) == .insufficientCapacityBeforeDeadline)
        provider.events = [FixedEvent(id: "all-busy", calendarID: "work", title: "合成占有", start: now, end: day(30))]
        await value.refreshCalendars()
        #expect(value.unscheduledReason(for: work) == .noAvailability && value.scheduledMinutes(for: work.id) == 0)
    }
    @Test func offlineDayChangeMovesTargetButRetainsCoverageAndBegunBlocks() async throws {
        let provider = HorizonCalendarProvider(); let clock = HorizonClock(now); let value = model(provider, clock: clock)
        try value.saveRoutine(routine())
        #expect(await value.applyCalendarSelection(["work"]))
        await value.applicationDidBecomeActive()
        let block = try #require(value.result.blocks.first)
        let coverage = value.calendarCoverage
        provider.fail = true; clock.now = day(1)
        await value.refreshForDayChangeIfNeeded()
        #expect(value.planningInterval?.start == day(1) && value.calendarCoverage == coverage)
        #expect(value.result.blocks.contains(block))
        #expect(value.result.blocks.filter { $0.start > clock.now }.allSatisfy { $0.end <= day(46) })
        #expect(value.persistenceMessage == nil)
    }
    @Test func swiftDataReopenRetainsCoverageWhenHorizonWasExtendedWithoutFetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plan.store")
        let value = model(store: try SwiftDataPlanStore(url: url))
        #expect(await value.applyCalendarSelection(["work"]))
        _ = try add(value)
        let restored = model(store: try SwiftDataPlanStore(url: url))
        #expect(restored.planningInterval?.end == day(30) && restored.calendarCoverage?.end == day(14))
        #expect(restored.result == value.result && restored.coverageMessage != nil)
    }
}

@MainActor private final class HorizonClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
@MainActor private final class HorizonPlanStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot }
}
@MainActor private final class HorizonJournal: BackupJournalStoring {
    var value: PersonalGanttBackup?
    func load() throws -> PersonalGanttBackup? { value }
    func save(_ backup: PersonalGanttBackup) throws { value = backup }
    func remove() throws { value = nil }
}
@MainActor private final class HorizonCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var ranges: [DateInterval] = []
    var events: [FixedEvent] = []
    var fail = false
    var onLoad: (() -> Void)?
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] {
        if fail { throw GoogleCalendarError.network }
        onLoad?()
        return [CalendarSource(id: "work", title: "合成Calendar", accountTitle: "テスト")]
    }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        ranges.append(range)
        if fail { throw GoogleCalendarError.network }
        return events
    }
}
