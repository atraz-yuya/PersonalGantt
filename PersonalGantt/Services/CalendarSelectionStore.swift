import Foundation

/// Preferences only. Events, tasks, and authentication credentials never enter this store.
@MainActor
protocol CalendarSelectionStoring {
    func load(clientID: String) -> Set<String>
    func save(_ selection: Set<String>, clientID: String)
    func clear(clientID: String)
}

@MainActor
final class UserDefaultsCalendarSelectionStore: CalendarSelectionStoring {
    private let defaults: UserDefaults
    private let key = "googleCalendarSelections.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(clientID: String) -> Set<String> {
        guard !clientID.isEmpty else { return [] }
        let selections = defaults.dictionary(forKey: key) ?? [:]
        return Set((selections[clientID] as? [String] ?? []).filter { !$0.isEmpty })
    }

    func save(_ selection: Set<String>, clientID: String) {
        guard !clientID.isEmpty else { return }
        var selections = defaults.dictionary(forKey: key) ?? [:]
        selections[clientID] = selection.sorted()
        defaults.set(selections, forKey: key)
    }

    func clear(clientID: String) {
        var selections = defaults.dictionary(forKey: key) ?? [:]
        selections.removeValue(forKey: clientID)
        defaults.set(selections, forKey: key)
    }
}
