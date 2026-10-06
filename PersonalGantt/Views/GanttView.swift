import SwiftUI

/// Read-only rendering of ScheduledBlock dates. No dragging or time editing.
struct GanttView: View {
    @Bindable var model: ScheduleViewModel
    let snapshot: DaySchedule
    let now: Date
    let onDetail: (UUID) -> Void
    private let labelWidth: CGFloat = 180
    private var chartWidth: CGFloat { CGFloat(snapshot.day.interval.duration / 3600) * 64 }
    private var ticks: [Date] {
        stride(from: 0.0, through: snapshot.day.interval.duration, by: 7200).map {
            snapshot.day.interval.start.addingTimeInterval($0)
        } + (snapshot.day.interval.duration.truncatingRemainder(dividingBy: 7200) == 0 ? [] : [snapshot.day.interval.end])
    }
    private var taskIDs: [UUID] {
        var seen = Set<UUID>()
        return snapshot.blocks.compactMap { seen.insert($0.source.taskID).inserted ? $0.source.taskID : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Label("作業", systemImage: "rectangle.fill").foregroundStyle(.blue)
                Label("固定予定", systemImage: "rectangle.fill").foregroundStyle(.secondary)
                Label("利用可能枠", systemImage: "rectangle.fill").foregroundStyle(.green)
            }.font(.caption).padding(.horizontal)
            Text("バーを選ぶとTask詳細が開きます。横にスクロールして各時間帯を確認できます。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    labels
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 8) {
                                axis
                                chartRow {
                                    ForEach(snapshot.availableIntervals, id: \.self) { interval in
                                        if let placement = GanttPlacement.of(interval, in: snapshot.day) {
                                            RoundedRectangle(cornerRadius: 4).fill(.green.opacity(0.18))
                                                .frame(width: chartWidth * placement.lengthFraction, height: 32)
                                                .offset(x: chartWidth * placement.startFraction, y: 6)
                                        }
                                    }
                                }
                                ForEach(snapshot.events) { event in
                                    chartRow {
                                        if let placement = GanttPlacement.of(event.interval, in: snapshot.day) {
                                            RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.25))
                                                .overlay(alignment: .leading) {
                                                    Text(event.source.isAllDay ? "終日" : event.source.title)
                                                        .font(.caption).padding(.horizontal, 6).lineLimit(1)
                                                }
                                                .frame(width: chartWidth * placement.lengthFraction, height: 36).clipped()
                                                .offset(x: chartWidth * placement.startFraction, y: 4)
                                        }
                                    }.accessibilityHidden(true)
                                }
                                ForEach(taskIDs, id: \.self) { taskID in
                                    chartRow {
                                        ForEach(snapshot.blocks.filter { $0.source.taskID == taskID }) { block in
                                            if let placement = GanttPlacement.of(block.interval, in: snapshot.day) {
                                                Button { onDetail(taskID) } label: {
                                                    RoundedRectangle(cornerRadius: 5).fill(.blue.opacity(block.source.end <= now ? 0.45 : 0.85))
                                                        .overlay {
                                                            Text("\(block.minutes.formatted())分").font(.caption).foregroundStyle(.white)
                                                                .lineLimit(1).padding(.horizontal, 4)
                                                        }
                                                }
                                                .buttonStyle(.plain)
                                                .frame(width: chartWidth * placement.lengthFraction, height: 36).clipped()
                                                .offset(x: chartWidth * placement.startFraction, y: 4)
                                                .accessibilityLabel("\(model.title(for: taskID))、\(intervalDescription(block.interval))、\(block.minutes.formatted())分")
                                                .accessibilityHint("Task詳細を開きます")
                                            }
                                        }
                                    }
                                }
                            }.frame(width: chartWidth, alignment: .leading)
                        }
                        .onAppear { scrollToFirstInterval(proxy) }
                        .onChange(of: snapshot.day.id) { _, _ in scrollToFirstInterval(proxy) }
                    }
                    .frame(height: 30 + CGFloat(1 + snapshot.events.count + taskIDs.count) * 52)
                }.padding(16)
                if snapshot.blocks.isEmpty && snapshot.events.isEmpty {
                    Text("この日の作業と固定予定はありません。")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .accessibilityIdentifier("gantt-chart")
            Text("利用可能枠は作業の配置分も含みます。薄い作業バーは過去の配置で、作業実績を表しません。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }.padding(.vertical, 8)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task / 予定").font(.caption.bold()).frame(height: 22)
            Text("利用可能枠").font(.subheadline).frame(height: 44)
            ForEach(snapshot.events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.source.title.isEmpty ? "固定予定" : event.source.title).font(.subheadline).lineLimit(1)
                    Text(event.source.isAllDay ? "終日" : intervalDescription(event.interval)).font(.caption).foregroundStyle(.secondary)
                }.frame(height: 44)
            }
            ForEach(taskIDs, id: \.self) { taskID in
                Button { onDetail(taskID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title(for: taskID)).font(.subheadline).lineLimit(1)
                        Text("\(snapshot.blocks.filter { $0.source.taskID == taskID }.reduce(0) { $0 + $1.minutes }.formatted())分")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(height: 44)
                }.buttonStyle(.plain)
            }
        }.frame(width: labelWidth, alignment: .leading)
    }

    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(ticks, id: \.self) { tick in
                let width = CGFloat(min(7200, snapshot.day.interval.end.timeIntervalSince(tick)) / 3600) * 64
                Color.clear.frame(width: width, height: 22)
                    .overlay(alignment: tick == snapshot.day.interval.end ? .trailing : .leading) {
                        Group {
                            if tick == snapshot.day.interval.end { Text("翌0:00") }
                            else { Text(tick, style: .time) }
                        }.font(.caption2.monospacedDigit()).fixedSize()
                    }.id(tick)
            }
        }.frame(width: chartWidth, height: 22, alignment: .leading).accessibilityHidden(true)
    }

    private func scrollToFirstInterval(_ proxy: ScrollViewProxy) {
        let start = (snapshot.events.map(\.interval.start) + snapshot.blocks.map(\.interval.start)).min()
            ?? snapshot.availableIntervals.first?.start ?? snapshot.day.id
        if let tick = ticks.last(where: { $0 <= start && $0 < snapshot.day.interval.end }) {
            proxy.scrollTo(tick, anchor: .leading)
        }
    }

    private func chartRow<Bars: View>(@ViewBuilder bars: () -> Bars) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                Rectangle().fill(.quaternary).frame(width: 1, height: 44)
                    .offset(x: CGFloat(tick.timeIntervalSince(snapshot.day.interval.start) / snapshot.day.interval.duration) * chartWidth)
                    .accessibilityHidden(true)
            }
            bars()
            if snapshot.day.interval.start <= now && now < snapshot.day.interval.end {
                Rectangle().fill(.red.opacity(0.7)).frame(width: 1, height: 44)
                    .offset(x: CGFloat(now.timeIntervalSince(snapshot.day.interval.start) / snapshot.day.interval.duration) * chartWidth)
                    .accessibilityHidden(true)
            }
        }.frame(width: chartWidth, height: 44, alignment: .topLeading)
    }

    private func intervalDescription(_ value: DateInterval) -> String {
        "\(value.start.formatted(date: .omitted, time: .shortened))から\(value.end == snapshot.day.interval.end ? "翌日0:00" : value.end.formatted(date: .omitted, time: .shortened))"
    }
}
