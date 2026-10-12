import SwiftUI

struct InputQueueView: View {
    @Bindable var model: ScheduleViewModel
    let onSettings: () -> Void
    var body: some View {
        Group {
            if let reminders = model.reminders {
                List {
                    Section("入力待ち \(model.inputQueueCount)件") {
                        if reminders.waitingRecords.isEmpty {
                            Text(reminders.isLoading ? "読み込み中です。" : "入力待ちはありません。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(reminders.waitingRecords) { record in
                            InputQueueRow(record: record, reminders: reminders, calendar: model.presentationCalendar,
                                reference: model.schedulingReferenceDate, isRecoveryRequired: model.isBackupRecoveryRequired)
                                .padding(.vertical, 8)
                        }
                    }
                    Section {
                        Button("Remindersを更新", systemImage: "arrow.triangle.2.circlepath") {
                            _Concurrency.Task { await reminders.refresh() }
                        }.disabled(reminders.isLoading || !reminders.isStorageAvailable || model.isBackupRecoveryRequired)
                        Button("設定を開く", systemImage: "gearshape", action: onSettings)
                        if reminders.isLoading { ProgressView("入力待ちを読み込み中…") }
                        if let message = reminders.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("入力待ちはありません", systemImage: "checklist")
                } description: {
                    Text("Remindersの使用リストは設定から選択できます。")
                } actions: { Button("設定を開く", action: onSettings) }
            }
        }.navigationTitle("待ち").accessibilityIdentifier("input-queue")
            .environment(\.calendar, model.presentationCalendar)
            .environment(\.timeZone, model.presentationCalendar.timeZone)
    }
}

private struct InputQueueRow: View {
    let record: ReminderRecord
    @Bindable var reminders: ReminderSyncViewModel
    let calendar: Calendar
    let reference: Date
    let isRecoveryRequired: Bool
    @State private var draft: InputQueueDraft
    @State private var errorMessage: String?
    init(record: ReminderRecord, reminders: ReminderSyncViewModel, calendar: Calendar, reference: Date, isRecoveryRequired: Bool) {
        self.record = record; self.reminders = reminders; self.calendar = calendar; self.reference = reference
        self.isRecoveryRequired = isRecoveryRequired
        _draft = State(initialValue: InputQueueDraft(record: record, metadata: reminders.metadata(for: record.id), reference: reference, calendar: calendar))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.displayTitle).font(.headline)
            Text(reminders.waitingDescription(for: record)).font(.caption).foregroundStyle(.secondary)
            LabeledContent("所要時間（分）") {
                TextField("例: 90", text: $draft.minutes)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                    .accessibilityLabel(record.displayTitle + "の所要時間、分")
                    .accessibilityIdentifier("queue-minutes-" + record.id)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            if let source = record.deadline {
                Text("締切: \(source.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if draft.canSetDeadline {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78))], alignment: .leading, spacing: 8) {
                    ForEach(QuickDeadline.allCases) { quick in
                        Button(quick.rawValue) {
                            draft.select(quick, reference: Date(), calendar: calendar)
                        }.buttonStyle(.bordered).lineLimit(1)
                    }
                }.font(.subheadline)
                Button("日付を選ぶ", systemImage: "calendar") { draft.setsDeadline = true }
                    .buttonStyle(.bordered)
                Text("クイック期限は23:59。今週末は日曜です。日時は変更できます。")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.setsDeadline {
                    DatePicker("締切", selection: $draft.deadline, in: Date.distantPast...Date.distantFuture,
                        displayedComponents: [.date, .hourAndMinute])
                        .accessibilityLabel(record.displayTitle + "の締切日時")
                        .accessibilityIdentifier("queue-deadline-" + record.id)
                }
            }
            if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || record.isRecurring && record.occurrenceKey == nil {
                Text("タイトルや繰り返しの締切はApple Remindersで変更してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !draft.minutes.isEmpty, let message = draft.validationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
            Button("保存して配置", systemImage: "checkmark") {
                do { try draft.save(to: reminders); errorMessage = nil }
                catch { errorMessage = error.localizedDescription }
            }.buttonStyle(.borderedProminent)
                .disabled(draft.validationMessage != nil)
                .accessibilityIdentifier("queue-save-" + record.id)
        }
        .disabled(reminders.isLoading || !reminders.isStorageAvailable || isRecoveryRequired)
        .onChange(of: record) { _, value in
            draft = InputQueueDraft(record: value, metadata: reminders.metadata(for: value.id), reference: reference, calendar: calendar)
            errorMessage = nil
        }
    }
}
