import Foundation

nonisolated struct WorkSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var taskID: UUID
    var taskTitle: String
    var start: Date
    var end: Date
    var actualMinutes: Int
    init(id: UUID = UUID(), taskID: UUID, taskTitle: String = "作業", start: Date, end: Date, actualMinutes: Int) {
        self.id = id; self.taskID = taskID; self.taskTitle = taskTitle
        self.start = start; self.end = end; self.actualMinutes = actualMinutes
    }
    func validate() throws {
        guard start >= .distantPast, end <= .distantFuture,
              start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start < end, actualMinutes > 0, actualMinutes <= 1440,
              Double(actualMinutes) * 60 <= end.timeIntervalSince(start) + 1 else { throw WorkSessionError.invalid }
    }
    static func unrecordedMinutes(in block: ScheduledBlock, sessions: [WorkSession]) -> Double {
        let credited = sessions.filter { $0.taskID == block.taskID }.reduce(0.0) { sum, session in
            let overlap = max(0, min(session.end, block.end).timeIntervalSince(max(session.start, block.start)))
            return sum + overlap / session.end.timeIntervalSince(session.start) * Double(session.actualMinutes)
        }
        return max(0, block.durationMinutes - credited)
    }
    static func minutesByTask(_ sessions: [WorkSession]) -> [UUID: Double] {
        sessions.reduce(into: [:]) { $0[$1.taskID, default: 0] += Double($1.actualMinutes) }
    }
}
nonisolated struct ActiveWorkSession: Codable, Equatable, Sendable { var taskID: UUID; var start: Date }
nonisolated enum WorkSessionError: LocalizedError { case invalid, alreadyRunning, noRunningSession
    var errorDescription: String? {
        switch self {
        case .invalid: "実績は1〜1440分で、開始・終了が有効な作業時間を入力してください。"
        case .alreadyRunning: "記録中の作業を停止してから、次の作業を開始してください。"
        case .noRunningSession: "開始中の作業がありません。"
        }
    }
}
