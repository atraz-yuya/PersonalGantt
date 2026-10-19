import SwiftUI

struct TodayView: View {
    @Bindable var model: ScheduleViewModel
    let onDetail: (UUID) -> Void
    var onInputQueue: () -> Void = { }
    var onSettings: () -> Void = { }
    @State private var workError: String?
    @State private var activityDay: TodayActivityRoute?
    @State private var showsUnscheduled = false
    @State private var pendingUnscheduledTaskID: UUID?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = TodaySummary.make(now: context.date, tasks: model.tasks, blocks: model.result.blocks, events: model.fixedEvents,
                sessions: model.workSessions, calendar: model.presentationCalendar)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(context.date.formatted(date: .abbreviated, time: .shortened)).font(.title2.bold())
                    Button {
                        activityDay = TodayActivityRoute(day: context.date)
                    } label: {
                        Label("今日の稼働時間: " + (model.activitySettings.window(on: context.date, calendar: model.presentationCalendar)?.displayName ?? "稼働なし") + "・変更", systemImage: "clock")
                    }.disabled(model.isBackupRecoveryRequired).accessibilityIdentifier("today-activity")
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            metric("今日の残り作業", "\(summary.remainingPlannedMinutes.rounded(.up).formatted())分")
                            Spacer()
                            metric("今日の実績", "\(summary.actualMinutes.formatted())分")
                            Spacer()
                            metric("日次上限", model.workloadSettings.maxScheduledMinutesPerDay.map { "\($0)分" } ?? "なし")
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            metric("今日の残り作業", "\(summary.remainingPlannedMinutes.rounded(.up).formatted())分")
                            metric("今日の実績", "\(summary.actualMinutes.formatted())分")
                            metric("日次上限", model.workloadSettings.maxScheduledMinutesPerDay.map { "\($0)分" } ?? "なし")
                        }
                    }
                    if let next = summary.nextWork {
                        Label("次の作業: \(model.title(for: next.taskID))", systemImage: "play.circle")
                    } else { Text("今日の残り作業はありません。") .foregroundStyle(.secondary) }
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
                        Button { showsUnscheduled = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("未配置の作業 \(model.unscheduledTasks.count)件").font(.headline)
                                    Text("計画全体の作業・一覧と理由を確認").font(.caption)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .accessibilityIdentifier("today-unscheduled")
                        .accessibilityHint("未配置のタスク名、未配置時間と理由の一覧を開きます")
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
                    if let schedule = summary.schedule {
                        Text("今日の予定").font(.title3.bold())
                        if !summary.allDayEvents.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("終日").font(.subheadline).foregroundStyle(.secondary)
                                ForEach(summary.allDayEvents) { event in
                                    calendarRow(event, day: schedule.day)
                                }
                            }
                        }
                        if summary.timelineItems.isEmpty && summary.allDayEvents.isEmpty {
                            Text("今日の作業・カレンダー予定はありません。") .foregroundStyle(.secondary)
                        }
                        ForEach(summary.timelineItems) { item in
                            switch item {
                            case .work(let block): workCard(block, day: schedule.day, now: context.date)
                            case .event(let event): calendarRow(event, day: schedule.day)
                            }
                        }
                    }
                }.padding()
            }.accessibilityIdentifier("today-dashboard")
        }.sheet(isPresented: $showsUnscheduled, onDismiss: {
            // Present the parent detail sheet only after this sheet is dismissed.
            if let id = pendingUnscheduledTaskID {
                pendingUnscheduledTaskID = nil
                onDetail(id)
            }
        }) {
            UnscheduledTasksView(model: model) { id in
                pendingUnscheduledTaskID = id
                showsUnscheduled = false
            }
        }.sheet(item: $activityDay) { route in
            NavigationStack {
                DayActivityView(model: model, day: route.day)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { activityDay = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 360)
            #endif
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }
    }

    private func calendarRow(_ event: DayFixedEvent, day: ScheduleDay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if !event.source.isAllDay { IntervalTimeLabel(interval: event.interval, day: day) }
                Text(event.source.title.isEmpty ? "カレンダーの予定" : event.source.title)
                Text("Google カレンダー").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-calendar-\(event.source.id)")
    }

    private func workCard(_ block: DayWorkBlock, day: ScheduleDay, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { onDetail(block.source.taskID) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    IntervalTimeLabel(interval: block.interval, day: day)
                    Text(model.title(for: block.source.taskID)).font(.headline)
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain)
            if let task = model.task(for: block.source.taskID) {
                HStack {
                    Text("優先度: \(task.priority.displayName)")
                    if task.routineOccurrence != nil { Label("Routine", systemImage: "repeat") }
                }.font(.caption).foregroundStyle(.secondary)
                Text("実績 \(model.completedMinutes(for: task.id).formatted())分・残り必要 \(model.remainingMinutes(for: task).formatted())分")
                    .font(.caption)
                WorkProgressControls(model: model, taskID: task.id)
                HStack {
                    Button("完了") { _Concurrency.Task { await model.toggleTaskCompletion(id: task.id) } }
                        .disabled(!model.canToggleTask(task) || model.taskIsBusy(task.id))
                    Button(task.routineOccurrence != nil ? "この日をスキップ" : "明日以降へ") { model.skipToday(taskID: task.id) }
                        .disabled(model.isBackupRecoveryRequired || task.routineOccurrence == nil && block.source.start <= now)
                    Button("詳細") { onDetail(task.id) }
                }.buttonStyle(.borderless)
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("today-work-\(block.source.taskID)")
    }
}

private struct TodayActivityRoute: Identifiable { let id = UUID(); let day: Date }
