import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct ScheduleRefreshTests {
    @Test func launchRestoresSelectionAndWaitsForCoverageBeforePlacingCurrentBlock() async {
        let provider = RefreshCalendarProvider()
        let preferences = MemoryCalendarSelection()
        preferences.save(["work"], clientID: "client")
        let clock = RefreshClock(date(8))
        provider.events = [event(8, 10)]
        let model = model(provider, clock, preferences)
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(model.result.blocks.isEmpty)
        #expect(model.availabilityDescription.contains("未取得"))
        await model.applicationDidBecomeActive()
        #expect(model.result.blocks.first?.start == date(10))
        #expect(model.protectedConflictCount == 0)
        #expect(provider.requestedIDs == [["work"]])
        #expect(provider.accessRequests == 0)
        #expect(!model.availabilityDescription.contains("仮配置"))
    }

    @Test func selectionRestoresInANewModelAfterSuccessfulApply() async {
        let provider = RefreshCalendarProvider()
        let preferences = MemoryCalendarSelection()
        let clock = RefreshClock(date(0))
        let first = model(provider, clock, preferences)
        #expect(await first.applyCalendarSelection(["work", "personal"]))
        let secondProvider = RefreshCalendarProvider()
        secondProvider.events = [event(8, 10)]
        let second = model(secondProvider, clock, preferences)
        await second.loadCalendarState()
        #expect(second.selectedCalendarIDs == ["work", "personal"])
        #expect(secondProvider.requestedIDs == [["work", "personal"]])
        #expect(second.result.blocks.first?.start == date(10))
    }

    @Test func failedSelectionAndRefreshRetainPreferencesAndWholeSnapshot() async {
        let provider = RefreshCalendarProvider()
        let preferences = MemoryCalendarSelection()
        let model = model(provider, RefreshClock(date(0)), preferences)
        #expect(await model.applyCalendarSelection(["work"]))
        let oldResult = model.result
        let oldSlots = model.availableSlots
        let oldRange = model.planningInterval
        let oldRefresh = model.lastCalendarRefresh
        let writes = preferences.writes
        provider.failEvents = true
        #expect(!(await model.applyCalendarSelection(["personal"])))
        await model.refreshCalendars()
        #expect(preferences.load(clientID: "client") == ["work"])
        #expect(preferences.writes == writes)
        #expect(model.result == oldResult && model.availableSlots == oldSlots)
        #expect(model.planningInterval == oldRange && model.lastCalendarRefresh == oldRefresh)
        #expect(model.calendarMessage?.contains("保持") == true)
    }

    @Test func missingCalendarIsPrunedAndPrunedSelectionPersists() async {
        let provider = RefreshCalendarProvider()
        let preferences = MemoryCalendarSelection()
        let model = model(provider, RefreshClock(date(0)), preferences)
        #expect(await model.applyCalendarSelection(["work", "personal"]))
        provider.sources.removeAll { $0.id == "personal" }
        await model.refreshCalendars()
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(preferences.load(clientID: "client") == ["work"])
        #expect(model.calendarMessage?.contains("除外") == true)
    }

    @Test func explicitEmptySelectionRestoresWithoutReadingEvents() async {
        let preferences = MemoryCalendarSelection()
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let first = model(provider, clock, preferences)
        #expect(await first.applyCalendarSelection(["work"]))
        #expect(await first.applyCalendarSelection([]))
        let secondProvider = RefreshCalendarProvider()
        let second = model(secondProvider, clock, preferences)
        await second.loadCalendarState()
        #expect(secondProvider.requestedIDs.isEmpty)
        #expect(second.fixedEvents.isEmpty && second.selectedCalendarIDs.isEmpty)
        #expect(!second.availabilityDescription.contains("仮配置"))
    }

    @Test func signedOutLaunchDoesNotPromptOrFetchSavedSelections() async {
        let preferences = MemoryCalendarSelection()
        preferences.save(["work"], clientID: "client")
        let provider = RefreshCalendarProvider()
        provider.authorization = .signedOut
        let model = model(provider, RefreshClock(date(9)), preferences)
        await model.applicationDidBecomeActive()
        #expect(provider.calendarLoads == 0 && provider.accessRequests == 0)
        #expect(model.selectedCalendarIDs == ["work"])
        #expect(model.lastCalendarRefresh == nil)
        #expect(model.availabilityDescription.contains("未取得"))
    }

    @Test func repeatedActiveSignalDoesNotRepeatedlyFetch() async {
        let provider = RefreshCalendarProvider()
        let model = model(provider, RefreshClock(date(0)))
        await model.applicationDidBecomeActive()
        let loads = provider.calendarLoads
        await model.applicationDidBecomeActive()
        #expect(provider.calendarLoads == loads)
        model.applicationDidBecomeInactive()
        await model.applicationDidBecomeActive()
        #expect(provider.calendarLoads == loads + 1)
        #expect(provider.accessRequests == 0)
    }

    @Test func returnToForegroundKeepsPastAndCurrentAndMovesFutureOnly() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let tasks = [
            task(1, 30, date(23)), task(2, 60, date(23)), task(3, 60, date(23))
        ]
        let model = ScheduleViewModel(tasks: tasks, calendarProvider: provider, calendar: utc, clock: { clock.now })
        await model.applicationDidBecomeActive()
        #expect(await model.applyCalendarSelection(["work"]))
        let past = model.result.blocks[0]
        let ongoing = model.result.blocks[1]
        clock.now = date(9)
        model.applicationDidBecomeInactive()
        provider.events = [FixedEvent(id: "changed", calendarID: "work", title: "合成予定",
                                      start: date(8, 45), end: date(12))]
        await model.applicationDidBecomeActive()
        #expect(model.result.blocks.contains(past))
        #expect(model.result.blocks.contains(ongoing))
        #expect(model.result.blocks.first { $0.taskID == tasks[2].id }?.start == date(12))
        #expect(model.protectedConflictCount == 1)
    }

    @Test func dayChangeRegeneratesFourteenDayRangeAndPreservesHistory() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        #expect(await model.applyCalendarSelection(["work"]))
        let past = model.result.blocks[0]
        clock.now = date(0, day: 7)
        await model.refreshForDayChangeIfNeeded()
        #expect(model.planningInterval == DateInterval(start: date(0, day: 7), end: date(0, day: 21)))
        #expect(model.result.blocks.contains(past))
        #expect(model.availableSlots.first?.start == date(8, day: 7))
        #expect(provider.requestedRanges.last == model.planningInterval)
    }

    @Test func sameDayAndInactiveDaySignalsDoNotFetch() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        let loads = provider.calendarLoads
        await model.refreshForDayChangeIfNeeded()
        #expect(provider.calendarLoads == loads)
        model.applicationDidBecomeInactive()
        clock.now = date(0, day: 7)
        await model.refreshForDayChangeIfNeeded()
        #expect(provider.calendarLoads == loads)
        await model.applicationDidBecomeActive()
        #expect(model.planningInterval?.start == date(0, day: 7))
    }

    @Test func dayChangeWithoutAuthorizationOnlyUpdatesProvisionalPlan() async {
        let provider = RefreshCalendarProvider()
        provider.authorization = .signedOut
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        clock.now = date(0, day: 7)
        await model.refreshForDayChangeIfNeeded()
        #expect(model.planningInterval?.start == date(0, day: 7))
        #expect(model.availableSlots.first?.start == date(8, day: 7))
        #expect(provider.calendarLoads == 0 && provider.accessRequests == 0)
    }

    @Test func revokedAuthorizationPreservesCacheAndBegunWorkAtDayChange() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        #expect(await model.applyCalendarSelection(["work"]))
        let before = model.result
        let oldRange = model.planningInterval
        provider.authorization = .signedOut
        clock.now = date(0, day: 7)
        model.applicationDidBecomeInactive()
        await model.applicationDidBecomeActive()
        #expect(model.result == before && model.planningInterval?.start == date(0, day: 7))
        #expect(model.calendarCoverage?.interval == oldRange)
        #expect(model.calendarAuthorization == .signedOut)
        #expect(model.calendarMessage?.contains("保持") == true)
        #expect(provider.accessRequests == 0)
    }

    @Test func midnightDuringFetchRetriesWithCurrentRangeBeforePublishing() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(23, 59))
        let model = model(provider, clock)
        provider.onCalendars = {
            if clock.now == date(23, 59) { clock.now = date(0, day: 7) }
        }
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(provider.requestedRanges == [
            DateInterval(start: date(0), end: date(0, day: 20)),
            DateInterval(start: date(0, day: 7), end: date(0, day: 21))
        ])
        #expect(model.planningInterval == provider.requestedRanges.last)
        #expect(model.lastCalendarRefresh == date(0, day: 7))
    }

    @Test func repeatedlyChangingPeriodCannotPublishPartialSnapshotOrLoopForever() async {
        let provider = RefreshCalendarProvider()
        let preferences = MemoryCalendarSelection()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock, preferences)
        #expect(await model.applyCalendarSelection(["work"]))
        let before = model.result
        let range = model.planningInterval
        let writes = preferences.writes
        let loads = provider.calendarLoads
        provider.onCalendars = { clock.now = clock.now.addingTimeInterval(86_400) }
        await model.refreshCalendars()
        #expect(provider.calendarLoads == loads + 2)
        #expect(model.result == before && model.planningInterval?.start == date(0, day: 8))
        #expect(model.calendarCoverage?.interval == range)
        #expect(preferences.writes == writes)
        #expect(model.calendarMessage?.contains("日付") == true)
    }

    @Test func slowFirstFetchClipsAtPublishTimeAndUsesLatestTaskEdits() async throws {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(8))
        let model = model(provider, clock)
        provider.onCalendars = {
            clock.now = date(9)
            try? model.updateTask(id: model.tasks[0].id,
                draft: TaskDraft(title: "更新済み", estimatedMinutesText: "90", deadline: date(23)))
        }
        #expect(await model.applyCalendarSelection(["work"]))
        #expect(model.result.blocks.first?.start == date(9))
        #expect(model.result.blocks.first?.end == date(10, 30))
        #expect(model.tasks[0].title == "更新済み")
        #expect(model.lastCalendarRefresh == date(9))
    }

    @Test func resumeDuringManualFetchCoalescesWithoutConcurrentRequests() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        #expect(await model.applyCalendarSelection(["work"]))
        provider.pauseNextEventLoad = true
        let refresh = _Concurrency.Task { await model.refreshCalendars() }
        await provider.waitUntilPaused()
        model.applicationDidBecomeInactive()
        let activation = _Concurrency.Task { await model.applicationDidBecomeActive() }
        await _Concurrency.Task.yield()
        provider.events = [event(8, 12)]
        provider.resume()
        await refresh.value
        await activation.value
        #expect(provider.maxConcurrentEventLoads == 1)
        #expect(model.result.blocks.first?.start == date(12))
        #expect(!model.isLoadingCalendars)
        #expect(provider.accessRequests == 0)
    }

    @Test func cancelledFetchCannotSwallowNextActivationOrReplaceSnapshot() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        #expect(await model.applyCalendarSelection(["work"]))
        provider.pauseNextEventLoad = true
        let refresh = _Concurrency.Task { await model.refreshCalendars() }
        await provider.waitUntilPaused()
        refresh.cancel()
        model.applicationDidBecomeInactive()
        let activation = _Concurrency.Task { await model.applicationDidBecomeActive() }
        await _Concurrency.Task.yield()
        provider.events = [event(8, 12)]
        provider.resume()
        await refresh.value
        await activation.value
        #expect(model.result.blocks.first?.start == date(12))
        #expect(model.calendarMessage == nil)
        #expect(provider.maxConcurrentEventLoads == 1)
    }

    @Test func goingInactiveDuringFetchDoesNotDrainAutomaticRefresh() async {
        let provider = RefreshCalendarProvider()
        let clock = RefreshClock(date(0))
        let model = model(provider, clock)
        await model.applicationDidBecomeActive()
        #expect(await model.applyCalendarSelection(["work"]))
        provider.pauseNextEventLoad = true
        let refresh = _Concurrency.Task { await model.refreshCalendars() }
        await provider.waitUntilPaused()
        clock.now = date(0, day: 7)
        await model.refreshForDayChangeIfNeeded()
        model.applicationDidBecomeInactive()
        clock.now = date(0)
        let loads = provider.calendarLoads
        provider.resume()
        await refresh.value
        #expect(provider.calendarLoads == loads)
    }

    @Test func connectionValidationRefreshesSnapshotAndFailureKeepsIt() async {
        let provider = RefreshCalendarProvider()
        let model = model(provider, RefreshClock(date(0)))
        #expect(await model.applyCalendarSelection(["work"]))
        provider.events = [event(8, 12)]
        await model.verifyCalendarConnection()
        #expect(provider.connectionChecks == 1)
        #expect(model.result.blocks.first?.start == date(12))
        let before = model.result
        let loads = provider.calendarLoads
        provider.failConnection = true
        await model.verifyCalendarConnection()
        #expect(model.result == before && provider.calendarLoads == loads)
        #expect(model.calendarMessage?.contains("保持") == true)
    }

    @Test func nextDayRespectsDSTInsteadOfAssumingTwentyFourHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let model = ScheduleViewModel(tasks: [], calendarProvider: RefreshCalendarProvider(), calendar: calendar, clock: { now })
        #expect(model.nextPlanningDay.timeIntervalSince(now) == 23 * 3600)
    }

    private func model(_ provider: RefreshCalendarProvider, _ clock: RefreshClock,
                       _ store: MemoryCalendarSelection? = nil) -> ScheduleViewModel {
        ScheduleViewModel(tasks: [task(1, 120, date(23, day: 9))], calendarProvider: provider,
                          calendar: utc, clock: { clock.now }, selectionStore: store, selectionScope: "client")
    }

    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 6) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func task(_ n: Int, _ minutes: Int, _ deadline: Date) -> PersonalGantt.Task {
        PersonalGantt.Task(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                          title: "合成Task \(n)", estimatedMinutes: minutes, deadline: deadline)
    }
    private func event(_ start: Int, _ end: Int) -> FixedEvent {
        FixedEvent(id: "synthetic", calendarID: "work", title: "合成予定", start: date(start), end: date(end))
    }
}

@MainActor
private final class RefreshClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private final class MemoryCalendarSelection: CalendarSelectionStoring {
    var selections: [String: Set<String>] = [:]
    var writes = 0
    func load(clientID: String) -> Set<String> { selections[clientID] ?? [] }
    func save(_ selection: Set<String>, clientID: String) { selections[clientID] = selection; writes += 1 }
    func clear(clientID: String) { selections.removeValue(forKey: clientID) }
}

@MainActor
private final class RefreshCalendarProvider: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    var sources = [
        CalendarSource(id: "work", title: "合成仕事", accountTitle: "テスト"),
        CalendarSource(id: "personal", title: "合成個人", accountTitle: "テスト")
    ]
    var events: [FixedEvent] = []
    var calendarLoads = 0
    var accessRequests = 0
    var connectionChecks = 0
    var failEvents = false
    var failConnection = false
    var onCalendars: (() -> Void)?
    var requestedIDs: [Set<String>] = []
    var requestedRanges: [DateInterval] = []
    var pauseNextEventLoad = false
    var maxConcurrentEventLoads = 0
    private var concurrentEventLoads = 0
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseObserver: CheckedContinuation<Void, Never>?

    func requestAccess() async throws -> CalendarAuthorization {
        accessRequests += 1
        authorization = .connected
        return authorization
    }
    func loadCalendars() async throws -> [CalendarSource] {
        calendarLoads += 1
        onCalendars?()
        return sources
    }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        requestedIDs.append(calendarIDs)
        requestedRanges.append(range)
        concurrentEventLoads += 1
        maxConcurrentEventLoads = max(maxConcurrentEventLoads, concurrentEventLoads)
        defer { concurrentEventLoads -= 1 }
        if pauseNextEventLoad {
            pauseNextEventLoad = false
            await withCheckedContinuation { continuation in
                paused = continuation
                pauseObserver?.resume()
                pauseObserver = nil
            }
        }
        if failEvents { throw GoogleCalendarError.network }
        return events.filter { calendarIDs.contains($0.calendarID) }
    }
    func validateConnection() async throws {
        connectionChecks += 1
        if failConnection { throw GoogleCalendarError.authentication }
    }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseObserver = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
}
