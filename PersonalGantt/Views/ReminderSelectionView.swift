import SwiftUI

struct ReminderSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let embedded: Bool
    @Bindable var model: ReminderSyncViewModel
    @State private var selection: Set<String>
    @State private var editedRecord: ReminderRecord?
    @State private var showsCompleted = false

    init(model: ReminderSyncViewModel, embedded: Bool = false) {
        self.embedded = embedded
        self.model = model
        _selection = State(initialValue: model.selectedListIDs)
    }

    var body: some View {
        Group {
            if embedded { content } else { NavigationStack { content } }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 600)
        #endif
    }

    private var content: some View {
        List {
            Section("Apple Reminders") {
                Text(model.authorization.description)
                if model.authorization != .fullAccess {
                    Button("Remindersへのアクセスを許可") {
                        _Concurrency.Task { await model.requestAccess() }
                    }
                    .disabled(model.isLoading || !model.isStorageAvailable)
                }
                Text("選んだリストのタスクを読み込み、完了／未完了を同期します。OSのアクセス許可は読み書き一括です。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("所要時間と締切の補完値は、この端末のPersonalGanttに保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.authorization == .fullAccess {
                Section("使用するReminderリスト") {
                    if model.lists.isEmpty { Text("使用できるReminderリストがありません。") }
                    ForEach(model.lists) { list in
                        Toggle(isOn: Binding(
                            get: { selection.contains(list.id) },
                            set: { if $0 { selection.insert(list.id) } else { selection.remove(list.id) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(list.title)
                                Text(list.accountTitle + (list.allowsCompletionChanges ? "" : "・読み取り専用"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(model.isLoading)
                    }
                    Text("選択を変更したら「反映」を押してください。未選択ではReminderを取得しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("選択したリストのReminder") {
                    Toggle("完了済みも表示", isOn: $showsCompleted)
                    ForEach(model.records.filter { showsCompleted || !$0.isCompleted }) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.displayTitle).strikethrough(record.isCompleted)
                                Spacer()
                                if record.isCompleted { Text("完了").foregroundStyle(.secondary) }
                                else if model.isExcluded(record.id) { Text("配置対象外").foregroundStyle(.secondary) }
                                else if model.task(for: record.id) != nil { Text("配置対象").foregroundStyle(.green) }
                                else { Text("入力待ち").foregroundStyle(.orange) }
                            }
                            if let deadline = record.deadline {
                                Text("締切: \(deadline.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(record.hasInvalidDeadline ? "Reminders側の締切が不正です。" : "Reminders側の締切は未設定です。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if model.task(for: record.id) == nil && !model.isExcluded(record.id) {
                                Text(model.waitingDescription(for: record))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Button(model.isExcluded(record.id) ? "所要時間を設定して再び配置する" : "所要時間・締切を設定") {
                                editedRecord = record
                            }.disabled(model.isLoading)
                        }
                    }
                    if model.records.isEmpty { Text("選択したリストにReminderがありません。") }
                }
                Button("Remindersを再読み込み") {
                    _Concurrency.Task { await model.refresh() }
                }.disabled(model.isLoading)
            }
            if model.isLoading { ProgressView("Remindersを読み込み中…") }
            if let message = model.message { Text(message).foregroundStyle(.orange) }
        }
        .navigationTitle("Remindersを選択")
        .onChange(of: model.lists) { _, lists in selection.formIntersection(Set(lists.map(\.id))) }
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(model.isLoading) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("反映") {
                    _Concurrency.Task {
                        if await model.applySelection(selection) {
                            selection = model.selectedListIDs
                        }
                    }
                }.disabled(model.authorization != .fullAccess || model.isLoading || !model.isStorageAvailable)
            }
        }
        .sheet(item: $editedRecord) { record in
            ReminderRequirementsView(record: record, model: model)
        }
    }
}

private struct ReminderRequirementsView: View {
    @Environment(\.dismiss) private var dismiss
    let record: ReminderRecord
    @Bindable var model: ReminderSyncViewModel
    @State private var minutes: String
    @State private var setsDeadline: Bool
    @State private var deadline: Date
    @State private var errorMessage: String?

    init(record: ReminderRecord, model: ReminderSyncViewModel) {
        self.record = record
        self.model = model
        let local = model.metadata(for: record.id)
        _minutes = State(initialValue: local?.estimatedMinutes.map(String.init) ?? "")
        _setsDeadline = State(initialValue: local?.deadlineOverride != nil)
        _deadline = State(initialValue: record.deadline ?? local?.deadlineOverride ?? Date().addingTimeInterval(86_400))
    }

    private var validatedDraft: TaskDraft? {
        guard record.deadline != nil || setsDeadline,
              !record.isRecurring || record.occurrenceKey != nil else { return nil }
        return TaskDraft(title: record.title, estimatedMinutesText: minutes, deadline: record.deadline ?? deadline)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    Text(record.displayTitle).font(.headline)
                    Text("タイトルとReminders側で設定した締切は、Apple Remindersで変更してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let sourceDeadline = record.deadline {
                        Text("締切: \(sourceDeadline.formatted(date: .abbreviated, time: .shortened))")
                    } else if !record.isRecurring {
                        Toggle("締切をPersonalGanttで設定", isOn: $setsDeadline)
                        if setsDeadline {
                            DatePicker("締切", selection: $deadline, in: Date.distantPast...Date.distantFuture,
                                       displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                    if record.isRecurring && record.occurrenceKey == nil {
                        Text("繰り返しReminderは、Reminders側で有効な締切を設定してください。").foregroundStyle(.orange)
                    }
                }
                Section("PersonalGanttの設定") {
                    TextField("所要時間（分）", text: $minutes)
                        .accessibilityIdentifier("reminder-minutes")
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("1分以上の整数を入力してください。開始・終了時刻はSchedulerが決定します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let draft = validatedDraft, let validation = draft.validationMessage {
                        Text(validation).foregroundStyle(.orange)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("配置に必要な入力")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try model.configure(identifier: record.id, estimatedMinutesText: minutes,
                                                deadlineOverride: record.deadline == nil && setsDeadline ? deadline : nil)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }.disabled(validatedDraft?.validationMessage != nil || validatedDraft == nil || model.isLoading)
                    .accessibilityIdentifier("save-reminder-requirements")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 380)
        #endif
    }
}
