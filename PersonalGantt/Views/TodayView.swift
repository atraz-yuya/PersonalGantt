import SwiftUI

struct TodayView: View {
    @Bindable var model: ScheduleViewModel
    let onDetail: (UUID) -> Void
    var onInputQueue: () -> Void = { }
    var onSettings: () -> Void = { }
    @State private var workError: String?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = TodaySummary.make(now: context.date, tasks: model.tasks, blocks: model.result.blocks,
                sessions: model.workSessions, calendar: model.presentationCalendar)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(context.date.formatted(date: .abbreviated, time: .shortened)).font(.title2.bold())
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            metric("今日の残り予定", "\(summary.remainingPlannedMinutes.rounded(.up).formatted())分")
                            Spacer()
                            metric("今日の実績", "\(summary.actualMinutes.formatted())分")
                            Spacer()
                            metric("日次上限", model.workloadSettings.maxScheduledMinutesPerDay.map { "\($0)分" } ?? "なし")
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            metric("今日の残り予定", "\(summary.remainingPlannedMinutes.rounded(.up).formatted())分")
                            metric("今日の実績", "\(summary.actualMinutes.formatted())分")
                            metric("日次上限", model.workloadSettings.maxScheduledMinutesPerDay.map { "\($0)分" } ?? "なし")
                        }
                    }
                    if let next = summary.nextWork {
                        Label("次の作業: \(model.title(for: next.taskID))", systemImage: "play.circle")
                    } else { Text("今日の残り予定はありません。") .foregroundStyle(.secondary) }
                    if let active = model.activeWorkSession {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("記録中: \(model.title(for: active.taskID))")
                            Button("停止して実績を保存") {
                                do { try model.finishWork(); workError = nil } catch { workError = error.localizedDescription }
                            }
                        }
                    }
                    if let workError { Text(workError).foregroundStyle(.orange) }
                    if !model.unscheduledTasks.isEmpty {
                        Label("未配置の作業が\(model.unscheduledTasks.count)件あります。タスク詳細で理由を確認できます。", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    if model.protectedConflictCount > 0 {
                        Label("開始済みの作業とCalendar予定が競合しています。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if model.inputQueueCount > 0 {
                        Button("入力待ち \(model.inputQueueCount)件", systemImage: "clock.badge.questionmark", action: onInputQueue)
                            .font(.subheadline).accessibilityLabel(model.inputQueueAccessibilityLabel)
                            .accessibilityIdentifier("today-input-queue")
                    }
                    ForEach(model.todayAttention) { notice in
                        Button(action: onSettings) { Label(notice.title + "・設定で確認", systemImage: "exclamationmark.circle") }
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                    ForEach(summary.blocks) { block in
                        VStack(alignment: .leading, spacing: 10) {
                            Button { onDetail(block.taskID) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(block.start.formatted(date: .omitted, time: .shortened)) – \(block.end.formatted(date: .omitted, time: .shortened))").font(.subheadline.monospacedDigit())
                                    Text(model.title(for: block.taskID)).font(.headline)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain)
                            if let task = model.task(for: block.taskID) {
                                HStack {
                                    Text("優先度: \(task.priority.displayName)")
                                    if task.routineOccurrence != nil { Label("Routine", systemImage: "repeat") }
                                    if task.isCompleted { Label("完了", systemImage: "checkmark.circle") }
                                }.font(.caption).foregroundStyle(.secondary)
                                Text("実績 \(model.completedMinutes(for: task.id).formatted())分・残り必要 \(model.remainingMinutes(for: task).formatted())分")
                                    .font(.caption)
                                WorkProgressControls(model: model, taskID: task.id)
                                HStack {
                                    Button(task.isCompleted ? "未完了へ" : "完了") { _Concurrency.Task { await model.toggleTaskCompletion(id: task.id) } }
                                        .disabled(!model.canToggleTask(task) || model.taskIsBusy(task.id))
                                    Button(task.routineOccurrence != nil ? "この日をスキップ" : "明日以降へ") { model.skipToday(taskID: task.id) }
                                        .disabled(model.isBackupRecoveryRequired || task.routineOccurrence == nil && block.start <= context.date)
                                    Button("詳細") { onDetail(task.id) }
                                }.buttonStyle(.borderless)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let snapshot = model.daySchedule(on: context.date) {
                        DisclosureGroup("今日の時間軸・固定予定") {
                            ScheduleTimelineView(model: model, snapshot: snapshot, now: context.date, isToday: true, onDetail: onDetail)
                                .frame(minHeight: 400)
                        }
                    }
                }.padding()
            }.accessibilityIdentifier("today-dashboard")
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }
    }
}
