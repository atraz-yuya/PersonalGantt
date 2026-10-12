import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct GoogleSessionIntegrationTests {
    private let configuration = GoogleOAuthConfiguration(clientID: "123-synthetic.apps.googleusercontent.com")

    @Test func restoredExpiredSessionRenewsWithoutBrowserAndReplansSelectedCalendar() async throws {
        let name = "PersonalGanttTests.session.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selections = UserDefaultsCalendarSelectionStore(defaults: defaults)
        selections.save(["study"], clientID: configuration.clientID)
        let storage = MemoryGoogleCredentials()
        storage.value = credential(expiresAt: date(0).addingTimeInterval(-1))
        let http = MockGoogleHTTP()
        let browser = MockGoogleBrowser()
        http.responses = [(200, renewedToken), (200, calendarList), (200, events)]
        let firstClient = GoogleOAuthClient(configuration: configuration, storage: storage,
                                           transport: http, authenticator: browser, clock: { date(0) })
        let first = model(firstClient, http, selections)
        await first.applicationDidBecomeActive()
        #expect(browser.requests.isEmpty)
        #expect(http.requests.map(\.httpMethod) == ["POST", "GET", "GET"])
        #expect(String(data: http.requests[0].httpBody!, encoding: .utf8)?.contains("grant_type=refresh_token") == true)
        #expect(storage.value?.refreshToken == "synthetic-refresh")
        #expect(storage.value?.expiresAt == date(1))
        #expect(first.result.blocks.first?.start == date(10))
        #expect(first.selectedCalendarIDs == ["study"])

        // New OAuth client + view model, same credential/selection stores: no re-authentication.
        let nextHTTP = MockGoogleHTTP()
        nextHTTP.responses = [(200, calendarList), (200, events)]
        let nextBrowser = MockGoogleBrowser()
        let nextClient = GoogleOAuthClient(configuration: configuration, storage: storage,
                                          transport: nextHTTP, authenticator: nextBrowser, clock: { date(0) })
        let second = model(nextClient, nextHTTP, selections)
        await second.applicationDidBecomeActive()
        #expect(nextBrowser.requests.isEmpty)
        #expect(nextHTTP.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(second.selectedCalendarIDs == ["study"])
        #expect(second.result == first.result)
    }

    @Test func connectionCheckForcesRenewalBeforeCalendarFetch() async throws {
        let name = "PersonalGanttTests.session.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selections = UserDefaultsCalendarSelectionStore(defaults: defaults)
        selections.save(["study"], clientID: configuration.clientID)
        let storage = MemoryGoogleCredentials()
        storage.value = credential(expiresAt: date(3))
        let http = MockGoogleHTTP()
        let browser = MockGoogleBrowser()
        http.responses = [(200, renewedToken), (200, calendarList), (200, events)]
        let client = GoogleOAuthClient(configuration: configuration, storage: storage,
                                      transport: http, authenticator: browser, clock: { date(0) })
        let model = model(client, http, selections)
        await model.verifyCalendarConnection()
        #expect(http.requests.map(\.httpMethod) == ["POST", "GET", "GET"])
        #expect(model.lastCalendarRefresh == date(0))
        #expect(model.calendarMessage == nil)
        #expect(browser.requests.isEmpty)
    }

    @Test func expiredRefreshFailureKeepsPlanAndSelectionAndNeverStartsLogin() async throws {
        let name = "PersonalGanttTests.session.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selections = UserDefaultsCalendarSelectionStore(defaults: defaults)
        selections.save(["study"], clientID: configuration.clientID)
        let storage = MemoryGoogleCredentials()
        storage.value = credential(expiresAt: date(3))
        let http = MockGoogleHTTP()
        let browser = MockGoogleBrowser()
        let client = GoogleOAuthClient(configuration: configuration, storage: storage,
                                      transport: http, authenticator: browser, clock: { date(0) })
        let model = model(client, http, selections)
        http.responses = [(200, calendarList), (200, events)]
        await model.loadCalendarState()
        let before = model.result
        let oldSlots = model.availableSlots
        http.responses = [(400, #"{"error":"invalid_grant","error_description":"synthetic-private-detail"}"#)]
        await model.verifyCalendarConnection()
        #expect(storage.value == nil)
        #expect(model.calendarAuthorization == .signedOut)
        #expect(model.result == before && model.availableSlots == oldSlots)
        #expect(selections.load(clientID: configuration.clientID) == ["study"])
        #expect(browser.requests.isEmpty)
        #expect(model.calendarMessage?.contains("synthetic-private-detail") == false)
    }

    @Test func explicitLogoutClearsSelectionAndTokensButKeepsBegunPlans() async throws {
        let name = "PersonalGanttTests.session.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selections = UserDefaultsCalendarSelectionStore(defaults: defaults)
        selections.save(["study"], clientID: configuration.clientID)
        let storage = MemoryGoogleCredentials()
        storage.value = credential(expiresAt: date(3))
        let http = MockGoogleHTTP()
        let tokens = GoogleOAuthClient(configuration: configuration, storage: storage,
                                      transport: http, authenticator: MockGoogleBrowser(), clock: { date(0) })
        var now = date(0)
        let task = PersonalGantt.Task(title: "合成作業", estimatedMinutes: 60, deadline: date(23))
        let model = ScheduleViewModel(tasks: [task], calendarProvider: GoogleCalendarService(tokens: tokens, transport: http, calendar: utc), activitySettings: .legacyFixture,
                                      calendar: utc, clock: { now }, selectionStore: selections, selectionScope: configuration.clientID)
        http.responses = [(200, calendarList), (200, #"{"items":[]}"#)]
        await model.loadCalendarState()
        let begun = try #require(model.result.blocks.first)
        now = date(8).addingTimeInterval(30 * 60)
        model.disconnectGoogle()
        #expect(storage.value == nil)
        #expect(selections.load(clientID: configuration.clientID).isEmpty)
        #expect(model.selectedCalendarIDs.isEmpty && model.fixedEvents.isEmpty)
        #expect(model.result.blocks.contains(begun))
        model.recalculate()
        #expect(model.result.blocks.contains(begun))
    }

    private func model(_ tokens: GoogleOAuthClient, _ http: MockGoogleHTTP,
                       _ selections: UserDefaultsCalendarSelectionStore) -> ScheduleViewModel {
        let task = PersonalGantt.Task(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                     title: "合成作業", estimatedMinutes: 120, deadline: date(23))
        return ScheduleViewModel(tasks: [task], calendarProvider: GoogleCalendarService(tokens: tokens, transport: http, calendar: utc), activitySettings: .legacyFixture,
                                 calendar: utc, clock: { date(0) }, selectionStore: selections, selectionScope: configuration.clientID)
    }
    private func credential(expiresAt: Date) -> GoogleCredentials {
        GoogleCredentials(clientID: configuration.clientID, accessToken: "synthetic-access",
                          refreshToken: "synthetic-refresh", expiresAt: expiresAt, scopes: GoogleOAuthConfiguration.scopes)
    }
    private var calendarList: String { #"{"items":[{"id":"study","summary":"合成学業","accessRole":"owner"}]}"# }
    private var events: String {
        #"{"items":[{"id":"synthetic","start":{"dateTime":"2026-10-06T08:00:00Z"},"end":{"dateTime":"2026-10-06T10:00:00Z"}}]}"#
    }
    private var renewedToken: String {
        let value: [String: Any] = ["access_token": "synthetic-renewed", "token_type": "Bearer", "expires_in": 3600]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: hour))!
    }
}
