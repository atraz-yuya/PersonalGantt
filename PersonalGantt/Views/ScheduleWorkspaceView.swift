import SwiftUI

private enum ScheduleDisplay: String, CaseIterable, Identifiable {
    case today = "今日", day = "日別", gantt = "Gantt"
    var id: Self { self }
}

struct ScheduleWorkspaceView: View {
    @Bindable var model: ScheduleViewModel
    let includesToday: Bool
    let onDetail: (UUID) -> Void
    @State private var display: ScheduleDisplay
    @State private var selectedDate = Date()

    init(model: ScheduleViewModel, includesToday: Bool = true, onDetail: @escaping (UUID) -> Void) {
        self.model = model
        self.includesToday = includesToday
        self.onDetail = onDetail
        _display = State(initialValue: includesToday ? .today : .day)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let days = model.displayDays(referenceDate: context.date)
            VStack(spacing: 0) {
                Picker("表示", selection: $display) {
                    if includesToday { Text("今日").tag(ScheduleDisplay.today) }
                    Text("日別").tag(ScheduleDisplay.day)
                    Text("Gantt").tag(ScheduleDisplay.gantt)
                }
                .pickerStyle(.segmented).padding()
                .accessibilityIdentifier("schedule-display")
                if display != .today { dayPicker(days: days, now: context.date) }
                Divider()
                if let snapshot = model.daySchedule(on: display == .today ? context.date : selectedDate) {
                    if display == .gantt { GanttView(model: model, snapshot: snapshot, now: context.date, onDetail: onDetail) }
                    else if display == .today { TodayView(model: model, onDetail: onDetail) }
                    else { ScheduleTimelineView(model: model, snapshot: snapshot, now: context.date, isToday: display == .today, onDetail: onDetail) }
                } else { Text("選択した日を表示できません。") }
            }
            .onChange(of: days.map(\.id), initial: true) { _, _ in
                guard let first = days.first, let last = days.last else { return }
                let normalized = model.presentationCalendar.startOfDay(for: selectedDate)
                selectedDate = min(max(normalized, first.id), last.id)
            }
        }
    }

    private func dayPicker(days: [ScheduleDay], now: Date) -> some View {
        HStack {
            let selected = model.presentationCalendar.startOfDay(for: selectedDate)
            let index = days.firstIndex { $0.id == selected }
            Button("前の日", systemImage: "chevron.left") {
                if let index, index > 0 { selectedDate = days[index - 1].id }
            }.labelStyle(.iconOnly).disabled(index == nil || index == 0)
            if let first = days.first, let last = days.last {
                DatePicker("日付", selection: $selectedDate, in: first.id...last.id, displayedComponents: .date)
                    .labelsHidden().accessibilityIdentifier("schedule-date")
            }
            Button("次の日", systemImage: "chevron.right") {
                if let index, index + 1 < days.count { selectedDate = days[index + 1].id }
            }.labelStyle(.iconOnly).disabled(index == nil || index == days.count - 1)
            Spacer(minLength: 8)
            Button("今日へ") {
                if let today = days.first(where: { $0.id == model.presentationCalendar.startOfDay(for: now) }) { selectedDate = today.id }
            }.disabled(!days.contains { $0.id == model.presentationCalendar.startOfDay(for: now) })
        }.padding(.horizontal).padding(.bottom, 12)
    }
}
