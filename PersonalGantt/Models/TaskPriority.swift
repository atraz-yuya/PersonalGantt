import Foundation

nonisolated enum TaskPriority: Int, Codable, CaseIterable, Sendable {
    case low, normal, high, critical
    var displayName: String {
        switch self { case .low: "低"; case .normal: "通常"; case .high: "高"; case .critical: "最優先" }
    }
    var weight: Double { Double(rawValue + 1) }
}
