import Foundation
import Observation

@MainActor
@Observable
final class ScheduleViewModel {
    private(set) var tasks: [Task]
    private(set) var availableSlots: [AvailableSlot]
    private(set) var result: SchedulingResult
    private(set) var calendars: [CalendarSource] = []
    private(set) var selectedCalendarIDs: Set<String> = []
    private(set) var fixedEvents: [FixedEvent] = []
    private(set) var calendarAuthorization: CalendarAuthorization = .signedOut
    private(set) var calendarMessage: String?
    private(set) var isLoadingCalendars = false
    private(set) var lastCalendarRefresh: Date?
    private(set) var planningInterval: DateInterval?
    private(set) var protectedConflictCount = 0
    private(set) var googleClientID = ""
    private(set) var reminders: ReminderSyncViewModel?
    private(set) var persistenceMessage: String?
    private(set) var lastPlanSave: Date?
    private(set) var isRestoredPlan = false
    private(set) var isPlanStorageBlocked = false
    @ObservationIgnored private var planStore: (any PlanSnapshotStoring)?

    @ObservationIgnored private var calendarProvider: (any CalendarProviding)?
    @ObservationIgnored private var selectionStore: (any CalendarSelectionStoring)?
    @ObservationIgnored private var selectionScope = ""
    @ObservationIgnored private var isApplicationActive = false
    @ObservationIgnored private var automaticRefreshPending = false
    @ObservationIgnored private var automaticRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var hasConfirmedPlan = false
    @ObservationIgnored private var activitySettings = ActivitySettings.default
    @ObservationIgnored private var calendar = Calendar.current
    @ObservationIgnored private var clock: () -> Date = { Date() }
    @ObservationIgnored private var archivedTitles: [UUID: String] = [:]
    @ObservationIgnored private var reminderTaskIDs: Set<UUID> = []

    var presentationCalendar: Calendar { calendar }

    init(tasks: [Task], availableSlots: [AvailableSlot]) {
        self.tasks = tasks
        self.availableSlots = availableSlots
        self.result = Scheduler().schedule(tasks: tasks, availableSlots: availableSlots)
    }

    convenience init() {
        let clientID = UserDefaults.standard.string(forKey: "googleOAuthClientID") ?? ""
        self.init(tasks: [], calendarProvider: GoogleCalendarService.live(clientID: clientID),
                  calendar: .autoupdatingCurrent, selectionStore: UserDefaultsCalendarSelectionStore(),
                  selectionScope: clientID)
        googleClientID = clientID
        attachReminders(provider: EventKitReminderService(), storage: FileReminderMetadataStore.live())
        attachPlanStore(SwiftDataPlanStore.live())
    }

    func attachReminders(provider: any ReminderProviding, storage: any ReminderMetadataStoring) {
        reminders = ReminderSyncViewModel(provider: provider, storage: storage, clock: clock) { [weak self] imported in
            guard let self else { return }
            let newIDs = Set(imported.map(\.id))
            for old in self.tasks where self.reminderTaskIDs.contains(old.id) && !newIDs.contains(old.id) {
                self.archivedTitles[old.id] = old.title
            }
            self.tasks = self.tasks.filter { !self.reminderTaskIDs.contains($0.id) } + imported
            self.reminderTaskIDs = newIDs
            self.recalculate()
        }
    }

    convenience init(
        tasks: [Task], calendarProvider: any CalendarProviding,
        activitySettings: ActivitySettings = .default, calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() },
        selectionStore: (any CalendarSelectionStoring)? = nil, selectionScope: String = "",
        planStore: (any PlanSnapshotStoring)? = nil
    ) {
        self.init(tasks: tasks, availableSlots: [])
        self.calendarProvider = calendarProvider
        self.activitySettings = activitySettings
        self.calendar = calendar
        self.clock = clock
        self.selectionStore = selectionStore
        self.selectionScope = selectionScope
        self.selectedCalendarIDs = selectionStore?.load(clientID: selectionScope) ?? []
        self.calendarAuthorization = calendarProvider.authorization
        do {
            let now = clock()
            planningInterval = try AvailabilityService().planningInterval(referenceDate: now, settings: activitySettings, calendar: calendar)
            availableSlots = try AvailabilityService().availableSlots(fixedEvents: [], settings: activitySettings, referenceDate: now, calendar: calendar)
            recalculate()
        } catch {
            calendarMessage = safeMessage(error)
        }
        if let planStore { attachPlanStore(planStore) }
    }

    /// Restore before lifecycle refreshes. No permission request or remote write occurs here.
    func attachPlanStore(_ store: any PlanSnapshotStoring) {
        planStore = store
        do {
            guard let snapshot = try store.load() else { return }
            try snapshot.validate()
            tasks = snapshot.tasks
            reminderTaskIDs = snapshot.reminderTaskIDs
            archivedTitles = snapshot.archivedTitles
            lastPlanSave = snapshot.savedAt
            isRestoredPlan = true
            // A saved provisional plan can also contain work that has since started.
            hasConfirmedPlan = snapshot.hasConfirmedPlan || !snapshot.blocks.isEmpty
            let sameSource = snapshot.calendarScope == selectionScope &&
                (selectionStore == nil || snapshot.selectedCalendarIDs == selectedCalendarIDs)
            if sameSource {
                result = SchedulingResult(blocks: snapshot.blocks, unscheduledTaskIDs: snapshot.unscheduledTaskIDs)
                availableSlots = snapshot.slots
                calendars = snapshot.calendars
                selectedCalendarIDs = snapshot.selectedCalendarIDs
                fixedEvents = snapshot.fixedEvents
                planningInterval = snapshot.planningStart.flatMap { start in
                    snapshot.planningEnd.map { DateInterval(start: start, end: $0) }
                }
                lastCalendarRefresh = snapshot.lastCalendarRefresh
            } else {
                // Calendar context changed outside this checkpoint: only begun work is safe.
                result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: [],
                    previousBlocks: snapshot.blocks, now: clock())
                availableSlots = []
                calendars = []
                fixedEvents = []
                lastCalendarRefresh = nil
                calendarMessage = "連携設定が変わっています。開始済みの枠を保持し、Googleの再取得を待っています。"
            }
            updateProtectedConflicts(now: clock())
        } catch {
            // Never turn unreadable or newer data into an empty replacement store.
            isPlanStorageBlocked = true
            persistenceMessage = storageReason(error) + " 復元できていません。以後の変更はこの端末に保存されません。"
        }
    }

    func retryPlanSave() { savePlan() }

    private func savePlan() {
        guard let planStore, !isPlanStorageBlocked else { return }
        let snapshot = PlanSnapshot(savedAt: clock(), tasks: tasks, reminderTaskIDs: reminderTaskIDs,
            blocks: result.blocks, unscheduledTaskIDs: result.unscheduledTaskIDs, archivedTitles: archivedTitles,
            slots: availableSlots, calendars: calendars, selectedCalendarIDs: selectedCalendarIDs, fixedEvents: fixedEvents,
            planningStart: planningInterval?.start, planningEnd: planningInterval?.end,
            lastCalendarRefresh: lastCalendarRefresh, hasConfirmedPlan: hasConfirmedPlan, calendarScope: selectionScope)
        do {
            try planStore.save(snapshot)
            lastPlanSave = snapshot.savedAt
            persistenceMessage = nil
        } catch {
            persistenceMessage = storageReason(error) + " 最新の変更は未保存です。アプリを終了する前に「保存を再試行」してください。"
        }
    }

    private func storageReason(_ error: Error) -> String {
        (error as? PlanStorageError)?.localizedDescription ?? PlanStorageError.unavailable.localizedDescription
    }

    var unscheduledTasks: [Task] {
        result.unscheduledTaskIDs.compactMap { id in tasks.first { $0.id == id } }
    }

    func recalculate() {
        if calendarProvider == nil {
            // Explicit-slot clients and existing tests retain their pure scheduler API.
            result = Scheduler().schedule(tasks: tasks, availableSlots: availableSlots)
        } else {
            let now = clock()
            result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: availableSlots, previousBlocks: hasConfirmedPlan ? result.blocks : [], now: now)
            updateProtectedConflicts(now: now)
        }
        savePlan()
    }

    var availabilityDescription: String {
        if isRestoredPlan { return "前回保存した計画を表示中。連携の最新取得を待っています。" }
        if lastCalendarRefresh == nil {
            return selectedCalendarIDs.isEmpty
                ? "カレンダー未反映。活動可能時間のみで仮配置しています。"
                : "保存したカレンダーを読み込み待ちです。現在は仮配置です。"
        }
        if selectedCalendarIDs.isEmpty {
            return "カレンダー未選択。活動可能時間のみで配置しています。"
        }
        return "\(selectedCalendarIDs.count)個のカレンダー・\(fixedEvents.count)件の固定予定を反映しています。"
    }

    /// Only inspect existing authorization at launch; never prompt automatically.
    func loadCalendarState() async {
        guard let calendarProvider else { return }
        calendarAuthorization = calendarProvider.authorization
        if calendarAuthorization == .connected {
            await refreshCalendars()
        } else if hasConfirmedPlan {
            calendarMessage = calendarAuthorization.description + " 現在の予定を保持しています。"
        }
    }

    /// Called only by the visible application's scene lifecycle; never starts OAuth.
    func applicationDidBecomeActive() async {
        guard !isApplicationActive else { return }
        isApplicationActive = true
        if isLoadingCalendars {
            automaticRefreshPending = true
            await withCheckedContinuation { automaticRefreshWaiters.append($0) }
            guard isApplicationActive, !_Concurrency.Task.isCancelled else { return }
            if automaticRefreshPending {
                automaticRefreshPending = false
                await loadCalendarState()
            }
            await reminders?.loadState()
            return
        }
        await reminders?.loadState()
        await loadCalendarState()
        if lastCalendarRefresh == nil && !isRestoredPlan && calendarAuthorization != .connected {
            rebuildProvisionalAvailability()
        }
    }

    func applicationDidBecomeInactive() { isApplicationActive = false }

    /// The foreground UI sleeps until this calendar boundary, including DST days.
    var nextPlanningDay: Date {
        let now = clock()
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
    }

    func refreshForDayChangeIfNeeded() async {
        guard isApplicationActive else { return }
        let now = clock()
        guard planningInterval?.start != calendar.startOfDay(for: now) else { return }
        await reminders?.loadState()
        if isLoadingCalendars {
            automaticRefreshPending = true
            return
        }
        if calendarProvider?.authorization == .connected {
            await refreshCalendars()
        } else if lastCalendarRefresh == nil && !isRestoredPlan {
            rebuildProvisionalAvailability()
        } else {
            calendarAuthorization = calendarProvider?.authorization ?? .signedOut
            calendarMessage = calendarAuthorization.description + " 現在の予定を保持しています。"
        }
        // An unavailable provider must not replace a previously confirmed snapshot.
    }

    func requestCalendarAccess() async {
        _ = await updateCalendars(selection: nil, requestAccess: true)
    }

    func refreshCalendars() async {
        _ = await updateCalendars(selection: nil)
    }

    /// Exercises token renewal without asking for additional permissions.
    func verifyCalendarConnection() async {
        _ = await updateCalendars(selection: nil, validateConnection: true)
    }

    @discardableResult
    func applyCalendarSelection(_ selection: Set<String>) async -> Bool {
        await updateCalendars(selection: selection)
    }

    private func updateCalendars(
        selection: Set<String>?, requestAccess: Bool = false, validateConnection: Bool = false
    ) async -> Bool {
        guard calendarProvider != nil, !isLoadingCalendars else { return false }
        isLoadingCalendars = true
        automaticRefreshPending = false
        defer {
            isLoadingCalendars = false
            let waiters = automaticRefreshWaiters
            automaticRefreshWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let succeeded = await updateSnapshot(
            selection: selection ?? selectedCalendarIDs,
            requestAccess: requestAccess, validateConnection: validateConnection
        )
        // Coalesce lifecycle changes received during a manual/selection/OAuth fetch.
        // Once inactive or cancelled, only the next activation may trigger a new request.
        while automaticRefreshPending && isApplicationActive && !_Concurrency.Task.isCancelled {
            automaticRefreshPending = false
            _ = await updateSnapshot(selection: selectedCalendarIDs)
        }
        return succeeded
    }

    private func updateSnapshot(
        selection: Set<String>, requestAccess: Bool = false, validateConnection: Bool = false
    ) async -> Bool {
        guard let provider = calendarProvider else { return false }
        calendarAuthorization = provider.authorization
        do {
            if requestAccess { calendarAuthorization = try await provider.requestAccess() }
            guard calendarAuthorization == .connected else {
                calendarMessage = calendarAuthorization.description + " 現在の予定を保持しています。"
                return false
            }
            if validateConnection { try await provider.validateConnection() }
            try await readCalendarSnapshot(selection: selection)
            return true
        } catch {
            calendarAuthorization = provider.authorization
            calendarMessage = "読み込みに失敗しました。現在の予定を保持します。\n\(safeMessage(error))"
            return false
        }
    }

    /// Publish only after all retrieval succeeds and its range still matches today's range.
    private func readCalendarSnapshot(selection: Set<String>) async throws {
        guard let calendarProvider else { return }
        for _ in 0..<2 {
            let requestTime = clock()
            let range = try AvailabilityService().planningInterval(referenceDate: requestTime, settings: activitySettings, calendar: calendar)
            let sources = try await calendarProvider.loadCalendars()
            let effectiveIDs = selection.intersection(Set(sources.map(\.id)))
            let events = effectiveIDs.isEmpty ? [] : try await calendarProvider.loadEvents(in: range, calendarIDs: effectiveIDs)
                .filter { effectiveIDs.contains($0.calendarID) && !$0.isCancelled }
            try _Concurrency.Task.checkCancellation()
            let now = clock()
            let currentRange = try AvailabilityService().planningInterval(referenceDate: now, settings: activitySettings, calendar: calendar)
            guard range == currentRange else { continue }
            let slots = try AvailabilityService().availableSlots(fixedEvents: events, settings: activitySettings, referenceDate: now, calendar: calendar)
            let previous = hasConfirmedPlan ? result.blocks : []
            let nextResult = ScheduleReplanner().schedule(tasks: tasks, availableSlots: slots, previousBlocks: previous, now: now)
            calendars = sources
            selectedCalendarIDs = effectiveIDs
            fixedEvents = events
            availableSlots = slots
            planningInterval = range
            result = nextResult
            hasConfirmedPlan = true
            lastCalendarRefresh = now
            isRestoredPlan = false
            calendarMessage = effectiveIDs == selection ? nil : "利用できなくなったカレンダーを選択から除外しました。"
            calendarAuthorization = calendarProvider.authorization
            updateProtectedConflicts(now: now)
            selectionStore?.save(effectiveIDs, clientID: selectionScope)
            savePlan()
            return
        }
        throw CalendarServiceError.planningPeriodChanged
    }

    private func rebuildProvisionalAvailability() {
        do {
            let now = clock()
            let service = AvailabilityService()
            let range = try service.planningInterval(referenceDate: now, settings: activitySettings, calendar: calendar)
            let slots = try service.availableSlots(fixedEvents: [], settings: activitySettings, referenceDate: now, calendar: calendar)
            planningInterval = range
            availableSlots = slots
            recalculate()
        } catch { calendarMessage = safeMessage(error) }
    }

    @discardableResult
    func configureGoogleClientID(_ input: String) -> Bool {
        guard !isLoadingCalendars else { return false }
        let clientID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GoogleOAuthConfiguration(clientID: clientID).isValid else {
            calendarMessage = GoogleCalendarError.configuration.localizedDescription
            return false
        }
        guard calendarAuthorization != .connected else {
            calendarMessage = "クライアントIDを変更する前にGoogleからログアウトしてください。"
            return false
        }
        if clientID != selectionScope {
            selectionStore?.clear(clientID: selectionScope)
            selectionScope = clientID
            selectedCalendarIDs = []
            calendars = []
            fixedEvents = []
            lastCalendarRefresh = nil
            isRestoredPlan = false
            // Old account availability cannot become a cache for the new account.
            rebuildProvisionalAvailability()
        }
        googleClientID = clientID
        UserDefaults.standard.set(clientID, forKey: "googleOAuthClientID")
        calendarProvider = GoogleCalendarService.live(clientID: clientID)
        calendarAuthorization = calendarProvider?.authorization ?? .signedOut
        calendarMessage = nil
        savePlan()
        return true
    }

    func disconnectGoogle() {
        guard !isLoadingCalendars, let provider = calendarProvider as? GoogleCalendarService else { return }
        do {
            try provider.disconnect()
            selectionStore?.clear(clientID: selectionScope)
            automaticRefreshPending = false
            calendarAuthorization = provider.authorization
            calendars = []
            selectedCalendarIDs = []
            fixedEvents = []
            let protected = hasConfirmedPlan ? result.blocks : []
            lastCalendarRefresh = nil
            let now = clock()
            planningInterval = try AvailabilityService().planningInterval(referenceDate: now, settings: activitySettings, calendar: calendar)
            availableSlots = try AvailabilityService().availableSlots(fixedEvents: [], settings: activitySettings, referenceDate: now, calendar: calendar)
            result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: availableSlots, previousBlocks: protected, now: now)
            updateProtectedConflicts(now: now)
            isRestoredPlan = false
            calendarMessage = "端末のGoogle認証情報を削除しました。活動可能時間のみで配置しています。"
            savePlan()
        } catch { calendarMessage = safeMessage(error) }
    }

    private func safeMessage(_ error: Error) -> String {
        if let known = error as? GoogleCalendarError { return known.localizedDescription }
        if let known = error as? CalendarServiceError { return known.localizedDescription }
        if let known = error as? AvailabilityError { return known.localizedDescription }
        return "読み込みに失敗しました。現在の予定を保持します。"
    }

    private func updateProtectedConflicts(now: Date) {
        let occupied = AvailabilityService().occupiedIntervals(fixedEvents, calendar: calendar)
        protectedConflictCount = result.blocks.filter { block in
            block.start <= now && now < block.end && occupied.contains { $0.start < block.end && block.start < $0.end }
        }.count
    }

    @discardableResult
    func addTask(_ draft: TaskDraft) throws -> Task {
        let input = try draft.validated()
        let task = Task(title: input.title, estimatedMinutes: input.estimatedMinutes, deadline: input.deadline)
        tasks.append(task)
        recalculate()
        return task
    }

    func updateTask(id: UUID, draft: TaskDraft) throws {
        let input = try draft.validated()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskInputError.taskNotFound
        }
        if reminderTaskIDs.contains(id) {
            guard let reminders, let identifier = tasks[index].reminderIdentifier,
                  let record = reminders.record(for: identifier)
            else { throw ReminderServiceError.reminderUnavailable }
            guard input.title == tasks[index].title,
                  record.deadline == nil || input.deadline == tasks[index].deadline
            else { throw ReminderServiceError.sourceOwnedFields }
            try reminders.configure(identifier: identifier, estimatedMinutesText: draft.estimatedMinutesText,
                                    deadlineOverride: record.deadline == nil ? input.deadline : nil)
            return
        }
        // Preserve identity and completion when editing the work requirement.
        tasks[index].title = input.title
        tasks[index].estimatedMinutes = input.estimatedMinutes
        tasks[index].deadline = input.deadline
        recalculate()
    }

    func deleteTask(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if reminderTaskIDs.contains(id) {
            if let identifier = task.reminderIdentifier, let reminders, reminders.record(for: identifier) != nil {
                _ = reminders.exclude(identifier: identifier)
            }
            return
        }
        archivedTitles[id] = task.title
        tasks.removeAll { $0.id == id }
        recalculate()
    }

    func toggleCompletion(id: UUID) {
        guard !reminderTaskIDs.contains(id) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isCompleted.toggle()
        recalculate()
    }

    func toggleTaskCompletion(id: UUID) async {
        if reminderTaskIDs.contains(id), let identifier = tasks.first(where: { $0.id == id })?.reminderIdentifier {
            await reminders?.toggleCompletion(identifier: identifier)
        } else {
            toggleCompletion(id: id)
        }
    }

    func isReminderTask(_ id: UUID) -> Bool { reminderTaskIDs.contains(id) }

    /// Replace generated availability when fixed events change, then rebuild the plan.
    func updateAvailableSlots(_ slots: [AvailableSlot]) {
        availableSlots = slots
        recalculate()
    }

    func title(for taskID: UUID) -> String {
        tasks.first { $0.id == taskID }?.title ?? archivedTitles[taskID] ?? "削除済みのタスク"
    }

    func scheduledMinutes(for taskID: UUID) -> Double {
        result.blocks.filter { $0.taskID == taskID }.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Unallocated estimate, not a record of completed work.
    func unallocatedMinutes(for task: Task) -> Double {
        guard !task.isCompleted else { return 0 }
        return max(0, Double(task.estimatedMinutes) - scheduledMinutes(for: task.id))
    }
}
