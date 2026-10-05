import SwiftUI

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskDraft
    @State private var saveError: String?
    private let isEditing: Bool
    private let onSave: (TaskDraft) throws -> Void

    init(task: Task?, defaultDeadline: Date, onSave: @escaping (TaskDraft) throws -> Void) {
        _draft = State(initialValue: task.map(TaskDraft.init(task:)) ?? TaskDraft(deadline: defaultDeadline))
        isEditing = task != nil
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("作業内容") {
                    TextField("タスク名", text: $draft.title)
                        .accessibilityIdentifier("task-title")
                    TextField("所要時間（分）", text: $draft.estimatedMinutesText)
                        .accessibilityIdentifier("task-minutes")
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    DatePicker(
                        "締切", selection: $draft.deadline,
                        in: Date.distantPast...Date.distantFuture,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("task-deadline")
                }

                Section {
                    Text("作業時間は空き時間と締切をもとに自動で決まります。")
                        .foregroundStyle(.secondary)
                    if let message = draft.validationMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("task-validation-error")
                    } else if draft.deadline < Date() {
                        Label("締切が過去のため、配置できない場合があります。", systemImage: "exclamationmark.clock")
                            .foregroundStyle(.orange)
                    }
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
                .font(.subheadline)
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "タスクを編集" : "タスクを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(draft.validationMessage != nil)
                        .accessibilityIdentifier("save-task")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 380)
        #endif
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
