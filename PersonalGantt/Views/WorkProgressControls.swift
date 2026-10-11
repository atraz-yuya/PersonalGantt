import SwiftUI

struct WorkProgressControls: View {
    @Bindable var model: ScheduleViewModel
    let taskID: UUID
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("30分やった") { perform { try model.logWork(taskID: taskID, minutes: 30) } }
                Button("60分やった") { perform { try model.logWork(taskID: taskID, minutes: 60) } }
            }
            if model.activeWorkSession?.taskID == taskID {
                Button("停止して実績を保存") { perform { try model.finishWork() } }
                Button("タイマーを取り消す") { model.cancelWorkTimer() }
                Text("開始: \(model.activeWorkSession!.start.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("作業を開始") { perform { try model.startWork(taskID: taskID) } }
                    .disabled(model.activeWorkSession != nil)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.buttonStyle(.borderless).disabled(model.isBackupRecoveryRequired)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
