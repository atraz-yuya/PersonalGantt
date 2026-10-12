#if DEBUG
import Foundation

/// Isolated data for visual review. Only the explicitly named preview bundle
/// uses this model; it never initializes live providers or the shared store.
@MainActor enum NavigationPreview {
    static func makeModel() -> ScheduleViewModel {
        let calendar = Calendar.current
        let deadline = QuickDeadline.tomorrow.date(reference: Date(), calendar: calendar) ?? Date()
        let model = ScheduleViewModel(tasks: [], calendarProvider: PreviewCalendar(), calendar: calendar)
        model.attachPlanStore(PreviewPlan())
        model.attachReminders(provider: PreviewReminders(deadline: deadline), storage: PreviewMetadata())
        _ = try? model.addTask(TaskDraft(title: "UI確認用の作業", estimatedMinutesText: "60", deadline: deadline))
        return model
    }
}
@MainActor private final class PreviewCalendar: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
@MainActor private final class PreviewPlan: PlanSnapshotStoring {
    var snapshot: PlanSnapshot?
    func load() throws -> PlanSnapshot? { snapshot }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); self.snapshot = snapshot }
}
@MainActor private final class PreviewMetadata: ReminderMetadataStoring {
    var state = ReminderLocalState(selectedListIDs: ["preview"], metadata: [
        "deadline": ReminderTaskMetadata(taskID: UUID(), externalIdentifier: "preview-deadline", listID: "preview", estimatedMinutes: 90)
    ])
    func load() throws -> ReminderLocalState { state }
    func save(_ state: ReminderLocalState) throws { try state.validate(); self.state = state }
}
@MainActor private final class PreviewReminders: ReminderProviding {
    var authorization: ReminderAuthorization = .fullAccess
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
    func requestAccess() async throws -> ReminderAuthorization { authorization }
    func loadLists() async throws -> [ReminderList] {
        [ReminderList(id: "preview", title: "UI確認用", accountTitle: "合成データ", allowsCompletionChanges: false)]
    }
    func loadReminders(listIDs: Set<String>) async throws -> [ReminderRecord] {
        guard listIDs.contains("preview") else { return [] }
        return [record("deadline", title: "資格勉強（UI確認用）", deadline: nil),
                record("minutes", title: "Kaggle（UI確認用）", deadline: deadline),
                record("both", title: "英語（UI確認用）", deadline: nil)]
    }
    private func record(_ id: String, title: String, deadline: Date?) -> ReminderRecord {
        ReminderRecord(id: id, externalIdentifier: "preview-" + id, listID: "preview", title: title,
            deadline: deadline, hasDateOnlyDeadline: false, hasInvalidDeadline: false,
            isCompleted: false, allowsCompletionChanges: false)
    }
    func setCompletion(identifier: String, listID: String, expected: Bool, completed: Bool) async throws -> ReminderRecord {
        throw ReminderServiceError.readOnly
    }
}
#endif
