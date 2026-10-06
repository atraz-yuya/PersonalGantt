import SwiftUI

struct ScheduleTimelineView: View {
    @Bindable var model: ScheduleViewModel
    let snapshot: DaySchedule
    let now: Date
    let isToday: Bool
    let onDetail: (UUID) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.day.interval.start, format: .dateTime.month().day().weekday()).font(.title2.bold())
                    Text("作業 \(snapshot.blocks.count)枠・\(snapshot.workMinutes.formatted())分 / 固定予定 \(snapshot.events.count)件")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isToday, let current = snapshot.blocks.first(where: { $0.source.start <= now && now < $0.source.end }) {
                        Button { onDetail(current.source.taskID) } label: {
                            Label("現在の時間枠: \(model.title(for: current.source.taskID))", systemImage: "clock")
                        }
                    }
                }.padding(.vertical, 4)
            }
            Section(isToday ? "今日の予定" : "日別Timeline") {
                if snapshot.items.isEmpty {
                    Text(isToday ? "今日の作業と固定予定はありません。" : "この日の作業と固定予定はありません。")
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.items) { item in
                    switch item {
                    case .work(let block): workRow(block)
                    case .event(let event):
                        VStack(alignment: .leading, spacing: 6) {
                            Label(event.source.title.isEmpty ? "固定予定" : event.source.title, systemImage: "calendar")
                                .font(.headline)
                            if event.source.isAllDay { Text("終日") }
                            else { IntervalTimeLabel(interval: event.interval, day: snapshot.day) }
                            Text("Google Calendarの固定予定").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !model.unscheduledTasks.isEmpty {
                Section("未配置の作業") {
                    Text("締切までに配置できないTaskが\(model.unscheduledTasks.count)件あります。タスク一覧から確認してください。")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
            Section("活動時間内の利用可能枠") {
                if snapshot.availableIntervals.isEmpty {
                    Text("利用可能な時間枠はありません。") .foregroundStyle(.secondary)
                }
                ForEach(snapshot.availableIntervals, id: \.self) { interval in
                    IntervalTimeLabel(interval: interval, day: snapshot.day)
                }
                Text("固定予定を差し引いた時間枠です。作業の配置に使われた時間も含みます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier(isToday ? "today-schedule" : "day-timeline")
    }

    private func workRow(_ block: DayWorkBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onDetail(block.source.taskID) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.title(for: block.source.taskID), systemImage: "rectangle.split.2x1")
                        .font(.headline).foregroundStyle(.primary)
                    HStack {
                        IntervalTimeLabel(interval: block.interval, day: snapshot.day)
                        Spacer()
                        Text("\(block.minutes.formatted())分")
                    }.foregroundStyle(.primary)
                    Text(BlockTimePosition.of(block.source, now: now).rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                    if block.interval.start != block.source.start || block.interval.end != block.source.end {
                        Text("日をまたぐ作業の、この日分を表示しています。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("schedule-block-\(block.source.taskID)")
            if let task = model.task(for: block.source.taskID) {
                Button(task.isCompleted ? "未完了に戻す" : "Taskを完了にする") {
                    _Concurrency.Task { await model.toggleTaskCompletion(id: task.id) }
                }
                .buttonStyle(.borderless)
                .disabled(model.taskIsBusy(task.id) || !model.canToggleTask(task))
                .font(.subheadline)
            } else {
                Text("配置対象から外れたTaskの保持された時間枠です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct IntervalTimeLabel: View {
    let interval: DateInterval
    let day: ScheduleDay
    var body: some View {
        HStack(spacing: 4) {
            Text(interval.start, style: .time)
            Text("–")
            if interval.end == day.interval.end { Text("翌日0:00") }
            else { Text(interval.end, style: .time) }
        }
        .font(.subheadline.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}
