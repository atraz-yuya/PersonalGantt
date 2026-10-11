import AppIntents
import Foundation

struct AddPersonalGanttTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "タスクを追加"
    static let description = IntentDescription("タスク名・所要時間・締切からタスクを保存し、現在の空き時間で作業予定を再計算します。")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "タスク名", requestValueDialog: "何を追加しますか？")
    var taskTitle: String

    @Parameter(title: "所要時間（分）", requestValueDialog: "何分必要ですか？")
    var estimatedMinutes: Int

    @Parameter(title: "締切", kind: .dateTime, requestValueDialog: "締切はいつですか？")
    var deadline: Date

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$taskTitle)を\(\.$estimatedMinutes)分、\(\.$deadline)締切で追加")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let receipt = try TaskCreationService(model: .shared).create(
                title: taskTitle, estimatedMinutes: estimatedMinutes, deadline: deadline)
            return .result(dialog: IntentDialog(stringLiteral: receipt.dialogText))
        } catch TaskInputError.emptyTitle {
            throw $taskTitle.needsValueError("タスク名を入力してください。")
        } catch TaskInputError.invalidMinutes {
            throw $estimatedMinutes.needsValueError("所要時間は1分以上の整数で入力してください。何分必要ですか？")
        } catch TaskInputError.invalidDeadline {
            throw $deadline.needsValueError("有効な締切日時を指定してください。")
        }
    }
}
