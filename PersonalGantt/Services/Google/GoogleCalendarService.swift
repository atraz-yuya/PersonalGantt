import Foundation

@MainActor
final class GoogleCalendarService: CalendarProviding {
    private let tokens: any GoogleTokenProviding
    private let transport: any GoogleHTTPTransport
    private let calendar: Calendar

    init(tokens: any GoogleTokenProviding, transport: any GoogleHTTPTransport, calendar: Calendar = .current) {
        self.tokens = tokens
        self.transport = transport
        self.calendar = calendar
    }
    static func live(clientID: String) -> GoogleCalendarService {
        let transport = GoogleURLSessionTransport()
        let oauth = GoogleOAuthClient(configuration: GoogleOAuthConfiguration(clientID: clientID),
            storage: GoogleKeychainCredentialStore(), transport: transport, authenticator: GoogleWebAuthenticator())
        return GoogleCalendarService(tokens: oauth, transport: transport)
    }
    var authorization: CalendarAuthorization { tokens.isSignedIn ? .connected : .signedOut }
    func requestAccess() async throws -> CalendarAuthorization {
        try await tokens.signIn()
        return authorization
    }
    func disconnect() throws { try tokens.signOut() }

    func loadCalendars() async throws -> [CalendarSource] {
        var result: [CalendarSource] = []
        var pageToken: String?
        var seen: Set<String> = []
        repeat {
            var query = [
                URLQueryItem(name: "minAccessRole", value: "reader"),
                URLQueryItem(name: "showDeleted", value: "false"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "fields", value: "nextPageToken,items(id,summary,summaryOverride,accessRole,deleted)")
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: CalendarPage = try await get(path: "/calendar/v3/users/me/calendarList", query: query)
            result += (page.items ?? []).filter { !$0.deleted && ["owner", "writer", "reader"].contains($0.accessRole ?? "") }.map {
                CalendarSource(id: $0.id, title: $0.summaryOverride ?? $0.summary ?? "名称未設定", accountTitle: "Google Calendar")
            }
            pageToken = try nextPage(page.nextPageToken, seen: &seen)
        } while pageToken != nil
        guard Set(result.map(\.id)).count == result.count else { throw GoogleCalendarError.invalidResponse }
        return result.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
    }

    func loadEvents(in range: DateInterval, calendarIDs: Set<String>) async throws -> [FixedEvent] {
        guard !calendarIDs.isEmpty else { return [] }
        guard range.start < range.end else { throw GoogleCalendarError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        var result: [FixedEvent] = []
        for id in calendarIDs.sorted() {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed), !id.isEmpty else {
                throw GoogleCalendarError.invalidResponse
            }
            var pageToken: String?
            var seen: Set<String> = []
            repeat {
                var query = [
                    URLQueryItem(name: "timeMin", value: formatter.string(from: range.start)),
                    URLQueryItem(name: "timeMax", value: formatter.string(from: range.end)),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "showDeleted", value: "false"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                    URLQueryItem(name: "maxResults", value: "2500"),
                    URLQueryItem(name: "fields", value: "nextPageToken,timeZone,items(id,summary,status,start,end)")
                ]
                if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let page: EventPage = try await get(path: "/calendar/v3/calendars/\(encoded)/events", query: query)
                for event in page.items ?? [] {
                    if let fixed = try event.fixedEvent(calendarID: id, calendarTimeZone: page.timeZone, activityCalendar: calendar),
                       fixed.start < range.end, range.start < fixed.end { result.append(fixed) }
                }
                pageToken = try nextPage(page.nextPageToken, seen: &seen)
            } while pageToken != nil
        }
        return result.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    private func nextPage(_ token: String?, seen: inout Set<String>) throws -> String? {
        guard let token, !token.isEmpty else { return nil }
        guard seen.insert(token).inserted, seen.count <= 1000 else { throw GoogleCalendarError.invalidResponse }
        return token
    }
    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = path
        components.queryItems = query
        guard let url = components.url else { throw GoogleCalendarError.invalidResponse }
        for attempt in 0...1 {
            let token = try await tokens.accessToken(forceRefresh: attempt == 1)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport.send(request)
            if response.statusCode == 401 {
                if attempt == 0 { continue }
                throw GoogleCalendarError.authentication
            }
            switch response.statusCode {
            case 200:
                guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw GoogleCalendarError.invalidResponse }
                return result
            case 403: throw GoogleCalendarError.forbidden
            case 404: throw CalendarServiceError.calendarUnavailable
            case 429: throw GoogleCalendarError.rateLimited
            default: throw GoogleCalendarError.server
            }
        }
        throw GoogleCalendarError.authentication
    }
}

private nonisolated struct CalendarPage: Decodable {
    let nextPageToken: String?
    let items: [CalendarEntry]?
}
private nonisolated struct CalendarEntry: Decodable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let accessRole: String?
    private let deletedValue: Bool?
    var deleted: Bool { deletedValue ?? false }
    enum CodingKeys: String, CodingKey {
        case id, summary, summaryOverride, accessRole
        case deletedValue = "deleted"
    }
}
private nonisolated struct EventPage: Decodable {
    let nextPageToken: String?
    let timeZone: String?
    let items: [GoogleCalendarEvent]?
}
