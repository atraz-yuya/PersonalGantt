import Foundation
import Observation

@MainActor
@Observable
final class ScheduleViewModel {
    /// App-target intents and every window must use the same checkpoint owner.
    static let shared = ScheduleViewModel()

    private(set) var tasks: [Task]
    private(set) var workloadSettings = WorkloadSettings.unlimited
    private(set) var routines: [Routine] = []
    private(set) var syncState = SyncState()
    private(set) var syncMessage: String?
    private(set) var isSyncing = false
    @ObservationIgnored private var syncTransport: (any SyncTransport)?
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
    private(set) var planningHorizon: PlanningHorizon?
    private(set) var calendarCoverage: CalendarCoverage?
    let horizonSettings = PlanningHorizonSettings.default
    private(set) var protectedConflictCount = 0
    private(set) var googleClientID = ""
    private(set) var reminders: ReminderSyncViewModel?
    private(set) var persistenceMessage: String?
    private(set) var lastPlanSave: Date?
    private(set) var isRestoredPlan = false
    private(set) var isPlanStorageBlocked = false
    private(set) var backupMessage: String?
    private(set) var isBackupRecoveryRequired = false
    @ObservationIgnored private var planStore: (any PlanSnapshotStoring)?
    @ObservationIgnored private var backupReminderStore: (any ReminderMetadataStoring)?
    @ObservationIgnored private var backupJournal: (any BackupJournalStoring)?
    @ObservationIgnored private var backupDeviceID = UUID()

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
    var schedulingReferenceDate: Date { clock() }

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
        syncTransport = CloudKitSyncTransport.configured()
        googleClientID = clientID
        let reminderStore = FileReminderMetadataStore.live()
        let planStore = SwiftDataPlanStore.live()
        let journal = FileBackupJournal.live()
        do {
            try BackupRestoration.recover(planStore: planStore, reminderStore: reminderStore, journal: journal)
            attachReminders(provider: EventKitReminderService(), storage: reminderStore)
            attachPlanStore(planStore)
        } catch {
            isBackupRecoveryRequired = true
            backupMessage = BackupError.recoveryRequired.localizedDescription
            attachReminders(provider: EventKitReminderService(), storage: LockedReminderStore())
            attachPlanStore(LockedPlanStore())
        }
        let deviceID = UserDefaults.standard.string(forKey: "backupDeviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(deviceID.uuidString, forKey: "backupDeviceID")
        configureBackup(reminderStore: reminderStore, journal: journal, deviceID: deviceID)
    }

    func attachReminders(provider: any ReminderProviding, storage: any ReminderMetadataStoring) {
        reminders = ReminderSyncViewModel(provider: provider, storage: storage, clock: clock) { [weak self] imported in
            guard let self else { return }
            if let mappings = self.reminders?.transferTaskIDs, !mappings.isEmpty {
                self.remapTransferredBlocks(mappings)
            }
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
            try rebuildPlanningAvailability(now: now)
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
            workloadSettings = snapshot.workloadSettings ?? .unlimited
            routines = snapshot.routines ?? []
            syncState = snapshot.syncState ?? SyncState()
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
                calendarCoverage = snapshot.resolvedCalendarCoverage
            } else {
                // Calendar context changed outside this checkpoint: only begun work is safe.
                result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: [],
                    previousBlocks: snapshot.blocks, now: clock(), workloadSettings: workloadSettings, calendar: calendar)
                availableSlots = []
                calendars = []
                fixedEvents = []
                lastCalendarRefresh = nil
                calendarCoverage = nil
                calendarMessage = "連携設定が変わっています。開始済みの枠を保持し、Googleの再取得を待っています。"
            }
            let horizon = try resolveHorizon(now: clock())
            planningHorizon = horizon
            planningInterval = horizon.interval
            updateProtectedConflicts(now: clock())
        } catch {
            // Never turn unreadable or newer data into an empty replacement store.
            isPlanStorageBlocked = true
            persistenceMessage = storageReason(error) + " 復元できていません。以後の変更はこの端末に保存されません。"
        }
    }

    func retryPlanSave() { savePlan() }

    private func savePlan() {
        captureSyncChanges()
        guard let planStore, !isPlanStorageBlocked else { return }
        let snapshot = currentPlanSnapshot()
        do {
            try planStore.save(snapshot)
            lastPlanSave = snapshot.savedAt
            persistenceMessage = nil
        } catch {
            persistenceMessage = storageReason(error) + " 最新の変更は未保存です。アプリを終了する前に「保存を再試行」してください。"
        }
    }

    private func currentPlanSnapshot() -> PlanSnapshot {
        PlanSnapshot(version: 4, savedAt: clock(), tasks: tasks, reminderTaskIDs: reminderTaskIDs,
            blocks: result.blocks, unscheduledTaskIDs: result.unscheduledTaskIDs, archivedTitles: archivedTitles,
            slots: availableSlots, calendars: calendars, selectedCalendarIDs: selectedCalendarIDs, fixedEvents: fixedEvents,
            planningStart: planningInterval?.start, planningEnd: planningInterval?.end,
            lastCalendarRefresh: lastCalendarRefresh, hasConfirmedPlan: hasConfirmedPlan, calendarScope: selectionScope,
            workloadSettings: workloadSettings, routines: routines, calendarCoverage: calendarCoverage, syncState: syncState)
    }

    var canEnableSync: Bool { syncTransport != nil }
    func attachSyncTransport(_ transport: any SyncTransport) { syncTransport = transport }
    func setSyncEnabled(_ enabled: Bool) {
        guard !enabled || canEnableSync else { syncMessage = SyncError.unavailable.localizedDescription; return }
        syncState.isEnabled = enabled
        savePlan()
    }
    private func captureSyncChanges() {
        do {
            let ordinary = tasks.filter { $0.routineOccurrence == nil && !reminderTaskIDs.contains($0.id) }
            let encodedTasks = try Dictionary(uniqueKeysWithValues: ordinary.map { ($0.id.uuidString, try SyncState.payloadData($0)) })
            let encodedRoutines = try Dictionary(uniqueKeysWithValues: routines.map { ($0.id.uuidString, try SyncState.payloadData($0)) })
            syncState.capture(kind: .task, values: encodedTasks, now: clock())
            syncState.capture(kind: .routine, values: encodedRoutines, now: clock())
            syncState.capture(kind: .workload, values: ["settings": try SyncState.payloadData(workloadSettings)],
                now: syncState.records["workload_settings"] == nil && workloadSettings == .unlimited ? .distantPast : clock())
        } catch { syncMessage = SyncError.invalidData.localizedDescription }
    }
    func synchronizeIfActive() async { if isApplicationActive { await synchronize() } }
    func synchronize() async {
        guard syncState.isEnabled, let syncTransport, !isSyncing, !isBackupRecoveryRequired else { return }
        isSyncing = true
        defer { isSyncing = false }
        captureSyncChanges()
        do {
            let remote = try await syncTransport.exchange(Array(syncState.records.values))
            try _Concurrency.Task.checkCancellation()
            try mergeSyncRecords(remote)
            syncState.lastSync = clock()
            syncMessage = syncState.conflictKeys.isEmpty ? "iCloud同期を反映しました。" : "競合を検出しました。更新日時の新しい内容を採用しています。"
            savePlan()
        } catch { syncMessage = (error as? SyncError)?.localizedDescription ?? SyncError.network.localizedDescription }
    }
    func mergeSyncRecords(_ incoming: [SyncRecord]) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        captureSyncChanges()
        var merged = syncState
        try merged.merge(incoming)
        var ordinary: [Task] = [], nextRoutines: [Routine] = [], nextWorkload = workloadSettings
        let decoder = JSONDecoder()
        for record in merged.records.values.sorted(by: { $0.key < $1.key }) {
            guard let data = record.payload else { continue }
            switch record.kind {
            case .task:
                let value = try decoder.decode(Task.self, from: data)
                guard value.id.uuidString == record.id, value.routineOccurrence == nil, value.reminderIdentifier == nil,
                      (try? TaskDraft(task: value).validated()) != nil else { throw SyncError.invalidData }
                ordinary.append(value)
            case .routine:
                let value = try decoder.decode(Routine.self, from: data)
                guard value.id.uuidString == record.id else { throw SyncError.invalidData }; try value.validate()
                nextRoutines.append(value)
            case .workload:
                guard record.id == "settings" else { throw SyncError.invalidData }
                nextWorkload = try decoder.decode(WorkloadSettings.self, from: data); try nextWorkload.validate()
            case .workSession, .schedulingSettings: break
            }
        }
        for old in tasks where !ordinary.contains(where: { $0.id == old.id }) { archivedTitles[old.id] = old.title }
        tasks = tasks.filter { reminderTaskIDs.contains($0.id) } + ordinary
        routines = nextRoutines; workloadSettings = nextWorkload; syncState = merged
        recalculate()
    }

    func configureBackup(reminderStore: any ReminderMetadataStoring, journal: any BackupJournalStoring, deviceID: UUID) {
        backupReminderStore = reminderStore; backupJournal = journal; backupDeviceID = deviceID
    }

    var canUseBackup: Bool {
        planStore != nil && !isPlanStorageBlocked && !isBackupRecoveryRequired &&
            !isLoadingCalendars && !(reminders?.isLoading ?? false) && (reminders?.isStorageAvailable ?? true)
    }

    func makeBackup() throws -> PersonalGanttBackup {
        guard canUseBackup else { throw BackupError.unavailable }
        let value = PersonalGanttBackup(createdAt: clock(), sourceDeviceID: backupDeviceID,
            plan: currentPlanSnapshot(), reminders: try reminders?.backupState() ?? ReminderLocalState())
        try value.validate()
        return value
    }

    /// Called only after the user previews and explicitly accepts the chosen file.
    func restoreBackup(_ backup: PersonalGanttBackup) throws {
        guard canUseBackup, let planStore, let backupReminderStore, let backupJournal else { throw BackupError.unavailable }
        try backup.validate()
        _ = try planStore.load() // Do not overwrite a store that became unreadable after launch.
        try backupReminderStore.load().validate()
        let before = try makeBackup()
        let native = reminders?.records ?? []
        let transfer = try ReminderTransferMapper.importState(backup.reminders, into: before.reminders,
            sameDevice: backup.sourceDeviceID == backupDeviceID, records: native)
        func importedID(_ source: UUID) -> UUID {
            var current = source
            var visited: Set<UUID> = []
            while let next = backup.reminders.transferAliases?[current], visited.insert(current).inserted { current = next }
            return transfer.taskIDs[current] ?? current
        }
        var next = backup
        next.sourceDeviceID = backupDeviceID
        next.reminders = transfer.state
        next.plan.savedAt = clock()
        next.plan.tasks = backup.plan.tasks.map { task in
            Task(id: importedID(task.id), title: task.title, isCompleted: task.isCompleted,
                 estimatedMinutes: task.estimatedMinutes, deadline: task.deadline,
                 reminderIdentifier: task.reminderIdentifier.map { transfer.reminderIDs[$0] ?? $0 },
                 routineOccurrence: task.routineOccurrence)
        }
        next.plan.reminderTaskIDs = Set(backup.plan.reminderTaskIDs.map(importedID))
        next.plan.blocks = backup.plan.blocks.map { block in
            ScheduledBlock(taskID: importedID(block.taskID), start: block.start, end: block.end)
        }
        next.plan.archivedTitles = [:]
        for (id, title) in backup.plan.archivedTitles { next.plan.archivedTitles[importedID(id)] = title }
        let protected = result.blocks.filter { $0.start <= clock() }
        for block in protected { next.plan.archivedTitles[block.taskID] = title(for: block.taskID) }
        var seen: Set<ScheduledBlock.ID> = []
        next.plan.blocks = (protected + next.plan.blocks).filter { seen.insert($0.id).inserted }
        let sameCalendar = backup.plan.calendarScope == selectionScope && backup.plan.selectedCalendarIDs == selectedCalendarIDs
        next.plan.calendarScope = selectionScope
        next.plan.selectedCalendarIDs = selectedCalendarIDs
        if !sameCalendar {
            next.plan.slots = []; next.plan.fixedEvents = []; next.plan.calendars = []
            next.plan.lastCalendarRefresh = nil
            next.plan.planningStart = planningInterval?.start; next.plan.planningEnd = planningInterval?.end
        }
        next.plan.calendarCoverage = sameCalendar ? backup.plan.resolvedCalendarCoverage : nil
        next.plan.version = 4
        next.plan.syncState = syncState // Keep this device identity even if restoration is interrupted.
        next.plan.workloadSettings = backup.plan.workloadSettings ?? .unlimited
        next.plan.routines = backup.plan.routines ?? []
        let restoredHorizon = try PlanningHorizonResolver().resolve(now: clock(), tasks: next.plan.tasks,
            routines: next.plan.routines ?? [], settings: horizonSettings, calendar: calendar)
        next.plan.planningStart = restoredHorizon.start; next.plan.planningEnd = restoredHorizon.end
        // Clip imported availability to its actual fetched range and the new target.
        let safeRange = next.plan.calendarCoverage?.intersection(with: restoredHorizon.interval)
        if next.plan.calendarCoverage != nil || !next.plan.selectedCalendarIDs.isEmpty {
            next.plan.slots = safeRange.map { clippedSlots(next.plan.slots, to: $0, now: clock()) } ?? []
        } else { next.plan.slots = clippedSlots(next.plan.slots, to: restoredHorizon.interval, now: clock()) }
        let occurrenceTasks = RoutinePlanner().tasks(for: next.plan.routines ?? [], in: restoredHorizon.interval, calendar: calendar)
        for old in next.plan.tasks where old.routineOccurrence != nil {
            next.plan.archivedTitles[old.id] = old.title
        }
        next.plan.tasks = next.plan.tasks.filter { $0.routineOccurrence == nil } + occurrenceTasks
        let recalculated = ScheduleReplanner().schedule(tasks: next.plan.tasks, availableSlots: next.plan.slots,
            previousBlocks: next.plan.blocks, now: clock(), workloadSettings: next.plan.workloadSettings ?? .unlimited, calendar: calendar)
        next.plan.blocks = recalculated.blocks
        next.plan.unscheduledTaskIDs = recalculated.unscheduledTaskIDs
        next.plan.hasConfirmedPlan = backup.plan.hasConfirmedPlan || !next.plan.blocks.isEmpty
        try next.validate()
        do {
            try BackupRestoration.replace(with: next, previous: before, planStore: planStore,
                reminderStore: backupReminderStore, journal: backupJournal)
        } catch let error as BackupError {
            if error == .recoveryRequired {
                isBackupRecoveryRequired = true
                isPlanStorageBlocked = true
                reminders?.blockAfterInterruptedRestore()
            }
            backupMessage = error.localizedDescription
            throw error
        }
        reminders?.adoptRestoredState(next.reminders)
        let localSync = syncState
        attachPlanStore(planStore)
        syncState = localSync
        savePlan()
        let begun = result.blocks.filter { $0.start <= clock() }
        let overlaps = begun.enumerated().contains { index, block in
            begun.dropFirst(index + 1).contains { $0.start < block.end && block.start < $0.end }
        }
        backupMessage = "ファイルのTask・設定・履歴を読み込みました。開始済みの端末内の時間枠は保持しています。" +
            (overlaps ? " 保持した履歴に重複する時間枠があります。Ganttで確認してください。" : "")
    }

    private func remapTransferredBlocks(_ mappings: [UUID: UUID]) {
        func resolved(_ source: UUID) -> UUID {
            var current = source
            var visited: Set<UUID> = []
            while let next = mappings[current], visited.insert(current).inserted { current = next }
            return current
        }
        var seen: Set<ScheduledBlock.ID> = []
        result.blocks = result.blocks.map { block in
            ScheduledBlock(taskID: resolved(block.taskID), start: block.start, end: block.end)
        }.filter { seen.insert($0.id).inserted }
        for (source, target) in mappings {
            archivedTitles[resolved(target)] = title(for: source)
        }
    }

    private func storageReason(_ error: Error) -> String {
        (error as? PlanStorageError)?.localizedDescription ?? PlanStorageError.unavailable.localizedDescription
    }

    var unscheduledTasks: [Task] {
        result.unscheduledTaskIDs.compactMap { id in tasks.first { $0.id == id } }
    }

    func recalculate() {
        guard !isBackupRecoveryRequired else { return }
        do {
            let now = clock()
            let horizon = try resolveHorizon(now: now)
            let periodChanged = planningInterval != horizon.interval
            planningHorizon = horizon
            planningInterval = horizon.interval
            if calendarProvider != nil {
                if periodChanged { try rebuildPlanningAvailability(now: now) }
                else {
                    let safeRange = calendarCoverage?.intersection(with: horizon.interval)
                        ?? (calendarCoverage == nil && selectedCalendarIDs.isEmpty ? horizon.interval : nil)
                    availableSlots = safeRange.map { clippedSlots(availableSlots, to: $0, now: now) } ?? []
                }
            }
            rebuildRoutineTasks(in: horizon.interval)
        } catch { calendarMessage = safeMessage(error) }
        if calendarProvider == nil {
            // Explicit-slot clients and existing tests retain their pure scheduler API.
            result = Scheduler().schedule(tasks: tasks, availableSlots: availableSlots,
                                          workloadSettings: workloadSettings, calendar: calendar)
        } else {
            let now = clock()
            result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: availableSlots, previousBlocks: hasConfirmedPlan ? result.blocks : [],
                                                 now: now, workloadSettings: workloadSettings, calendar: calendar)
            updateProtectedConflicts(now: now)
        }
        savePlan()
    }

    var availabilityDescription: String {
        if let coverageMessage { return coverageMessage }
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
            recalculate()
            return
        }
        await reminders?.loadState()
        await synchronize()
        await loadCalendarState()
        if lastCalendarRefresh == nil && !isRestoredPlan && calendarAuthorization != .connected {
            rebuildProvisionalAvailability()
        }
        recalculate()
    }

    func applicationDidBecomeInactive() {
        isApplicationActive = false
        BackgroundCalendarRefresh.scheduleNext()
    }

    func performBackgroundRefresh() async {
        defer { BackgroundCalendarRefresh.scheduleNext() }
        guard !_Concurrency.Task.isCancelled else { return }
        await loadCalendarState()
    }

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
        // Roll routine requirements forward even offline, using only retained availability.
        recalculate()
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
                refreshDerivedPeriodAfterFailure()
                return false
            }
            if validateConnection { try await provider.validateConnection() }
            try await readCalendarSnapshot(selection: selection)
            return true
        } catch {
            calendarAuthorization = provider.authorization
            calendarMessage = "読み込みに失敗しました。現在の予定を保持します。\n\(safeMessage(error))"
            refreshDerivedPeriodAfterFailure()
            return false
        }
    }

    private func refreshDerivedPeriodAfterFailure() {
        if (try? resolveHorizon(now: clock()).interval) != planningInterval { recalculate() }
    }

    /// Publish only after all retrieval succeeds and its range still matches the requirements.
    private func readCalendarSnapshot(selection: Set<String>) async throws {
        guard let calendarProvider else { return }
        for _ in 0..<2 {
            let requestTime = clock()
            let range = try resolveHorizon(now: requestTime).interval
            let sources = try await calendarProvider.loadCalendars()
            let effectiveIDs = selection.intersection(Set(sources.map(\.id)))
            let events = effectiveIDs.isEmpty ? [] : try await calendarProvider.loadEvents(in: range, calendarIDs: effectiveIDs)
                .filter { effectiveIDs.contains($0.calendarID) && !$0.isCancelled }
            try _Concurrency.Task.checkCancellation()
            let now = clock()
            let horizon = try resolveHorizon(now: now)
            let currentRange = horizon.interval
            guard range == currentRange else { continue }
            let slots = try AvailabilityService().availableSlots(fixedEvents: events, in: range, settings: activitySettings, referenceDate: now, calendar: calendar)
            let previous = hasConfirmedPlan ? result.blocks : []
            rebuildRoutineTasks(in: range)
            let nextResult = ScheduleReplanner().schedule(tasks: tasks, availableSlots: slots, previousBlocks: previous, now: now,
                                                        workloadSettings: workloadSettings, calendar: calendar)
            calendars = sources
            selectedCalendarIDs = effectiveIDs
            fixedEvents = events
            availableSlots = slots
            planningInterval = range
            planningHorizon = horizon
            calendarCoverage = CalendarCoverage(start: range.start, end: range.end)
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
            calendarCoverage = nil
            try rebuildPlanningAvailability(now: now)
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
            calendarCoverage = nil
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
            calendarCoverage = nil
            let now = clock()
            try rebuildPlanningAvailability(now: now)
            rebuildRoutineTasks(in: routinePlanningRange)
            result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: availableSlots, previousBlocks: protected, now: now,
                                                 workloadSettings: workloadSettings, calendar: calendar)
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
    func addTask(_ draft: TaskDraft, requirePersistence: Bool = false) throws -> Task {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        let input = try draft.validated()
        let task = Task(title: input.title, estimatedMinutes: input.estimatedMinutes, deadline: input.deadline)
        if requirePersistence {
            // Commit the requirement before scheduling. Siri must never report an
            // in-memory-only addition as saved, or lose it if the plan save fails.
            guard let planStore, !isPlanStorageBlocked else { throw PlanStorageError.unavailable }
            var snapshot = currentPlanSnapshot()
            snapshot.tasks.append(task)
            do {
                try planStore.save(snapshot)
                lastPlanSave = snapshot.savedAt
                persistenceMessage = nil
            } catch {
                throw PlanStorageError.unavailable
            }
        }
        tasks.append(task)
        recalculate()
        return task
    }

    func updateTask(id: UUID, draft: TaskDraft) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        let input = try draft.validated()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw TaskInputError.taskNotFound
        }
        guard tasks[index].routineOccurrence == nil else { throw RoutineInputError.editOccurrence }
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
        guard !isBackupRecoveryRequired else { return }
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if let occurrence = task.routineOccurrence,
           let index = routines.firstIndex(where: { $0.id == occurrence.routineID }) {
            routines[index].completedOccurrenceIDs.remove(id)
            routines[index].skippedOccurrenceIDs.insert(id)
            recalculate()
            return
        }
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
        guard !isBackupRecoveryRequired else { return }
        guard !reminderTaskIDs.contains(id) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let occurrence = tasks[index].routineOccurrence,
           let routineIndex = routines.firstIndex(where: { $0.id == occurrence.routineID }) {
            if !routines[routineIndex].completedOccurrenceIDs.insert(id).inserted {
                routines[routineIndex].completedOccurrenceIDs.remove(id)
            }
            recalculate()
            return
        }
        tasks[index].isCompleted.toggle()
        recalculate()
    }

    func toggleTaskCompletion(id: UUID) async {
        guard !isBackupRecoveryRequired else { return }
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

    func setWorkloadSettings(_ settings: WorkloadSettings) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        try settings.validate()
        workloadSettings = settings
        recalculate()
    }

    @discardableResult
    func saveRoutine(_ value: Routine) throws -> Routine {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        var value = value
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        try value.validate()
        if let index = routines.firstIndex(where: { $0.id == value.id }) {
            // Editing a rule never resurrects already completed or skipped occurrences.
            value.completedOccurrenceIDs = routines[index].completedOccurrenceIDs
            value.skippedOccurrenceIDs = routines[index].skippedOccurrenceIDs
            routines[index] = value
        } else { routines.append(value) }
        recalculate()
        return value
    }

    func deleteRoutine(id: UUID) {
        guard !isBackupRecoveryRequired else { return }
        routines.removeAll { $0.id == id }
        recalculate()
    }

    func resetRoutineSkippedDays(id: UUID) {
        guard !isBackupRecoveryRequired, let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].skippedOccurrenceIDs = []
        recalculate()
    }

    var dailyScheduledMinutes: [Date: Double] {
        DailyWorkload.secondsByDay(blocks: result.blocks, calendar: calendar).mapValues { $0 / 60 }
    }

    var workloadLimitExceededDays: Int {
        guard let limit = workloadSettings.maxScheduledMinutesPerDay else { return 0 }
        return dailyScheduledMinutes.filter { $0.key >= calendar.startOfDay(for: clock()) && $0.value > Double(limit) }.count
    }

    private func resolveHorizon(now: Date) throws -> PlanningHorizon {
        try PlanningHorizonResolver().resolve(now: now, tasks: tasks, routines: routines,
                                             settings: horizonSettings, calendar: calendar)
    }

    private var routinePlanningRange: DateInterval {
        (try? resolveHorizon(now: clock()).interval) ?? DateInterval(start: clock(), duration: 0)
    }

    private func clippedSlots(_ slots: [AvailableSlot], to range: DateInterval, now: Date) -> [AvailableSlot] {
        slots.compactMap { slot in
            let start = max(slot.start, range.start, now), end = min(slot.end, range.end)
            return start < end ? AvailableSlot(id: slot.id, start: start, end: end) : nil
        }
    }

    /// Regenerate only inside the confirmed cache. Shrinking does not destroy
    /// coverage, so later edits can reuse an already fetched wider interval.
    private func rebuildPlanningAvailability(now: Date) throws {
        let horizon = try resolveHorizon(now: now)
        planningHorizon = horizon
        planningInterval = horizon.interval
        let range: DateInterval
        if let calendarCoverage {
            guard let intersection = calendarCoverage.intersection(with: horizon.interval) else {
                availableSlots = []; return
            }
            range = intersection
        } else if selectedCalendarIDs.isEmpty {
            range = horizon.interval // Explicitly provisional without selected Calendars.
        } else {
            availableSlots = []; return
        }
        availableSlots = try AvailabilityService().availableSlots(fixedEvents: fixedEvents, in: range,
            settings: activitySettings, referenceDate: now, calendar: calendar)
    }

    var coverageMessage: String? {
        guard calendarProvider != nil, let range = planningInterval else { return nil }
        if let calendarCoverage, !calendarCoverage.contains(range) {
            return "新しく延長された期間のCalendar情報をまだ取得できていません。取得済みの範囲だけに配置しています。"
        }
        if calendarCoverage == nil && !selectedCalendarIDs.isEmpty {
            return "選択したCalendarの対象期間を未取得です。再読み込みを待っています。"
        }
        return nil
    }

    /// Invoked by the visible UI when the derived interval changes. Siri and
    /// background creation persist/replan synchronously without requiring network.
    func refreshPlanningCoverageIfNeeded() async {
        guard isApplicationActive, calendarProvider?.authorization == .connected,
              let range = planningInterval, calendarCoverage?.contains(range) != true else { return }
        if isLoadingCalendars { automaticRefreshPending = true; return }
        await refreshCalendars()
    }

    private func rebuildRoutineTasks(in range: DateInterval) {
        let generated = RoutinePlanner().tasks(for: routines, in: range, calendar: calendar)
        let newIDs = Set(generated.map(\.id))
        for old in tasks where old.routineOccurrence != nil && !newIDs.contains(old.id) {
            archivedTitles[old.id] = old.title
        }
        tasks = tasks.filter { $0.routineOccurrence == nil } + generated
    }
}
