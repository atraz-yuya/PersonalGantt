import Foundation
import Testing
@testable import PersonalGantt

@MainActor struct WritebackTests {
    private func block(_ start: Int = 8, _ end: Int = 9, id: UUID = UUID()) -> ScheduledBlock { ScheduledBlock(taskID: id, start: ReminderFixtures.date(start), end: ReminderFixtures.date(end)) }
    @Test func offNeverSendsRequestsAndReadOnlyCannotWrite() async throws {
        let http = WriteHTTP(), tokens = WriteTokens(), writer = GoogleWritebackService(tokens: tokens, transport: http)
        let state = WritebackState()
        #expect(try await writer.publish(blocks: [block()], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) == state)
        #expect(http.requests.isEmpty)
        var on = state; on.enabled = true; tokens.writePermission = false
        await #expect(throws: WritebackError.self) { try await writer.publish(blocks: [block()], titles: [:], state: on, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) }
        #expect(http.requests.isEmpty)
    }
    @Test func createUpdateDeleteAndDuplicateSuppressionUseOnlyDedicatedCalendar() async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        var state = WritebackState(); state.enabled = true
        let original = block(); let titles = [original.taskID: "Synthetic"]
        state = try await writer.publish(blocks: [original], titles: titles, state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(state.calendarID == "dedicated" && state.events.count == 1 && http.events.count == 1)
        let id = try #require(state.events.keys.first)
        let writes = http.writeCount
        state = try await writer.publish(blocks: [original], titles: titles, state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(http.writeCount == writes)
        let shifted = block(10, 11, id: original.taskID)
        state = try await writer.publish(blocks: [shifted], titles: titles, state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(state.events.keys.first == id && http.requests.contains { $0.httpMethod == "PATCH" && $0.value(forHTTPHeaderField: "If-Match") != nil })
        state = try await writer.publish(blocks: [], titles: titles, state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(state.events.isEmpty && http.events.isEmpty)
        #expect(http.requests.filter { $0.httpMethod == "PATCH" || $0.httpMethod == "DELETE" }.allSatisfy { $0.url!.path.contains("/dedicated/events/") })
    }
    @Test func fractionalSecondPlacementRemainsStableAcrossRefresh() async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        var state = WritebackState(); state.enabled = true
        var work = block(); work.start = work.start.addingTimeInterval(0.123456); work.end = work.end.addingTimeInterval(0.123456)
        state = try await writer.publish(blocks: [work], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        let writes = http.writeCount
        state = try await writer.publish(blocks: [work], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(http.writeCount == writes && state.events.count == 1)
    }
    @Test func externalEditIsWarnedWithoutOverwrite() async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        var state = WritebackState(); state.enabled = true
        let original = block()
        state = try await writer.publish(blocks: [original], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        let id = try #require(state.events.keys.first); http.events[id]?["summary"] = "External change"
        let writes = http.writeCount
        await #expect(throws: WritebackError.self) { try await writer.publish(blocks: [original], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) }
        #expect(http.writeCount == writes)
    }
    @Test func lostCreateResponseRecoversWithoutDuplicatesAndFutureOrphansCanBeRemoved() async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        var state = WritebackState(); state.enabled = true
        let original = block(); http.loseNextCreateResponse = true
        await #expect(throws: (any Error).self) { try await writer.publish(blocks: [original], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) }
        #expect(http.events.count == 1)
        let writes = http.writeCount
        let recovered = try await writer.publish(blocks: [original], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(recovered.events.count == 1 && http.writeCount == writes)
        let cleaned = try await writer.publish(blocks: [], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        #expect(cleaned.events.isEmpty && http.events.isEmpty)
    }
    @Test func begunEventsAreNeverChangedOrDeleted() async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        var state = WritebackState(); state.enabled = true
        let original = block()
        state = try await writer.publish(blocks: [original], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        let writes = http.writeCount
        state = try await writer.publish(blocks: [], titles: [:], state: state, now: ReminderFixtures.date(9), calendar: ReminderFixtures.calendar)
        #expect(http.events.count == 1 && http.writeCount == writes && state.events.count == 1)
    }
    @Test(arguments: [0, 1, 2]) func elapsedTimeCannotReuseBegunEventIDForSameTaskFutureBlock(kind: Int) async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        var state = WritebackState(); state.enabled = true
        let first = block(), later = block(10, 11, id: first.taskID)
        state = try await writer.publish(blocks: [first, later], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar)
        let begun = try #require(state.events.values.first { $0.start == first.start })
        let before = try JSONSerialization.data(withJSONObject: #require(http.events[begun.id]), options: [.sortedKeys])
        let writes = http.writeCount
        if kind == 2 { state.events = [:] } // simulate a lost checkpoint; discover both events
        let blocks = kind == 0 ? [first, later] : [later]
        state = try await writer.publish(blocks: blocks, titles: [:], state: state, now: ReminderFixtures.date(9), calendar: ReminderFixtures.calendar)
        #expect(try JSONSerialization.data(withJSONObject: #require(http.events[begun.id]), options: [.sortedKeys]) == before)
        #expect(state.events.count == 2 && http.events.count == 2 && http.writeCount == writes)
        state = try await writer.publish(blocks: blocks, titles: [:], state: state, now: ReminderFixtures.date(9), calendar: ReminderFixtures.calendar)
        #expect(http.writeCount == writes)
    }
    @Test func mismatchingDestinationMarkerPreventsAnyWrites() async throws {
        let http = WriteHTTP(), writer = GoogleWritebackService(tokens: WriteTokens(), transport: http)
        http.description = "Existing user calendar"
        var state = WritebackState(); state.enabled = true; state.calendarID = "dedicated"
        await #expect(throws: WritebackError.self) { try await writer.publish(blocks: [block()], titles: [:], state: state, now: ReminderFixtures.date(0), calendar: ReminderFixtures.calendar) }
        #expect(http.writeCount == 0)
    }
    @Test func oauthAddsOnlyAppCreatedScopeOnExplicitEnablement() throws {
        let id = "synthetic.apps.googleusercontent.com"
        let read = try GoogleOAuthAttempt.make(configuration: GoogleOAuthConfiguration(clientID: id))
        let write = try GoogleOAuthAttempt.make(configuration: GoogleOAuthConfiguration(clientID: id, writebackEnabled: true))
        let query = URLComponents(url: write.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let scopes = Set(query.first { $0.name == "scope" }!.value!.split(separator: " ").map(String.init))
        #expect(scopes == GoogleOAuthConfiguration.scopes.union([GoogleOAuthConfiguration.writebackScope]))
        #expect(!read.authorizationURL.absoluteString.contains("app.created"))
    }
}
@MainActor private final class WriteTokens: GoogleTokenProviding {
    var isSignedIn = true, writePermission = true
    var grantedScopes: Set<String> { writePermission ? GoogleOAuthConfiguration.scopes.union([GoogleOAuthConfiguration.writebackScope]) : GoogleOAuthConfiguration.scopes }
    func signIn() async throws { }
    func accessToken(forceRefresh: Bool) async throws -> String { "synthetic" }
    func signOut() throws { isSignedIn = false }
}
@MainActor private final class WriteHTTP: GoogleHTTPTransport {
    var description: String?
    var events: [String: [String: Any]] = [:]
    var requests: [URLRequest] = []
    var loseNextCreateResponse = false
    var writeCount: Int { requests.filter { $0.httpMethod != "GET" }.count }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path, method = request.httpMethod!
        var value: Any = [:], status = 200
        if path.hasSuffix("/calendarList") {
            value = ["items": description.map { [["id": "dedicated", "description": $0]] } ?? []]
        } else if path == "/calendar/v3/calendars", method == "POST" {
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]); description = body["description"] as? String
            value = ["id": "dedicated", "description": description!]
        } else if path == "/calendar/v3/calendars/dedicated" { value = ["id": "dedicated", "description": description ?? ""] }
        else if path.hasSuffix("/events"), method == "GET" { value = ["items": Array(events.values)] }
        else if method == "POST" || method == "PATCH" {
            var body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let id = (body["id"] as? String) ?? request.url!.lastPathComponent; body["id"] = id; body["etag"] = "synthetic-\(writeCount)"; events[id] = body; value = body
            if loseNextCreateResponse { loseNextCreateResponse = false; throw GoogleCalendarError.network }
        } else if method == "DELETE" { events.removeValue(forKey: request.url!.lastPathComponent); status = 204 }
        else { status = 404 }
        return (status == 204 ? Data() : try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct WritebackIntegrationTests {
    @Test func localMutationsDoNotWriteUntilExplicitEnablementAndBackupDoesNotEnableAnotherDevice() async throws {
        let a = model(), b = model(), writer = ModelWriteProvider()
        a.attachWritebackProvider(writer)
        _ = try a.addTask(TaskDraft(title: "Synthetic", deadline: ReminderFixtures.date(23)))
        await a.publishSchedule(); #expect(writer.calls == 0)
        await a.enableWriteback(); #expect(a.writebackState.enabled && writer.calls == 1)
        let backup = try a.makeBackup(); try b.restoreBackup(backup)
        #expect(!b.writebackState.enabled && b.writebackState.calendarID == nil)
        a.disableWriteback(); await a.publishSchedule(); #expect(writer.calls == 1)
    }
    @Test func ownDestinationIsExcludedFromReadbackToPreventLoop() async {
        let a = model(); a.attachWritebackProvider(ModelWriteProvider())
        await a.enableWriteback()
        #expect(await a.applyCalendarSelection(["own"]))
        #expect(a.selectedCalendarIDs.isEmpty && !a.calendars.contains { $0.id == "own" })
    }
    private func model() -> ScheduleViewModel {
        let value = ScheduleViewModel(tasks: [], calendarProvider: ModelWriteCalendar(), calendar: ReminderFixtures.calendar,
            clock: { ReminderFixtures.date(0) }, planStore: ModelWriteStore())
        value.configureBackup(reminderStore: MemoryReminderMetadata(), journal: ModelWriteJournal(), deviceID: UUID())
        return value
    }
}
@MainActor private final class ModelWriteProvider: CalendarWritebackProviding {
    var calls = 0
    func authorize() async throws { }
    func publish(blocks: [ScheduledBlock], titles: [UUID: String], state: WritebackState, now: Date, calendar: Calendar) async throws -> WritebackState {
        calls += 1; var next = state; next.calendarID = "own"; return next
    }
}
@MainActor private final class ModelWriteCalendar: CalendarProviding {
    var authorization: CalendarAuthorization = .connected
    func requestAccess() async throws -> CalendarAuthorization { authorization }
    func loadCalendars() async throws -> [CalendarSource] { [CalendarSource(id: "own", title: "Synthetic", accountTitle: "Test")] }
    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] { [] }
}
@MainActor private final class ModelWriteStore: PlanSnapshotStoring {
    var value: PlanSnapshot?
    func load() throws -> PlanSnapshot? { value }
    func save(_ snapshot: PlanSnapshot) throws { try snapshot.validate(); value = snapshot }
}
@MainActor private final class ModelWriteJournal: BackupJournalStoring {
    var value: PersonalGanttBackup?
    func load() throws -> PersonalGanttBackup? { value }
    func save(_ backup: PersonalGanttBackup) throws { value = backup }
    func remove() throws { value = nil }
}
