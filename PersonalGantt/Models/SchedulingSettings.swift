import Foundation

nonisolated enum DistributionMode: String, Codable, CaseIterable, Sendable {
    case earliestFirst, balanced
    var displayName: String { self == .balanced ? "長期作業を分散" : "早い空き時間から" }
}
nonisolated struct SchedulingSettings: Codable, Equatable, Sendable {
    var distributionMode: DistributionMode = .earliestFirst
    var optimizeLocally: Bool? = nil
    var maxContinuousMinutes: Int? = nil
    var minimumBreakMinutes: Int? = nil
    var weights: OptimizationWeights? = nil
    var activitySettings: ActivitySettings? = nil
    var isValid: Bool {
        let restValid = (maxContinuousMinutes == nil && minimumBreakMinutes == nil) ||
            (maxContinuousMinutes.map { (1...480).contains($0) } == true && minimumBreakMinutes.map { (1...120).contains($0) } == true)
        return restValid && (weights?.isValid ?? true) && (activitySettings?.isValid ?? true)
    }
    static let `default` = SchedulingSettings()
}
