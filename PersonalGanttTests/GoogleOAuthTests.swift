import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct GoogleOAuthTests {
    private let configuration = GoogleOAuthConfiguration(clientID: "123-synthetic.apps.googleusercontent.com")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func pkceMatchesKnownS256VectorAndAttemptsAreUnique() throws {
        #expect(GoogleOAuthAttempt.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try GoogleOAuthAttempt.make(configuration: configuration)
        let second = try GoogleOAuthAttempt.make(configuration: configuration)
        #expect(first.verifier.count == 43)
        #expect(first.verifier != second.verifier && first.state != second.state)
    }

    @Test func authorizationOnlyRequestsReadScopesWithOfflinePkce() throws {
        let attempt = try GoogleOAuthAttempt.make(configuration: configuration)
        let query = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(attempt.authorizationURL.host == "accounts.google.com")
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(query.first { $0.name == "access_type" }?.value == "offline")
        #expect(Set(query.first { $0.name == "scope" }!.value!.split(separator: " ").map(String.init)) == GoogleOAuthConfiguration.scopes)
        #expect(!query.contains { ["client_secret", "access_token", "refresh_token"].contains($0.name) })
    }

    @Test(arguments: ["wrong-scheme:/oauthredirect?state=state&code=c",
        "com.googleusercontent.apps.123-synthetic:/wrong?state=state&code=c",
        "com.googleusercontent.apps.123-synthetic://host/oauthredirect?state=state&code=c",
        "com.googleusercontent.apps.123-synthetic:/oauthredirect?state=wrong&code=c",
        "com.googleusercontent.apps.123-synthetic:/oauthredirect?state=state&state=state&code=c",
        "com.googleusercontent.apps.123-synthetic:/oauthredirect?state=state&code=c&code=d",
        "com.googleusercontent.apps.123-synthetic:/oauthredirect?state=state"])
    func invalidCallbacksAreRejected(text: String) {
        let attempt = GoogleOAuthAttempt(configuration: configuration, verifier: "verifier", state: "state")
        #expect(throws: GoogleCalendarError.invalidCallback) { try attempt.authorizationCode(from: URL(string: text)!) }
    }

    @Test func consentDenialIsSanitized() {
        let attempt = GoogleOAuthAttempt(configuration: configuration, verifier: "verifier", state: "state")
        #expect(throws: GoogleCalendarError.cancelled) {
            try attempt.authorizationCode(from: URL(string: "\(configuration.redirectURI)?state=state&error=access_denied")!)
        }
    }

    @Test func successfulSignInStoresTokensAndUsesCodeVerifier() async throws {
        let storage = MemoryGoogleCredentials()
        let http = MockGoogleHTTP()
        let browser = MockGoogleBrowser()
        http.responses = [(200, tokenResponse(refresh: "synthetic-refresh"))]
        let client = makeClient(storage, http, browser)
        try await client.signIn()
        #expect(client.isSignedIn)
        #expect(storage.value?.refreshToken == "synthetic-refresh")
        #expect(storage.value?.expiresAt == now.addingTimeInterval(3600))
        let body = String(data: http.requests[0].httpBody!, encoding: .utf8)!
        #expect(body.contains("code_verifier="))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
        #expect(http.requests[0].url?.host == "oauth2.googleapis.com")
        #expect(try await client.accessToken(forceRefresh: false) == "synthetic-access")
        #expect(http.requests.count == 1)
    }

    @Test(arguments: ["cancel", "wrongState"])
    func cancelledOrInvalidLoginNeverExchangesOrReplacesCredentials(mode: String) async {
        let storage = MemoryGoogleCredentials()
        storage.value = credential()
        let original = storage.value
        let http = MockGoogleHTTP()
        let browser = MockGoogleBrowser()
        browser.mode = mode
        let client = makeClient(storage, http, browser)
        do { try await client.signIn(); Issue.record("Unexpected success") } catch {}
        #expect(storage.value == original)
        #expect(http.requests.isEmpty)
    }

    @Test func missingScopeDoesNotPublishTokens() async {
        let storage = MemoryGoogleCredentials()
        let http = MockGoogleHTTP()
        http.responses = [(200, tokenResponse(scope: "https://www.googleapis.com/auth/calendar.events.readonly"))]
        do { try await makeClient(storage, http).signIn(); Issue.record("Unexpected success") }
        catch { #expect(error as? GoogleCalendarError == .insufficientScope) }
        #expect(storage.value == nil)
    }

    @Test func refreshPreservesRefreshTokenWhenOmitted() async throws {
        let storage = MemoryGoogleCredentials()
        storage.value = credential(expires: now.addingTimeInterval(-1))
        let http = MockGoogleHTTP()
        http.responses = [(200, tokenResponse(access: "synthetic-new-access", scope: nil))]
        let client = makeClient(storage, http)
        #expect(try await client.accessToken(forceRefresh: false) == "synthetic-new-access")
        #expect(storage.value?.refreshToken == "synthetic-refresh")
        #expect(String(data: http.requests[0].httpBody!, encoding: .utf8)!.contains("grant_type=refresh_token"))
    }

    @Test func invalidGrantErasesLocalCredentialAndRequiresLogin() async {
        let storage = MemoryGoogleCredentials()
        storage.value = credential()
        let http = MockGoogleHTTP()
        http.responses = [(400, #"{"error":"invalid_grant","error_description":"synthetic-sensitive-detail"}"#)]
        let client = makeClient(storage, http)
        do { _ = try await client.accessToken(forceRefresh: true); Issue.record("Unexpected success") }
        catch { #expect(error as? GoogleCalendarError == .authentication) }
        #expect(storage.value == nil)
        #expect(!GoogleCalendarError.authentication.localizedDescription.contains("synthetic-sensitive-detail"))
    }

    @Test func transientRefreshFailureKeepsCredential() async {
        let storage = MemoryGoogleCredentials()
        storage.value = credential()
        let original = storage.value
        let http = MockGoogleHTTP()
        http.responses = [(500, "synthetic-sensitive-response")]
        do { _ = try await makeClient(storage, http).accessToken(forceRefresh: true); Issue.record("Unexpected success") } catch {}
        #expect(storage.value == original)
    }

    @Test func newLoginDoesNotReuseAnotherAccountsRefreshToken() async throws {
        let storage = MemoryGoogleCredentials()
        storage.value = credential()
        let http = MockGoogleHTTP()
        http.responses = [(200, tokenResponse())]
        try await makeClient(storage, http).signIn()
        #expect(storage.value?.refreshToken == nil)
    }

    @Test func keychainWriteFailureFailsLoginRatherThanPersistingElsewhere() async {
        let storage = MemoryGoogleCredentials()
        storage.failWrite = true
        let http = MockGoogleHTTP()
        http.responses = [(200, tokenResponse())]
        do { try await makeClient(storage, http).signIn(); Issue.record("Unexpected success") }
        catch { #expect(error as? GoogleCalendarError == .secureStorage) }
        #expect(storage.value == nil)
    }

    @Test func clientIdentityMismatchAndSignOutRejectStoredToken() async throws {
        let storage = MemoryGoogleCredentials()
        storage.value = GoogleCredentials(clientID: "other.apps.googleusercontent.com", accessToken: "synthetic-other",
            refreshToken: nil, expiresAt: now.addingTimeInterval(3600), scopes: GoogleOAuthConfiguration.scopes)
        let client = makeClient(storage, MockGoogleHTTP())
        #expect(!client.isSignedIn)
        do { _ = try await client.accessToken(forceRefresh: false); Issue.record("Unexpected success") }
        catch { #expect(error as? GoogleCalendarError == .authentication) }
        storage.value = credential()
        try client.signOut()
        #expect(storage.value == nil)
    }

    @Test(arguments: ["", "https://evil.example/client", "bad.apps.googleusercontent.com?query=x", " space.apps.googleusercontent.com"])
    func invalidConfigurationIsRejected(clientID: String) {
        #expect(!GoogleOAuthConfiguration(clientID: clientID).isValid)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let text = String(data: GoogleOAuthClient.formBody(["code": "a+b&c=d /"]), encoding: .utf8)!
        #expect(text == "code=a%2Bb%26c%3Dd%20%2F")
    }

    private func credential(expires: Date? = nil) -> GoogleCredentials {
        GoogleCredentials(clientID: configuration.clientID, accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                          expiresAt: expires ?? now.addingTimeInterval(3600), scopes: GoogleOAuthConfiguration.scopes)
    }
    private func makeClient(_ storage: MemoryGoogleCredentials, _ http: MockGoogleHTTP, _ browser: MockGoogleBrowser? = nil) -> GoogleOAuthClient {
        GoogleOAuthClient(configuration: configuration, storage: storage, transport: http, authenticator: browser ?? MockGoogleBrowser(), clock: { now })
    }
    private func tokenResponse(access: String = "synthetic-access", refresh: String? = nil,
                               scope: String? = GoogleOAuthConfiguration.scopes.sorted().joined(separator: " ")) -> String {
        var body: [String: Any] = ["access_token": access, "expires_in": 3600, "token_type": "Bearer"]
        if let refresh { body["refresh_token"] = refresh }
        if let scope { body["scope"] = scope }
        return String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
    }
}
