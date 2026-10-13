import Foundation
import Observation

@MainActor
@Observable
final class ScheduleViewModel {
    /// App-target intents and every window must use the same checkpoint owner.
    static let shared = ScheduleViewModel()

    private(set) var tasks: [Task]
    private(set) var writebackState = WritebackState()
    private(set) var writebackMessage: String?
    private(set) var isPublishing = false
    @ObservationIgnored private var writebackProvider: (any CalendarWritebackProviding)?
    @ObservationIgnored private var writebackPending = false
    private(set) var schedulingSettings = SchedulingSettings.default
    private(set) var workloadSettings = WorkloadSettings.unlimited
    private(set) var routines: [Routine] = []
    private(set) var workSessions: [WorkSession] = []
    private(set) var activeWorkSession: ActiveWorkSession?
    private(set) var workSessionMessage: String?
    private(set) var syncState = SyncState()
    private(set) var localSync: LocalSyncTransport?
    private(set) var syncMessage: String?
    private(set) var isSyncing = false
    @ObservationIgnored private var syncPending = false
    @ObservationIgnored private var syncTransport: (any SyncTransport)?
    private(set) var availableSlots: [AvailableSlot]
    private(set) var result: SchedulingResult
    private(set) var calendars: [CalendarSource] = []
    private(set) var selectedCalendarIDs: Set<String> = []
    private(set) var fixedEvents: [FixedEvent] = []
    private(set) var calendarAuthorization: CalendarAuthorization = .signedOut
    private(set) var calendarMessage: String?
    private(set) var calendarRefreshFailed = false
    private(set) var isLoadingCalendars = false
    private(set) var lastCalendarRefresh: Date?
    private(set) var planningInterval: DateInterval?
    private(set) var planningHorizon: PlanningHorizon?
    private(set) var calendarCoverage: CalendarCoverage?
    let horizonSettings = PlanningHorizonSettings.default
    private(set) var lastRecalculation: Date?
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
    @ObservationIgnored private var initialActivitySettings = ActivitySettings.default
    @ObservationIgnored private var lastAvailabilitySettings: ActivitySettings?
    var activitySettings: ActivitySettings { schedulingSettings.activitySettings ?? initialActivitySettings }
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
        configureLocalSync()
    }

    func attachReminders(provider: any ReminderProviding, storage: any ReminderMetadataStoring) {
        reminders = ReminderSyncViewModel(provider: provider, storage: storage, clock: clock,
            onMetadataChanged: { [weak self] value in
                guard let self else { throw ReminderServiceError.localStorage }
                guard self.planStore != nil else { return false }
                try self.setReminderSyncMetadata(value); return true
            }) { [weak self] imported in
                self?.receiveReminderTasks(imported)
                self?.recalculate()
            }
        _ = reminders?.applySynchronizedMetadata(Array(syncState.records.values))
    }
    private func receiveReminderTasks(_ imported: [Task]) {
        if let mappings = reminders?.transferTaskIDs, !mappings.isEmpty {
            remapTransferredBlocks(mappings)
        }
        let newIDs = Set(imported.map(\.id))
        for old in tasks where reminderTaskIDs.contains(old.id) && !newIDs.contains(old.id) {
            archivedTitles[old.id] = old.title
        }
        var priorities = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.priority) })
        var deferred = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in task.notBefore.map { (task.id, $0) } })
        for (source, target) in reminders?.transferTaskIDs ?? [:] {
            if let priority = priorities[source] { priorities[target] = priority }
            if let bound = deferred[source] { deferred[target] = bound }
        }
        let importedWithPriorities = imported.map { task in
            var value = task; value.priority = priorities[task.id] ?? .normal; value.notBefore = deferred[task.id]; return value
        }
        tasks = tasks.filter { !reminderTaskIDs.contains($0.id) } + importedWithPriorities
        reminderTaskIDs = newIDs
    }
    private func setReminderSyncMetadata(_ value: ReminderSyncMetadata) throws {
        do {
            try value.validate()
            var next = syncState
            next.captureValue(kind: .reminderMetadata, id: value.id, payload: try SyncState.payloadData(value), now: clock())
            guard let record = next.records["reminderMetadata_" + value.id] else { throw SyncError.invalidData }
            try applyLocalSyncRecords([record])
            localSync?.localRecordsDidChange()
        } catch { throw ReminderServiceError.localStorage }
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
        self.writebackProvider = (calendarProvider as? GoogleCalendarService)?.makeWritebackService()
        self.initialActivitySettings = activitySettings
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
            _ = reminders?.applySynchronizedMetadata(Array(syncState.records.values))
            writebackState = snapshot.writebackState ?? WritebackState()
            schedulingSettings = snapshot.schedulingSettings ?? .default
            workSessions = snapshot.workSessions ?? []
            activeWorkSession = snapshot.activeWorkSession
            reminderTaskIDs = snapshot.reminderTaskIDs
            archivedTitles = snapshot.archivedTitles
            lastPlanSave = snapshot.savedAt
            isRestoredPlan = true
            // A saved provisional plan can also contain work that has since started.
            hasConfirmedPlan = snapshot.hasConfirmedPlan || !snapshot.blocks.isEmpty
            let sameSource = snapshot.calendarScope == selectionScope &&
                (selectionStore == nil || snapshot.selectedCalendarIDs == selectedCalendarIDs)
            if sameSource {
                result = SchedulingResult(blocks: snapshot.blocks, unscheduledTaskIDs: snapshot.unscheduledTaskIDs, fixedRoutineConflicts: snapshot.fixedRoutineConflicts ?? [])
                availableSlots = snapshot.slots
                lastAvailabilitySettings = activitySettings
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
                    previousBlocks: snapshot.blocks, now: clock(), workloadSettings: workloadSettings, calendar: calendar, workSessions: effectiveWorkSessions, distributionMode: schedulingSettings.distributionMode, optimizationSettings: schedulingSettings, activitySettings: activitySettings, fixedEvents: fixedEvents, globalExclusionsApplied: calendarProvider != nil, calendarCoverage: calendarCoverage, requiresCalendarCoverage: calendarProvider != nil && !selectedCalendarIDs.isEmpty, planningRange: (try? resolveHorizon(now: clock()))?.interval)
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
        let previous = syncState.records
        captureSyncChanges()
        guard let planStore, !isPlanStorageBlocked else { return }
        let snapshot = currentPlanSnapshot()
        do {
            try planStore.save(snapshot)
            lastPlanSave = snapshot.savedAt
            persistenceMessage = nil
            if previous != syncState.records { localSync?.localRecordsDidChange() }
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
            workloadSettings: workloadSettings, routines: routines, calendarCoverage: calendarCoverage, writebackState: writebackState, syncState: syncState, workSessions: workSessions, schedulingSettings: schedulingSettings, activeWorkSession: activeWorkSession, fixedRoutineConflicts: result.fixedRoutineConflicts)
    }

    var canEnableWriteback: Bool { writebackProvider != nil && calendarAuthorization == .connected && !isPlanStorageBlocked && !isBackupRecoveryRequired }
    func attachWritebackProvider(_ provider: any CalendarWritebackProviding) { writebackProvider = provider }
    func enableWriteback() async {
        guard let writebackProvider, !isBackupRecoveryRequired, !isPublishing else { return }
        do {
            try await writebackProvider.authorize()
            if calendarProvider != nil {
                guard await updateCalendars(selection: nil) else { throw WritebackError.network }
            }
            writebackState.enabled = true
            savePlan()
            guard planStore != nil, persistenceMessage == nil, !isPlanStorageBlocked else {
                writebackState.enabled = false; throw PlanStorageError.unavailable
            }
            await publishSchedule()
        } catch { writebackMessage = (error as? LocalizedError)?.errorDescription ?? WritebackError.network.localizedDescription }
    }
    func disableWriteback() {
        guard !isBackupRecoveryRequired else { return }
        writebackState.enabled = false; writebackPending = false; savePlan()
    }
    func resetWritebackDestination() {
        guard !isPublishing, !isBackupRecoveryRequired else { return }
        writebackState = WritebackState(); savePlan()
        writebackMessage = "書き戻しをOFFにしました。次に有効にすると新しい専用Calendarを作成します。以前のCalendarはGoogle側で管理してください。"
    }
    func publishScheduleIfActive() async { if isApplicationActive { await publishSchedule() } }
    func publishSchedule() async {
        guard writebackState.enabled, let writebackProvider, !isBackupRecoveryRequired,
              !isPlanStorageBlocked, persistenceMessage == nil else { return }
        if isPublishing { writebackPending = true; return }
        isPublishing = true
        defer { isPublishing = false }
        repeat {
            writebackPending = false
            let snapshot = result.blocks
            let titles = Dictionary(uniqueKeysWithValues: Set(snapshot.map(\.taskID)).map { ($0, title(for: $0)) })
            do {
                let next = try await writebackProvider.publish(blocks: snapshot, titles: titles, state: writebackState, now: clock(), calendar: calendar)
                guard writebackState.enabled else { return }
                writebackState = next
                writebackMessage = "未来の作業枠をPersonalGantt専用Calendarへ反映しました。"
                savePlan()
            } catch {
                writebackMessage = (error as? LocalizedError)?.errorDescription ?? WritebackError.network.localizedDescription
                return
            }
        } while writebackPending && isApplicationActive && writebackState.enabled && !_Concurrency.Task.isCancelled
    }

    var canEnableLocalSync: Bool { planStore != nil && !isPlanStorageBlocked && !isBackupRecoveryRequired }
    func configureLocalSync(link: (any LocalSyncLink)? = nil, store: (any LocalSyncPreferenceStoring)? = nil) {
        let name = MultipeerLocalLink.deviceName
        localSync = LocalSyncTransport(deviceID: syncState.deviceID, displayName: name,
            link: link ?? AdaptiveLocalLink(deviceID: syncState.deviceID, name: name),
            store: store ?? LocalSyncKeychainPreferences(),
            snapshot: { [weak self] in
                guard let self, self.canEnableLocalSync, self.persistenceMessage == nil else { throw LocalSyncError.storage }
                self.captureSyncChanges()
                return Array(self.syncState.records.values)
            }, apply: { [weak self] incoming in
                guard let self else { throw LocalSyncError.storage }
                try self.applyLocalSyncRecords(incoming)
            })
        if localSync?.preferences.enabled == true { setSyncEnabled(false) }
        #if os(macOS)
        localSync?.setAvailable(canEnableLocalSync)
        #endif
    }
    func setLocalSyncEnabled(_ enabled: Bool) {
        guard canEnableLocalSync else { return }
        savePlan() // Persist the device UUID before exposing a network identity.
        guard persistenceMessage == nil else { return }
        if enabled { setSyncEnabled(false) }
        localSync?.setEnabled(enabled)
    }
    func beginLocalPairing() {
        setLocalSyncEnabled(true)
        guard canEnableLocalSync, persistenceMessage == nil else { return }
        localSync?.beginPairing()
    }
    /// Remote ACKs may be sent only after this complete checkpoint saves.
    /// A failed save rolls back the model synchronously, before UI observers run.
    func applyLocalSyncRecords(_ incoming: [SyncRecord]) throws {
        guard canEnableLocalSync, persistenceMessage == nil else { throw LocalSyncError.storage }
        let before = currentPlanSnapshot(), previousHorizon = planningHorizon
        let previousRecalculation = lastRecalculation, previousAvailability = lastAvailabilitySettings
        let previousConflicts = protectedConflictCount, previousSave = lastPlanSave
        try mergeSyncRecords(incoming)
        guard persistenceMessage == nil else {
            tasks = before.tasks; routines = before.routines ?? []; workSessions = before.workSessions ?? []
            _ = reminders?.applySynchronizedMetadata(Array(before.syncState?.records.values ?? Dictionary<String, SyncRecord>().values))
            activeWorkSession = before.activeWorkSession; workloadSettings = before.workloadSettings ?? .unlimited
            schedulingSettings = before.schedulingSettings ?? .default; syncState = before.syncState ?? SyncState()
            reminderTaskIDs = before.reminderTaskIDs; archivedTitles = before.archivedTitles
            result = SchedulingResult(blocks: before.blocks, unscheduledTaskIDs: before.unscheduledTaskIDs, fixedRoutineConflicts: before.fixedRoutineConflicts ?? [])
            availableSlots = before.slots; planningHorizon = previousHorizon
            planningInterval = previousHorizon?.interval; lastAvailabilitySettings = previousAvailability
            lastRecalculation = previousRecalculation; protectedConflictCount = previousConflicts; lastPlanSave = previousSave
            throw LocalSyncError.storage
        }
    }

    var canEnableSync: Bool { syncTransport != nil && !isPlanStorageBlocked && !isBackupRecoveryRequired }
    func attachSyncTransport(_ transport: any SyncTransport) { syncTransport = transport }
    func setSyncEnabled(_ enabled: Bool) {
        guard !isBackupRecoveryRequired else { return }
        guard !enabled || canEnableSync else { syncMessage = SyncError.unavailable.localizedDescription; return }
        if enabled { localSync?.setEnabled(false) }
        syncState.isEnabled = enabled
        savePlan()
    }
    private func captureSyncChanges() {
        do {
            for value in reminders?.legacySyncMetadata() ?? [] where syncState.records["reminderMetadata_" + value.id] == nil {
                // Unknown migration timestamps must not defeat subsequent explicit edits.
                syncState.captureValue(kind: .reminderMetadata, id: value.id, payload: try SyncState.payloadData(value), now: .distantPast)
            }
            let ordinary = tasks.filter { $0.routineOccurrence == nil && !reminderTaskIDs.contains($0.id) }
            let encodedTasks = try Dictionary(uniqueKeysWithValues: ordinary.map { ($0.id.uuidString, try SyncState.payloadData($0)) })
            let encodedRoutines = try Dictionary(uniqueKeysWithValues: routines.map { ($0.id.uuidString, try SyncState.payloadData($0)) })
            syncState.capture(kind: .task, values: encodedTasks, now: clock())
            syncState.capture(kind: .schedulingSettings, values: ["settings": try SyncState.payloadData(schedulingSettings)],
                now: syncState.records["schedulingSettings_settings"] == nil && schedulingSettings == .default ? .distantPast : clock())
            let encodedSessions = try Dictionary(uniqueKeysWithValues: workSessions.map { ($0.id.uuidString, try SyncState.payloadData($0)) })
            syncState.capture(kind: .workSession, values: encodedSessions, now: clock())
            syncState.capture(kind: .routine, values: encodedRoutines, now: clock())
            syncState.capture(kind: .workload, values: ["settings": try SyncState.payloadData(workloadSettings)],
                now: syncState.records["workload_settings"] == nil && workloadSettings == .unlimited ? .distantPast : clock())
        } catch { syncMessage = SyncError.invalidData.localizedDescription }
    }
    func synchronizeIfActive() async { if isApplicationActive { await synchronize() } }
    func synchronize() async {
        guard syncState.isEnabled, let syncTransport, !isBackupRecoveryRequired, !isPlanStorageBlocked else { return }
        if isSyncing { syncPending = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncPending = false
            captureSyncChanges()
            do {
                let remote = try await syncTransport.exchange(Array(syncState.records.values))
                try _Concurrency.Task.checkCancellation()
                guard syncState.isEnabled, !isBackupRecoveryRequired else { return }
                try mergeSyncRecords(remote)
                syncState.lastSync = clock()
                syncMessage = syncState.conflictKeys.isEmpty ? "iCloud同期を反映しました。" : "競合を検出しました。更新日時の新しい内容を採用しています。"
                savePlan()
            } catch { syncMessage = (error as? SyncError)?.localizedDescription ?? SyncError.network.localizedDescription; return }
        } while syncPending && isApplicationActive && syncState.isEnabled && !_Concurrency.Task.isCancelled
    }
    func acknowledgeSyncConflicts() {
        guard !isBackupRecoveryRequired else { return }
        syncState.conflictKeys = []; savePlan()
    }

    func mergeSyncRecords(_ incoming: [SyncRecord]) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        captureSyncChanges()
        for record in incoming { try SyncPayloadValidator.validate(record) }
        var merged = syncState
        try merged.merge(incoming)
        var ordinary: [Task] = [], nextRoutines: [Routine] = [], nextWorkload = workloadSettings
        var nextSessions: [WorkSession] = []
        var nextScheduling = schedulingSettings
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
            case .workSession:
                let value = try decoder.decode(WorkSession.self, from: data)
                guard value.id.uuidString == record.id, value.end <= clock() else { throw SyncError.invalidData }
                try value.validate(); nextSessions.append(value)
            case .reminderMetadata: break // Validated above; projected against local EventKit below.
            case .schedulingSettings:
                guard record.id == "settings" else { throw SyncError.invalidData }
                nextScheduling = try decoder.decode(SchedulingSettings.self, from: data)
                guard nextScheduling.isValid else { throw SyncError.invalidData }
            }
        }
        for old in tasks where !ordinary.contains(where: { $0.id == old.id }) { archivedTitles[old.id] = old.title }
        tasks = tasks.filter { reminderTaskIDs.contains($0.id) } + ordinary
        schedulingSettings = nextScheduling
        workSessions = nextSessions
        for session in nextSessions { archivedTitles[session.taskID] = session.taskTitle }
        if let activeWorkSession, !tasks.contains(where: { $0.id == activeWorkSession.taskID }) { self.activeWorkSession = nil }
        routines = nextRoutines; workloadSettings = nextWorkload; syncState = merged
        if let imported = reminders?.applySynchronizedMetadata(Array(merged.records.values)) { receiveReminderTasks(imported) }
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
                 routineOccurrence: task.routineOccurrence, priority: task.priority, notBefore: task.notBefore, availabilityExclusions: task.availabilityExclusions)
        }
        next.plan.activeWorkSession = nil
        var sessionsByID = Dictionary(uniqueKeysWithValues: workSessions.map { ($0.id, $0) })
        for var session in backup.plan.workSessions ?? [] { session.taskID = importedID(session.taskID); sessionsByID[session.id] = session }
        next.plan.workSessions = Array(sessionsByID.values).sorted { $0.id.uuidString < $1.id.uuidString }
        next.plan.reminderTaskIDs = Set(backup.plan.reminderTaskIDs.map(importedID))
        next.plan.blocks = backup.plan.blocks.map { block in
            ScheduledBlock(taskID: importedID(block.taskID), start: block.start, end: block.end)
        }
        next.plan.archivedTitles = [:]
        for (id, title) in backup.plan.archivedTitles { next.plan.archivedTitles[importedID(id)] = title }
        for session in next.plan.workSessions ?? [] { next.plan.archivedTitles[session.taskID] = session.taskTitle }
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
        next.plan.writebackState = writebackState // Destination and consent belong to this device.
        next.plan.schedulingSettings = backup.plan.schedulingSettings ?? .default
        next.plan.version = 4
        next.plan.syncState = syncState // Keep this device identity even if restoration is interrupted.
        let restoredMetadata = Array(backup.reminders.metadata.values) + Array(backup.reminders.pendingTransfer?.values ?? Dictionary<String, ReminderTaskMetadata>().values)
        let portableGroups = Dictionary(grouping: restoredMetadata.compactMap { ReminderSyncMetadata(metadata: $0) }, by: \.id)
        // Ambiguous file associations must not become a portable edit on another device.
        for values in portableGroups.values where values.count == 1 {
            let value = values[0]
            next.plan.syncState?.captureValue(kind: .reminderMetadata, id: value.id, payload: try SyncState.payloadData(value), now: clock())
        }
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
        if let hours = next.plan.schedulingSettings?.activitySettings {
            let range = safeRange ?? (next.plan.calendarCoverage == nil && next.plan.selectedCalendarIDs.isEmpty ? restoredHorizon.interval : nil)
            next.plan.slots = try range.map {
                try AvailabilityService().availableSlots(fixedEvents: next.plan.fixedEvents, in: $0, settings: hours, referenceDate: clock(), calendar: calendar)
            } ?? []
        }
        let occurrenceTasks = RoutinePlanner().tasks(for: next.plan.routines ?? [], in: restoredHorizon.interval, calendar: calendar)
        for old in next.plan.tasks where old.routineOccurrence != nil {
            next.plan.archivedTitles[old.id] = old.title
        }
        next.plan.tasks = next.plan.tasks.filter { $0.routineOccurrence == nil } + occurrenceTasks
        let recalculated = ScheduleReplanner().schedule(tasks: next.plan.tasks, availableSlots: next.plan.slots,
            previousBlocks: next.plan.blocks, now: clock(), workloadSettings: next.plan.workloadSettings ?? .unlimited, calendar: calendar, workSessions: next.plan.workSessions ?? [], distributionMode: next.plan.schedulingSettings?.distributionMode ?? .earliestFirst, optimizationSettings: next.plan.schedulingSettings, activitySettings: next.plan.schedulingSettings?.activitySettings, fixedEvents: next.plan.fixedEvents, globalExclusionsApplied: true, calendarCoverage: next.plan.calendarCoverage, requiresCalendarCoverage: !next.plan.selectedCalendarIDs.isEmpty, planningRange: restoredHorizon.interval)
        next.plan.blocks = recalculated.blocks
        next.plan.unscheduledTaskIDs = recalculated.unscheduledTaskIDs
        next.plan.fixedRoutineConflicts = recalculated.fixedRoutineConflicts
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
        let localSync = next.plan.syncState ?? syncState
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
        for index in workSessions.indices { workSessions[index].taskID = resolved(workSessions[index].taskID) }
        if let activeWorkSession { self.activeWorkSession?.taskID = resolved(activeWorkSession.taskID) }
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

    private var effectiveSchedulingSettings: SchedulingSettings {
        var settings = schedulingSettings; settings.activitySettings = activitySettings; return settings
    }

    func recalculate() {
        guard !isBackupRecoveryRequired else { return }
        do {
            let now = clock()
            let horizon = try resolveHorizon(now: now)
            let rebuild = planningInterval != horizon.interval || lastAvailabilitySettings != activitySettings
            planningHorizon = horizon
            planningInterval = horizon.interval
            if calendarProvider != nil {
                if rebuild {
                    // Changed hours and sync settings use cached fixed events immediately.
                    try rebuildPlanningAvailability(now: now)
                } else {
                    let safeRange = calendarCoverage?.intersection(with: horizon.interval)
                        ?? (calendarCoverage == nil && selectedCalendarIDs.isEmpty ? horizon.interval : nil)
                    availableSlots = safeRange.map { clippedSlots(availableSlots, to: $0, now: now) } ?? []
                }
            }
            rebuildRoutineTasks(in: horizon.interval)
        } catch { calendarMessage = safeMessage(error) }
        if calendarProvider == nil {
            // Explicit-slot clients and existing tests retain their pure scheduler API.
            result = ScheduleOptimizationEngine().schedule(OptimizationRequest(tasks: tasks, slots: availableSlots,
                completedMinutes: WorkSession.minutesByTask(effectiveWorkSessions), workload: workloadSettings, settings: effectiveSchedulingSettings, calendar: calendar, fixedEvents: fixedEvents, referenceDate: clock(), planningRange: planningInterval))
        } else {
            let now = clock()
            result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: availableSlots, previousBlocks: hasConfirmedPlan ? result.blocks : [],
                                                 now: now, workloadSettings: workloadSettings, calendar: calendar, workSessions: effectiveWorkSessions, distributionMode: schedulingSettings.distributionMode, optimizationSettings: schedulingSettings, activitySettings: activitySettings, fixedEvents: fixedEvents, globalExclusionsApplied: calendarProvider != nil, calendarCoverage: calendarCoverage, requiresCalendarCoverage: calendarProvider != nil && !selectedCalendarIDs.isEmpty, planningRange: planningInterval)
            updateProtectedConflicts(now: now)
        }
        lastRecalculation = clock()
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
            calendarRefreshFailed = !selectedCalendarIDs.isEmpty
            calendarMessage = calendarAuthorization.description + " 現在の予定を保持しています。"
        }
    }

    /// Called only by the visible application's scene lifecycle; never starts OAuth.
    func applicationDidBecomeActive() async {
        guard !isApplicationActive else { return }
        isApplicationActive = true
        localSync?.setAvailable(canEnableLocalSync)
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
        #if !os(macOS)
        localSync?.setAvailable(false)
        #endif
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
                calendarRefreshFailed = !selection.isEmpty
                calendarMessage = calendarAuthorization.description + " 現在の予定を保持しています。"
                refreshDerivedPeriodAfterFailure()
                return false
            }
            if validateConnection { try await provider.validateConnection() }
            try await readCalendarSnapshot(selection: selection)
            calendarRefreshFailed = false
            return true
        } catch {
            calendarAuthorization = provider.authorization
            calendarRefreshFailed = true
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
            let sources = try await calendarProvider.loadCalendars().filter { $0.id != writebackState.calendarID }
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
                                                        workloadSettings: workloadSettings, calendar: calendar, workSessions: effectiveWorkSessions, distributionMode: schedulingSettings.distributionMode, optimizationSettings: schedulingSettings, activitySettings: activitySettings, fixedEvents: events, globalExclusionsApplied: true, calendarCoverage: CalendarCoverage(start: range.start, end: range.end), requiresCalendarCoverage: !effectiveIDs.isEmpty, planningRange: range)
            calendars = sources
            selectedCalendarIDs = effectiveIDs
            fixedEvents = events
            availableSlots = slots
            lastAvailabilitySettings = activitySettings
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
        writebackState = WritebackState()
        UserDefaults.standard.set(clientID, forKey: "googleOAuthClientID")
        calendarProvider = GoogleCalendarService.live(clientID: clientID)
        writebackProvider = (calendarProvider as? GoogleCalendarService)?.makeWritebackService()
        calendarAuthorization = calendarProvider?.authorization ?? .signedOut
        calendarMessage = nil
        calendarRefreshFailed = false
        savePlan()
        return true
    }

    func disconnectGoogle() {
        calendarRefreshFailed = false
        guard !isLoadingCalendars, let provider = calendarProvider as? GoogleCalendarService else { return }
        do {
            try provider.disconnect()
            selectionStore?.clear(clientID: selectionScope)
            automaticRefreshPending = false
            writebackState = WritebackState()
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
                                                 workloadSettings: workloadSettings, calendar: calendar, workSessions: effectiveWorkSessions, distributionMode: schedulingSettings.distributionMode, optimizationSettings: schedulingSettings, activitySettings: activitySettings, fixedEvents: fixedEvents, globalExclusionsApplied: calendarProvider != nil, calendarCoverage: calendarCoverage, requiresCalendarCoverage: calendarProvider != nil && !selectedCalendarIDs.isEmpty, planningRange: planningInterval)
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
        let task = Task(title: input.title, estimatedMinutes: input.estimatedMinutes, deadline: input.deadline, priority: input.priority, availabilityExclusions: input.availabilityExclusions)
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
                                    deadlineOverride: record.deadline == nil ? input.deadline : nil, availabilityExclusions: input.availabilityExclusions)
            if let newIndex = tasks.firstIndex(where: { $0.id == id }) { tasks[newIndex].priority = input.priority; recalculate() }
            return
        }
        // Preserve identity and completion when editing the work requirement.
        tasks[index].title = input.title
        tasks[index].estimatedMinutes = input.estimatedMinutes
        tasks[index].deadline = input.deadline
        tasks[index].priority = input.priority
        tasks[index].availabilityExclusions = input.availabilityExclusions
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
        if activeWorkSession?.taskID == id { activeWorkSession = nil }
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
    func skipToday(taskID: UUID) {
        guard !isBackupRecoveryRequired, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if tasks[index].routineOccurrence != nil { deleteTask(id: taskID); return }
        tasks[index].notBefore = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock()))
        recalculate()
    }

    private var effectiveWorkSessions: [WorkSession] {
        workSessions.map { session in
            guard let external = session.reminderExternalIdentifier, !external.isEmpty else { return session }
            let records = (reminders?.records ?? []).filter { $0.externalIdentifier == external && $0.occurrenceKey == session.reminderOccurrenceKey }
            guard records.count == 1, let local = tasks.first(where: { $0.reminderIdentifier == records[0].id }) else { return session }
            var mapped = session; mapped.taskID = local.id; return mapped
        }
    }
    func sessions(for taskID: UUID) -> [WorkSession] { effectiveWorkSessions.filter { $0.taskID == taskID } }
    func completedMinutes(for taskID: UUID) -> Double { WorkSession.minutesByTask(effectiveWorkSessions)[taskID] ?? 0 }
    func remainingMinutes(for task: Task) -> Double {
        task.isCompleted ? 0 : max(0, Double(task.estimatedMinutes) - completedMinutes(for: task.id))
    }
    func unallocatedMinutes(for task: Task) -> Double {
        guard !task.isCompleted else { return 0 }
        let planned: Double
        if !sessions(for: task.id).isEmpty {
            planned = result.blocks.filter { $0.taskID == task.id && $0.end > clock() }.reduce(0) { total, block in
                total + (block.start > clock() ? block.durationMinutes : WorkSession.unrecordedMinutes(in: block, sessions: effectiveWorkSessions))
            }
        } else { planned = scheduledMinutes(for: task.id) }
        return max(0, remainingMinutes(for: task) - planned)
    }

    func logWork(taskID: UUID, minutes: Int, endingAt: Date? = nil) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        guard let task = task(for: taskID) else { throw TaskInputError.taskNotFound }
        guard (1...1440).contains(minutes) else { throw WorkSessionError.invalid }
        let end = endingAt ?? clock()
        guard end <= clock() else { throw WorkSessionError.invalid }
        var session = WorkSession(taskID: taskID, taskTitle: task.title,
            start: end.addingTimeInterval(-Double(minutes) * 60), end: end, actualMinutes: minutes)
        if let identifier = task.reminderIdentifier, let record = reminders?.record(for: identifier) {
            session.reminderExternalIdentifier = record.externalIdentifier; session.reminderOccurrenceKey = record.occurrenceKey
        }
        try session.validate()
        workSessions.append(session); recalculate()
    }
    func startWork(taskID: UUID) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        guard task(for: taskID) != nil else { throw TaskInputError.taskNotFound }
        guard activeWorkSession == nil else { throw WorkSessionError.alreadyRunning }
        activeWorkSession = ActiveWorkSession(taskID: taskID, start: clock()); savePlan()
    }
    func finishWork() throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        guard let activeWorkSession else { throw WorkSessionError.noRunningSession }
        let end = clock(), minutes = Int(min(1441, end.timeIntervalSince(activeWorkSession.start) / 60))
        var session = WorkSession(taskID: activeWorkSession.taskID, taskTitle: title(for: activeWorkSession.taskID),
            start: activeWorkSession.start, end: end, actualMinutes: minutes)
        if let identifier = task(for: activeWorkSession.taskID)?.reminderIdentifier, let record = reminders?.record(for: identifier) {
            session.reminderExternalIdentifier = record.externalIdentifier; session.reminderOccurrenceKey = record.occurrenceKey
        }
        try session.validate()
        workSessions.append(session); self.activeWorkSession = nil; recalculate()
    }
    func cancelWorkTimer() {
        guard !isBackupRecoveryRequired else { return }
        activeWorkSession = nil; savePlan()
    }
    func deleteWorkSession(id: UUID) {
        guard !isBackupRecoveryRequired else { return }
        workSessions.removeAll { $0.id == id }; recalculate()
    }


    func setActivitySettings(_ settings: ActivitySettings) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        guard settings.isValid else { throw AvailabilityError.invalidSettings }
        schedulingSettings.activitySettings = settings
        recalculate()
    }

    func setActivityWindow(_ window: ActivityWindow?, on day: Date) throws {
        guard day.timeIntervalSinceReferenceDate.isFinite, day >= .distantPast, day <= .distantFuture else { throw AvailabilityError.invalidDateRange }
        var settings = activitySettings
        settings.dayOverrides[ActivitySettings.dayKey(day, calendar: calendar)] = ActivityDayOverride(window: window)
        try setActivitySettings(settings)
    }

    func clearActivityOverride(on day: Date) throws {
        guard day.timeIntervalSinceReferenceDate.isFinite, day >= .distantPast, day <= .distantFuture else { throw AvailabilityError.invalidDateRange }
        var settings = activitySettings
        settings.dayOverrides.removeValue(forKey: ActivitySettings.dayKey(day, calendar: calendar))
        try setActivitySettings(settings)
    }

    func setLocalOptimization(_ enabled: Bool) {
        guard !isBackupRecoveryRequired else { return }
        schedulingSettings.optimizeLocally = enabled; recalculate()
    }
    func setRestSettings(maximumMinutes: Int?, minimumBreakMinutes: Int?) throws {
        guard !isBackupRecoveryRequired else { throw BackupError.recoveryRequired }
        var value = schedulingSettings
        value.maxContinuousMinutes = maximumMinutes; value.minimumBreakMinutes = minimumBreakMinutes
        guard value.isValid else { throw AvailabilityError.invalidSettings }
        schedulingSettings = value; recalculate()
    }

    func setDistributionMode(_ mode: DistributionMode) {
        guard !isBackupRecoveryRequired else { return }
        schedulingSettings.distributionMode = mode; recalculate()
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
        lastAvailabilitySettings = activitySettings
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
