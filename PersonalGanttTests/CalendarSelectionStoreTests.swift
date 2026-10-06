import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct CalendarSelectionStoreTests {
    @Test func roundTripAndClientIsolationUseOnlySelectionIDs() throws {
        let name = "PersonalGanttTests.selection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsCalendarSelectionStore(defaults: defaults)
        store.save(["work", "study"], clientID: "synthetic-client-a")
        store.save(["personal"], clientID: "synthetic-client-b")
        let restored = UserDefaultsCalendarSelectionStore(defaults: defaults)
        #expect(restored.load(clientID: "synthetic-client-a") == ["work", "study"])
        #expect(restored.load(clientID: "synthetic-client-b") == ["personal"])
        #expect(restored.load(clientID: "unknown").isEmpty)
        #expect(defaults.dictionaryRepresentation().keys.contains("googleCalendarSelections.v1"))
        #expect(!defaults.dictionaryRepresentation().keys.contains("accessToken"))
    }

    @Test func clearingOneClientDoesNotClearAnother() throws {
        let name = "PersonalGanttTests.selection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsCalendarSelectionStore(defaults: defaults)
        store.save(["a"], clientID: "first")
        store.save(["b"], clientID: "second")
        store.clear(clientID: "first")
        #expect(store.load(clientID: "first").isEmpty)
        #expect(store.load(clientID: "second") == ["b"])
    }

    @Test func emptySelectionSurvivesRecreationAndEmptyScopeIsIgnored() throws {
        let name = "PersonalGanttTests.selection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsCalendarSelectionStore(defaults: defaults)
        store.save(["work"], clientID: "client")
        store.save([], clientID: "client")
        store.save(["invalid"], clientID: "")
        #expect(UserDefaultsCalendarSelectionStore(defaults: defaults).load(clientID: "client").isEmpty)
        #expect(store.load(clientID: "").isEmpty)
    }

    @Test func malformedPreferencesDoNotBecomeASelection() throws {
        let name = "PersonalGanttTests.selection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["client": 123], forKey: "googleCalendarSelections.v1")
        let store = UserDefaultsCalendarSelectionStore(defaults: defaults)
        #expect(store.load(clientID: "client").isEmpty)
        defaults.set(["client": ["", "work", "work"]], forKey: "googleCalendarSelections.v1")
        #expect(store.load(clientID: "client") == ["work"])
    }
}
