import Foundation
@testable import PersonalGantt

/// All credentials and calendar data in these doubles are synthetic.
@MainActor
final class MockGoogleHTTP: GoogleHTTPTransport {
    var responses: [(Int, String)] = []
    var requests: [URLRequest] = []
    var onSend: (() -> Void)?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        onSend?()
        guard !responses.isEmpty else { throw GoogleCalendarError.network }
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class MemoryGoogleCredentials: GoogleCredentialStoring {
    var value: GoogleCredentials?
    var failWrite = false
    func read() throws -> GoogleCredentials? { value }
    func write(_ credentials: GoogleCredentials) throws {
        if failWrite { throw GoogleCalendarError.secureStorage }
        value = credentials
    }
    func delete() throws { value = nil }
}

@MainActor
final class MockGoogleBrowser: GoogleWebAuthenticating {
    var mode = "success"
    var requests: [URL] = []
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        requests.append(url)
        if mode == "cancel" { throw GoogleCalendarError.cancelled }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let state = mode == "wrongState" ? "incorrect" : items.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: "\(callbackScheme):/oauthredirect")!
        callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "synthetic-code")]
        return callback.url!
    }
}

@MainActor
final class MockGoogleTokens: GoogleTokenProviding {
    var isSignedIn = true
    var refreshes: [Bool] = []
    func signIn() async throws { isSignedIn = true }
    func accessToken(forceRefresh: Bool) async throws -> String {
        guard isSignedIn else { throw GoogleCalendarError.authentication }
        refreshes.append(forceRefresh)
        return forceRefresh ? "synthetic-refreshed-access" : "synthetic-access"
    }
    func signOut() throws { isSignedIn = false }
}
