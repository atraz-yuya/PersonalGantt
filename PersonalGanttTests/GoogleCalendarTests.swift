import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct GoogleCalendarTests {
    @Test func requestedExampleProducesThreeSlotsAndAvoidsEvents() async throws {
        let http = MockGoogleHTTP()
        http.responses = [(200, calendars), (200, exampleEvents)]
        let service = GoogleCalendarService(tokens: MockGoogleTokens(), transport: http, calendar: utc)
        let task = PersonalGantt.Task(title: "卒論", estimatedMinutes: 300, deadline: date(23))
        let model = ScheduleViewModel(tasks: [task], calendarProvider: service, activitySettings: .legacyFixture, calendar: utc, clock: { date(0) })
        #expect(await model.applyCalendarSelection(["study"]))
        #expect(Array(model.availableSlots.prefix(3)).map { DateInterval(start: $0.start, end: $0.end) } == [
            DateInterval(start: date(8), end: date(10)),
            DateInterval(start: date(12), end: date(14)),
            DateInterval(start: date(16), end: date(23))
        ])
        #expect(model.result.blocks == [
            ScheduledBlock(taskID: task.id, start: date(8), end: date(10)),
            ScheduledBlock(taskID: task.id, start: date(12), end: date(14)),
            ScheduledBlock(taskID: task.id, start: date(16), end: date(17))
        ])
        #expect(model.result.unscheduledTaskIDs.isEmpty)
        #expect(http.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "www.googleapis.com" })
    }

    @Test func calendarListPaginationFiltersUnreadableAndDeletedCalendars() async throws {
        let http = MockGoogleHTTP()
        http.responses = [
            (200, #"{"nextPageToken":"page-2","items":[{"id":"z","summary":"Z","accessRole":"reader"},{"id":"busy","summary":"Busy","accessRole":"freeBusyReader"}]}"#),
            (200, #"{"items":[{"id":"a","summary":"A","summaryOverride":"Alias","accessRole":"owner"},{"id":"deleted","summary":"D","accessRole":"writer","deleted":true}]}"#)
        ]
        let sources = try await GoogleCalendarService(tokens: MockGoogleTokens(), transport: http).loadCalendars()
        #expect(sources.map(\.id) == ["a", "z"])
        #expect(sources[0].title == "Alias")
        #expect(query(http.requests[1], "pageToken") == "page-2")
        #expect(query(http.requests[0], "minAccessRole") == "reader")
        #expect(http.requests.allSatisfy { $0.url?.query?.contains("access_token") == false })
    }

    @Test func onlySelectedCalendarsAreReadWithSafePathEncodingAndPagination() async throws {
        let http = MockGoogleHTTP()
        http.responses = [
            (200, #"{"timeZone":"UTC","nextPageToken":"next","items":[{"id":"cancel","status":"cancelled"}]}"#),
            (200, #"{"timeZone":"UTC","items":[{"id":"e","summary":"授業","start":{"dateTime":"2026-10-06T10:00:00Z"},"end":{"dateTime":"2026-10-06T12:00:00Z"}}]}"#)
        ]
        let service = GoogleCalendarService(tokens: MockGoogleTokens(), transport: http, calendar: utc)
        let result = try await service.loadEvents(in: range, calendarIDs: ["user+calendar/a@group.calendar.google.com"])
        #expect(result.count == 1)
        #expect(http.requests.count == 2)
        #expect(http.requests[0].url?.absoluteString.contains("%2F") == true)
        #expect(query(http.requests[0], "singleEvents") == "true")
        #expect(query(http.requests[0], "showDeleted") == "false")
        #expect(query(http.requests[0], "timeMin") == "2026-10-06T00:00:00Z")
        #expect(query(http.requests[1], "pageToken") == "next")
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
    }

    @Test func emptySelectionMakesNoRequestsAndMultipleSelectionsStaySeparate() async throws {
        let http = MockGoogleHTTP()
        let service = GoogleCalendarService(tokens: MockGoogleTokens(), transport: http, calendar: utc)
        #expect(try await service.loadEvents(in: range, calendarIDs: []).isEmpty)
        #expect(http.requests.isEmpty)
        http.responses = [(200, #"{"items":[]}"#), (200, #"{"items":[]}"#)]
        _ = try await service.loadEvents(in: range, calendarIDs: ["work", "study"])
        #expect(http.requests.map { $0.url!.path } == [
            "/calendar/v3/calendars/study/events", "/calendar/v3/calendars/work/events"
        ])
    }

    @Test func unauthorizedRequestRefreshesOnceAndRetries() async throws {
        let http = MockGoogleHTTP()
        let tokens = MockGoogleTokens()
        http.responses = [(401, "synthetic-private-error"), (200, calendars)]
        _ = try await GoogleCalendarService(tokens: tokens, transport: http).loadCalendars()
        #expect(tokens.refreshes == [false, true])
        #expect(http.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-refreshed-access")
    }

    @Test func repeatedUnauthorizedResponseStopsAfterOneRetry() async {
        let http = MockGoogleHTTP()
        http.responses = [(401, ""), (401, "")]
        do { _ = try await GoogleCalendarService(tokens: MockGoogleTokens(), transport: http).loadCalendars(); Issue.record("Unexpected success") }
        catch { #expect(error as? GoogleCalendarError == .authentication) }
        #expect(http.requests.count == 2)
    }

    @Test(arguments: [403, 404, 429, 500, 302])
    func httpFailuresDoNotExposeResponseBodies(status: Int) async {
        let http = MockGoogleHTTP()
        http.responses = [(status, "synthetic-private-calendar-and-token-detail")]
        do { _ = try await GoogleCalendarService(tokens: MockGoogleTokens(), transport: http).loadCalendars(); Issue.record("Unexpected success") }
        catch {
            #expect(!error.localizedDescription.contains("synthetic-private"))
        }
    }

    @Test func repeatedPaginationTokenFailsRatherThanReturningPartialData() async {
        let http = MockGoogleHTTP()
        http.responses = [(200, #"{"nextPageToken":"same","items":[]}"#), (200, #"{"nextPageToken":"same","items":[]}"#)]
        do { _ = try await GoogleCalendarService(tokens: MockGoogleTokens(), transport: http).loadCalendars(); Issue.record("Unexpected success") }
        catch { #expect(error as? GoogleCalendarError == .invalidResponse) }
        #expect(http.requests.count == 2)
    }

    @Test func refreshChangesFutureScheduleAndFailedPageRetainsSnapshot() async {
        let http = MockGoogleHTTP()
        let model = ScheduleViewModel(tasks: [PersonalGantt.Task(title: "作業", estimatedMinutes: 180, deadline: date(23))],
            calendarProvider: GoogleCalendarService(tokens: MockGoogleTokens(), transport: http, calendar: utc), activitySettings: .legacyFixture,
            calendar: utc, clock: { date(0) })
        http.responses = [(200, calendars), (200, exampleEvents)]
        #expect(await model.applyCalendarSelection(["study"]))
        http.responses = [(200, calendars), (200, #"{"items":[{"id":"changed","start":{"dateTime":"2026-10-06T08:00:00Z"},"end":{"dateTime":"2026-10-06T16:00:00Z"}}]}"#)]
        await model.refreshCalendars()
        #expect(model.result.blocks.first?.start == date(16))
        let before = model.result
        let slots = model.availableSlots
        let fixed = model.fixedEvents
        http.responses = [(200, calendars), (200, #"{"nextPageToken":"next","items":[]}"#), (500, "private-response")]
        await model.refreshCalendars()
        #expect(model.result == before && model.availableSlots == slots && model.fixedEvents == fixed)
        #expect(model.calendarMessage?.contains("private-response") == false)
    }

    @Test func taskEditDuringFetchIsUsedByPublishedPlan() async throws {
        let http = MockGoogleHTTP()
        let task = PersonalGantt.Task(title: "旧名", estimatedMinutes: 30, deadline: date(23))
        let model = ScheduleViewModel(tasks: [task], calendarProvider: GoogleCalendarService(tokens: MockGoogleTokens(), transport: http, calendar: utc), activitySettings: .legacyFixture,
                                      calendar: utc, clock: { date(0) })
        http.responses = [(200, calendars), (200, exampleEvents)]
        var changed = false
        http.onSend = {
            if !changed {
                changed = true
                try? model.updateTask(id: task.id, draft: TaskDraft(title: "新名", estimatedMinutesText: "180", deadline: date(23)))
            }
        }
        #expect(await model.applyCalendarSelection(["study"]))
        #expect(model.tasks[0].title == "新名")
        #expect(model.scheduledMinutes(for: task.id) == 180)
    }

    private var calendars: String { #"{"items":[{"id":"study","summary":"学業","accessRole":"owner"}]}"# }
    private var exampleEvents: String {
        #"{"timeZone":"UTC","items":[{"id":"class","summary":"授業","start":{"dateTime":"2026-10-06T10:00:00Z"},"end":{"dateTime":"2026-10-06T12:00:00Z"}},{"id":"job","summary":"バイト","start":{"dateTime":"2026-10-06T14:00:00Z"},"end":{"dateTime":"2026-10-06T16:00:00Z"}}]}"#
    }
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var range: DateInterval { DateInterval(start: date(0), end: date(0, day: 20)) }
    private func date(_ hour: Int, day: Int = 6) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
