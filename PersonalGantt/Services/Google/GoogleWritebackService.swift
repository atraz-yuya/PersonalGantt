import Foundation
import CryptoKit

@MainActor final class GoogleWritebackService: CalendarWritebackProviding {
    private let tokens: any GoogleTokenProviding
    private let transport: any GoogleHTTPTransport
    init(tokens: any GoogleTokenProviding, transport: any GoogleHTTPTransport) { self.tokens = tokens; self.transport = transport }
    func authorize() async throws {
        if tokens.grantedScopes.contains(GoogleOAuthConfiguration.writebackScope) { return }
        guard let client = tokens as? GoogleOAuthClient else { throw WritebackError.insufficientScope }
        try await client.authorizeWriteback()
    }
    func publish(blocks: [ScheduledBlock], titles: [UUID: String], state: WritebackState, now: Date, calendar: Calendar) async throws -> WritebackState {
        guard state.enabled else { return state }
        guard tokens.grantedScopes.contains(GoogleOAuthConfiguration.writebackScope) else { throw WritebackError.insufficientScope }
        try state.validate()
        var next = state
        let destination = try await dedicatedCalendar(state)
        if destination != state.calendarID { next.calendarID = destination; next.events = [:] }
        let prefix = "/calendar/v3/calendars/\(encoded(destination))/events"
        func desiredEvents(protecting protectedIDs: Set<String>) -> [String: PublishedEvent] {
            var desired: [String: PublishedEvent] = [:], counts: [String: Int] = [:]
            for block in blocks.sorted(by: { $0.start == $1.start ? $0.taskID.uuidString < $1.taskID.uuidString : $0.start < $1.start }) {
                let day = calendar.startOfDay(for: block.start).timeIntervalSinceReferenceDate.bitPattern
                let group = "\(block.taskID)|\(day)"
                var ordinal = counts[group, default: 0]
                counts[group] = ordinal + 1
                // Begun blocks retain their ordinal even though they aren't published.
                guard block.start > now else { continue }
                var id: String
                repeat {
                    let seed = "\(state.publisherID)|\(group)|\(ordinal)"
                    id = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
                    ordinal += 1
                } while protectedIDs.contains(id)
                counts[group] = ordinal
                desired[id] = PublishedEvent(id: id, taskID: block.taskID, start: millisecondDate(block.start), end: millisecondDate(block.end),
                    title: titles[block.taskID] ?? "PersonalGantt", etag: "")
            }
            return desired
        }
        var desired = desiredEvents(protecting: Set(next.events.values.filter { $0.start <= now }.map(\.id)))
        // Discover owned events as well as checkpointed IDs. This recovers a
        // lost create response and cleans up future orphans after a partial run.
        var discovered: [String: RemoteEvent] = [:]
        var token: String?, seen: Set<String> = []
        repeat {
            var query = [URLQueryItem(name: "privateExtendedProperty", value: "personalGanttPublisher=" + state.publisherID.uuidString),
                         URLQueryItem(name: "maxResults", value: "2500")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page: EventPage = try await send("GET", prefix, query: query)
            for event in page.items ?? [] where event.status != "cancelled" {
                guard discovered.count < 10000 else { throw WritebackError.network }
                guard event.extendedProperties?.privateProperties?["personalGanttPublisher"] == state.publisherID.uuidString else { throw WritebackError.externalEdit }
                if let previous = next.events[event.id] {
                    if !event.matches(previous), desired[event.id].map({ !event.matches($0) }) ?? true { throw WritebackError.externalEdit }
                } else {
                    let restored = try event.published()
                    guard event.extendedProperties?.privateProperties?["personalGanttFingerprint"] == fingerprint(restored) else { throw WritebackError.externalEdit }
                    next.events[event.id] = restored
                }
                discovered[event.id] = event
            }
            token = page.nextPageToken
            if let token { guard seen.insert(token).inserted, seen.count < 1000 else { throw WritebackError.network } }
        } while token != nil
        for id in next.events.keys where discovered[id] == nil { throw WritebackError.externalEdit }
        // Also protect begun orphans recovered after a lost response/checkpoint.
        desired = desiredEvents(protecting: Set(next.events.values.filter { $0.start <= now }.map(\.id)))
        let remote = discovered
        for id in desired.keys.sorted() {
            let wanted = desired[id]!
            let event: RemoteEvent
            if let current = remote[id] {
                if current.matches(wanted) { event = current }
                else {
                    var patch = eventBody(wanted, publisher: state.publisherID); patch.removeValue(forKey: "id")
                    event = try await send("PATCH", prefix + "/" + id, body: patch, etag: current.etag)
                }
            } else {
                // Google accepts caller-provided base32hex IDs. A lost POST
                // response can be recovered by GET with the same ID next time.
                event = try await send("POST", prefix, body: eventBody(wanted, publisher: state.publisherID))
            }
            var stored = wanted; stored.etag = event.etag ?? ""; next.events[id] = stored
        }
        for (id, previous) in next.events.sorted(by: { $0.key < $1.key }) where desired[id] == nil && previous.start > now {
            if let current = remote[id] { try await delete(prefix + "/" + id, etag: current.etag) }
            next.events.removeValue(forKey: id)
        }
        return next
    }
    private func dedicatedCalendar(_ state: WritebackState) async throws -> String {
        let marker = "PersonalGantt publisher " + state.publisherID.uuidString
        if let id = state.calendarID {
            guard id != "primary", let existing: RemoteCalendar = try await get("/calendar/v3/calendars/" + encoded(id)),
                  existing.description == marker else { throw WritebackError.invalidDestination }
            return id
        }
        var token: String?, seen: Set<String> = []
        repeat {
            let page: CalendarPage = try await send("GET", "/calendar/v3/users/me/calendarList", query: token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            if let found = page.items?.first(where: { $0.description == marker }) { return found.id }
            token = page.nextPageToken
            if let token { guard seen.insert(token).inserted, seen.count < 1000 else { throw WritebackError.invalidDestination } }
        } while token != nil
        let created: RemoteCalendar = try await send("POST", "/calendar/v3/calendars", body: ["summary": "PersonalGantt", "description": marker])
        guard !created.id.isEmpty, created.id != "primary" else { throw WritebackError.invalidDestination }
        return created.id
    }
    private func eventBody(_ event: PublishedEvent, publisher: UUID) -> [String: Any] {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["id": event.id, "summary": event.title, "start": ["dateTime": formatter.string(from: event.start)],
            "end": ["dateTime": formatter.string(from: event.end)], "transparency": "opaque",
            "extendedProperties": ["private": ["personalGanttPublisher": publisher.uuidString, "personalGanttTask": event.taskID.uuidString, "personalGanttFingerprint": fingerprint(event)]]]
    }
    private func millisecondDate(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000) }
    private func fingerprint(_ event: PublishedEvent) -> String {
        let value = "\(event.title)|\(event.start.timeIntervalSinceReferenceDate.bitPattern)|\(event.end.timeIntervalSinceReferenceDate.bitPattern)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func encoded(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func get<T: Decodable>(_ path: String) async throws -> T? {
        let (data, status) = try await request("GET", path)
        if status == 404 || status == 410 { return nil }
        guard status == 200 else { throw WritebackError.network }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                    etag: String? = nil, query: [URLQueryItem] = []) async throws -> T {
        let (data, status) = try await request(method, path, body: body, etag: etag, query: query)
        if status == 412 { throw WritebackError.externalEdit }
        guard status == 200 || status == 201 else { throw WritebackError.network }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func delete(_ path: String, etag: String?) async throws {
        let (_, status) = try await request("DELETE", path, etag: etag)
        if status == 412 { throw WritebackError.externalEdit }
        guard [204,404,410].contains(status) else { throw WritebackError.network }
    }
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, etag: String? = nil,
                         query: [URLQueryItem] = []) async throws -> (Data, Int) {
        guard tokens.grantedScopes.contains(GoogleOAuthConfiguration.writebackScope) else { throw WritebackError.insufficientScope }
        var url = URLComponents(); url.scheme = "https"; url.host = "www.googleapis.com"; url.percentEncodedPath = path; url.queryItems = query.isEmpty ? nil : query
        for attempt in 0..<2 {
            var request = URLRequest(url: url.url!)
            let token = try await tokens.accessToken(forceRefresh: attempt == 1)
            guard tokens.grantedScopes.contains(GoogleOAuthConfiguration.writebackScope) else { throw WritebackError.insufficientScope }
            request.httpMethod = method; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await transport.send(request)
            if response.statusCode == 401 && attempt == 0 { continue }
            if response.statusCode == 401 || response.statusCode == 403 { throw WritebackError.insufficientScope }
            return (data, response.statusCode)
        }
        throw WritebackError.network
    }
    private struct RemoteCalendar: Decodable { let id: String; let description: String? }
    private struct CalendarPage: Decodable { let items: [RemoteCalendar]?; let nextPageToken: String? }
    private struct EventPage: Decodable { let items: [RemoteEvent]?; let nextPageToken: String? }
    private struct RemoteEvent: Decodable {
        let id: String; let etag: String?; let summary: String?; let status: String?
        let start: EventTime?; let end: EventTime?; let extendedProperties: Properties?
        struct EventTime: Decodable { let dateTime: String? }
        struct Properties: Decodable {
            let privateProperties: [String: String]?
            enum CodingKeys: String, CodingKey { case privateProperties = "private" }
        }
        private func instant(_ text: String?) -> Date? {
            guard let text else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }
        func published() throws -> PublishedEvent {
            guard let start = instant(start?.dateTime), let end = instant(end?.dateTime), start < end,
                  let task = extendedProperties?.privateProperties?["personalGanttTask"].flatMap(UUID.init(uuidString:)) else { throw WritebackError.externalEdit }
            return PublishedEvent(id: id, taskID: task, start: start, end: end, title: summary ?? "PersonalGantt", etag: etag ?? "")
        }
        func matches(_ event: PublishedEvent) -> Bool {
            id == event.id && summary == event.title && instant(start?.dateTime) == event.start && instant(end?.dateTime) == event.end
        }
    }
}
