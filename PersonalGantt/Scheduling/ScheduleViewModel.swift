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
    private(set) var calendarAuthorization: CalendarAuthorization = .notDetermined
    private(set) var calendarMessage: String?
    private(set) var isLoadingCalendars = false
    private(set) var lastCalendarRefresh: Date?
    private(set) var planningInterval: DateInterval?
    private(set) var protectedConflictCount = 0

    @ObservationIgnored private var calendarProvider: (any CalendarProviding)?
    @ObservationIgnored private var activitySettings = ActivitySettings.default
    @ObservationIgnored private var calendar = Calendar.current
    @ObservationIgnored private var clock: () -> Date = { Date() }
    @ObservationIgnored private var archivedTitles: [UUID: String] = [:]

    init(tasks: [Task], availableSlots: [AvailableSlot]) {
        self.tasks = tasks
        self.availableSlots = availableSlots
        self.result = Scheduler().schedule(tasks: tasks, availableSlots: availableSlots)
    }

    convenience init() {
        let sample = SampleSchedule.make()
        self.init(tasks: sample.tasks, calendarProvider: CalendarService())
    }

    convenience init(
        tasks: [Task], calendarProvider: any CalendarProviding,
        activitySettings: ActivitySettings = .default, calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.init(tasks: tasks, availableSlots: [])
        self.calendarProvider = calendarProvider
        self.activitySettings = activitySettings
        self.calendar = calendar
        self.clock = clock
        self.calendarAuthorization = calendarProvider.authorization
        do {
            let now = clock()
            planningInterval = try AvailabilityService().planningInterval(referenceDate: now, settings: activitySettings, calendar: calendar)
            availableSlots = try AvailabilityService().availableSlots(fixedEvents: [], settings: activitySettings, referenceDate: now, calendar: calendar)
            recalculate()
        } catch {
            calendarMessage = error.localizedDescription
        }
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
            result = ScheduleReplanner().schedule(tasks: tasks, availableSlots: availableSlots, previousBlocks: result.blocks, now: now)
            updateProtectedConflicts(now: now)
        }
    }

    var availabilityDescription: String {
        if selectedCalendarIDs.isEmpty {
            return "カレンダー未反映。活動可能時間のみで配置しています。"
        }
        return "\(selectedCalendarIDs.count)個のカレンダー・\(fixedEvents.count)件の固定予定を反映しています。"
    }

    /// Only inspect existing authorization at launch; never prompt automatically.
    func loadCalendarState() {
        guard let calendarProvider else { return }
        calendarAuthorization = calendarProvider.authorization
        if calendarAuthorization == .fullAccess { refreshCalendars() }
    }

    func requestCalendarAccess() async {
        guard let calendarProvider, !isLoadingCalendars else { return }
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        do {
            calendarAuthorization = try await calendarProvider.requestAccess()
            guard calendarAuthorization == .fullAccess else {
                calendarMessage = calendarAuthorization.description
                return
            }
            try readCalendarSnapshot(selection: selectedCalendarIDs)
        } catch {
            calendarAuthorization = calendarProvider.authorization
            calendarMessage = "読み込みに失敗しました。現在の予定を保持します。\n\(error.localizedDescription)"
        }
    }

    func refreshCalendars() {
        guard let calendarProvider, !isLoadingCalendars else { return }
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        calendarAuthorization = calendarProvider.authorization
        guard calendarAuthorization == .fullAccess else {
            calendarMessage = calendarAuthorization.description + " 現在の予定を保持しています。"
            return
        }
        do { try readCalendarSnapshot(selection: selectedCalendarIDs) }
        catch { calendarMessage = "読み込みに失敗しました。現在の予定を保持します。\n\(error.localizedDescription)" }
    }

    @discardableResult
    func applyCalendarSelection(_ selection: Set<String>) -> Bool {
        guard let calendarProvider, !isLoadingCalendars else { return false }
        calendarAuthorization = calendarProvider.authorization
        guard calendarAuthorization == .fullAccess else {
            calendarMessage = calendarAuthorization.description
            return false
        }
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        do {
            try readCalendarSnapshot(selection: selection)
            return true
        } catch {
            calendarMessage = "読み込みに失敗しました。現在の予定を保持します。\n\(error.localizedDescription)"
            return false
        }
    }

    /// Publish only after calendar lookup, event lookup, and availability all succeed.
    private func readCalendarSnapshot(selection: Set<String>) throws {
        guard let calendarProvider else { return }
        let now = clock()
        let range = try AvailabilityService().planningInterval(referenceDate: now, settings: activitySettings, calendar: calendar)
        let sources = try calendarProvider.loadCalendars()
        let effectiveIDs = selection.intersection(Set(sources.map(\.id)))
        let events = effectiveIDs.isEmpty ? [] : try calendarProvider.loadEvents(in: range, calendarIDs: effectiveIDs)
            .filter { effectiveIDs.contains($0.calendarID) && !$0.isCancelled }
        let slots = try AvailabilityService().availableSlots(fixedEvents: events, settings: activitySettings, referenceDate: now, calendar: calendar)
        let nextResult = ScheduleReplanner().schedule(tasks: tasks, availableSlots: slots, previousBlocks: result.blocks, now: now)
        calendars = sources
        selectedCalendarIDs = effectiveIDs
        fixedEvents = events
        availableSlots = slots
        planningInterval = range
        result = nextResult
        lastCalendarRefresh = now
        calendarMessage = effectiveIDs == selection ? nil : "利用できなくなったカレンダーを選択から除外しました。"
        updateProtectedConflicts(now: now)
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
        // Preserve identity and completion when editing the work requirement.
        tasks[index].title = input.title
        tasks[index].estimatedMinutes = input.estimatedMinutes
        tasks[index].deadline = input.deadline
        recalculate()
    }

    func deleteTask(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        archivedTitles[id] = task.title
        tasks.removeAll { $0.id == id }
        recalculate()
    }

    func toggleCompletion(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isCompleted.toggle()
        recalculate()
    }

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
