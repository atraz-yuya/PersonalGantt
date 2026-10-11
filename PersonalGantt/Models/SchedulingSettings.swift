import Foundation

nonisolated enum DistributionMode: String, Codable, CaseIterable, Sendable {
    case earliestFirst, balanced
    var displayName: String { self == .balanced ? "長期作業を分散" : "早い空き時間から" }
}
nonisolated struct SchedulingSettings: Codable, Equatable, Sendable {
    var distributionMode: DistributionMode = .earliestFirst
    static let `default` = SchedulingSettings()
}
