import SwiftUI

struct AppSidebarView: View {
    @Bindable var model: ScheduleViewModel
    let selection: AppDestination
    let onCommand: (WorkspaceCommand) -> Void
    var body: some View {
        List {
            Section("画面") {
                ForEach([AppDestination.today, .day, .tasks]) { destination in
                    destinationRow(destination)
                }
            }
            Section("日常操作") {
                Button { onCommand(.addTask) } label: { row("タスクを追加", symbol: "plus") }
                    .disabled(model.isBackupRecoveryRequired).accessibilityIdentifier("add-task")
                destinationRow(.inputQueue)
                Button { onCommand(.refreshCalendar) } label: { row("カレンダーを更新", symbol: "arrow.triangle.2.circlepath") }
                    .disabled(model.isLoadingCalendars || model.isBackupRecoveryRequired).accessibilityIdentifier("refresh-calendar")
                Button { onCommand(.recalculate) } label: { row("予定を再計算", symbol: "arrow.clockwise") }
                    .disabled(model.isBackupRecoveryRequired).accessibilityIdentifier("recalculate-plan")
            }
            Section { destinationRow(.settings) }
        }
        .buttonStyle(.plain)
        .listStyle(.sidebar)
        .navigationTitle("PersonalGantt")
        .accessibilityIdentifier("app-sidebar")
    }
    private func row(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
    }
    private func destinationRow(_ destination: AppDestination) -> some View {
        Button { onCommand(.show(destination)) } label: {
            HStack {
                row(destination.title, symbol: destination.symbol)
                if destination == .inputQueue && model.inputQueueCount > 0 {
                    Text(model.inputQueueCount.formatted()).font(.caption.monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule()).accessibilityHidden(true)
                }
            }.contentShape(Rectangle())
        }
        .listRowBackground(selection == destination ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityLabel(destination == .inputQueue ? model.inputQueueAccessibilityLabel : destination.title)
        .accessibilityAddTraits(selection == destination ? .isSelected : [])
        .accessibilityIdentifier("navigate-" + destination.rawValue)
    }
}
