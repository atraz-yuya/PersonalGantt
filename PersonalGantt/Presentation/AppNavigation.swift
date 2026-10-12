import Foundation

nonisolated enum AppDestination: String, CaseIterable, Identifiable {
    case today, day, tasks, inputQueue, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .today: "今日"
        case .day: "日別"
        case .tasks: "タスク"
        case .inputQueue: "入力待ち"
        case .settings: "設定"
        }
    }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .day: "calendar"
        case .tasks: "checklist"
        case .inputQueue: "clock.badge.questionmark"
        case .settings: "gearshape"
        }
    }
    var isPrimaryTab: Bool { self == .today || self == .day || self == .tasks }
}

nonisolated enum WorkspaceCommand {
    case show(AppDestination), addTask, refreshCalendar, recalculate
}

nonisolated enum QuickDeadline: String, CaseIterable, Identifiable {
    case today = "今日", tomorrow = "明日", weekend = "今週末", threeDays = "3日後", week = "1週間後"
    var id: Self { self }
    func date(reference: Date, calendar: Calendar) -> Date? {
        let offset: Int
        switch self {
        case .today: offset = 0
        case .tomorrow: offset = 1
        case .weekend:
            let weekday = calendar.component(.weekday, from: reference)
            offset = weekday == 1 ? 0 : 8 - weekday
        case .threeDays: offset = 3
        case .week: offset = 7
        }
        guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference)) else { return nil }
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day)
    }
}

/// UI draft only: persisted requirements still pass through ReminderSyncViewModel.configure.
nonisolated struct InputQueueDraft {
    let record: ReminderRecord
    var minutes: String
    var setsDeadline: Bool
    var deadline: Date
    init(record: ReminderRecord, metadata: ReminderTaskMetadata?, reference: Date, calendar: Calendar) {
        self.record = record
        minutes = metadata?.estimatedMinutes.map(String.init) ?? ""
        setsDeadline = metadata?.deadlineOverride != nil
        deadline = record.deadline ?? metadata?.deadlineOverride ?? QuickDeadline.tomorrow.date(reference: reference, calendar: calendar) ?? reference
    }
    var canSetDeadline: Bool { record.deadline == nil && !record.isRecurring }
    var deadlineOverride: Date? { canSetDeadline && setsDeadline ? deadline : nil }
    var validationMessage: String? {
        if record.isRecurring && record.occurrenceKey == nil {
            return "繰り返しReminderの締切はApple Remindersで設定してください。"
        }
        guard let date = record.deadline ?? deadlineOverride else { return TaskInputError.invalidDeadline.localizedDescription }
        return TaskDraft(title: record.title, estimatedMinutesText: minutes, deadline: date).validationMessage
    }
    mutating func select(_ quick: QuickDeadline, reference: Date, calendar: Calendar) {
        guard canSetDeadline, let value = quick.date(reference: reference, calendar: calendar) else { return }
        deadline = value; setsDeadline = true
    }
    @MainActor func save(to model: ReminderSyncViewModel) throws {
        try model.configure(identifier: record.id, estimatedMinutesText: minutes, deadlineOverride: deadlineOverride)
    }
}

nonisolated struct TodayAttention: Identifiable, Equatable {
    let id: String
    let title: String
    let destination: AppDestination
}

@MainActor extension ScheduleViewModel {
    var inputQueueCount: Int { reminders?.waitingRecords.count ?? 0 }
    var inputQueueAccessibilityLabel: String {
        inputQueueCount == 0 ? "入力待ち" : "入力待ち、\(inputQueueCount)件"
    }
    var todayAttention: [TodayAttention] {
        var result: [TodayAttention] = []
        if isBackupRecoveryRequired {
            result.append(TodayAttention(id: "recovery", title: "データの復旧が必要です", destination: .settings))
        } else if persistenceMessage != nil {
            result.append(TodayAttention(id: "save", title: "変更を保存できていません", destination: .settings))
        }
        if calendarRefreshFailed {
            result.append(TodayAttention(id: "calendar", title: "カレンダーを更新できませんでした", destination: .settings))
        }
        if reminders?.lastOperationFailed == true || reminders?.isStorageAvailable == false {
            result.append(TodayAttention(id: "reminders", title: "Remindersを確認してください", destination: .settings))
        }
        return result
    }
}
