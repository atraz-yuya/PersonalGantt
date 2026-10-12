import Foundation

@MainActor
protocol GoogleTokenProviding {
    var isSignedIn: Bool { get }
    var grantedScopes: Set<String> { get }
    func signIn() async throws
    func accessToken(forceRefresh: Bool) async throws -> String
    func signOut() throws
}

@MainActor extension GoogleTokenProviding {
    var grantedScopes: Set<String> { GoogleOAuthConfiguration.scopes }
}

@MainActor
final class GoogleOAuthClient: GoogleTokenProviding {
    let configuration: GoogleOAuthConfiguration
    private let storage: any GoogleCredentialStoring
    private let transport: any GoogleHTTPTransport
    private let authenticator: any GoogleWebAuthenticating
    private let clock: () -> Date

    init(configuration: GoogleOAuthConfiguration, storage: any GoogleCredentialStoring,
         transport: any GoogleHTTPTransport, authenticator: any GoogleWebAuthenticating,
         clock: @escaping () -> Date = { Date() }) {
        self.configuration = configuration
        self.storage = storage
        self.transport = transport
        self.authenticator = authenticator
        self.clock = clock
    }
    var grantedScopes: Set<String> {
        guard let value = try? storage.read(), value.clientID == configuration.clientID else { return [] }
        return value.scopes
    }
    func authorizeWriteback() async throws {
        let upgraded = GoogleOAuthClient(configuration: GoogleOAuthConfiguration(clientID: configuration.clientID, writebackEnabled: true),
            storage: storage, transport: transport, authenticator: authenticator, clock: clock)
        try await upgraded.signIn()
    }
    var isSignedIn: Bool {
        guard let value = try? storage.read() else { return false }
        return value.clientID == configuration.clientID && configuration.authorizationScopes.isSubset(of: value.scopes)
    }
    func signIn() async throws {
        let attempt = try GoogleOAuthAttempt.make(configuration: configuration)
        let callback = try await authenticator.authenticate(url: attempt.authorizationURL, callbackScheme: configuration.callbackScheme)
        let code = try attempt.authorizationCode(from: callback)
        let response = try await tokenRequest([
            "client_id": configuration.clientID, "code": code,
            "code_verifier": attempt.verifier, "redirect_uri": configuration.redirectURI,
            "grant_type": "authorization_code"
        ])
        // A new account must never inherit a previous account's refresh token.
        let credentials = try credential(response, previous: nil)
        try storage.write(credentials)
    }
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let previous = try storage.read(), previous.clientID == configuration.clientID,
              configuration.authorizationScopes.isSubset(of: previous.scopes) else { throw GoogleCalendarError.authentication }
        if !forceRefresh && previous.expiresAt > clock().addingTimeInterval(60) { return previous.accessToken }
        guard let refresh = previous.refreshToken else { throw GoogleCalendarError.authentication }
        do {
            let response = try await tokenRequest([
                "client_id": configuration.clientID, "refresh_token": refresh, "grant_type": "refresh_token"
            ])
            let updated = try credential(response, previous: previous)
            try storage.write(updated)
            return updated.accessToken
        } catch GoogleCalendarError.authentication {
            try storage.delete()
            throw GoogleCalendarError.authentication
        }
    }
    func signOut() throws { try storage.delete() }

    private func credential(_ response: TokenResponse, previous: GoogleCredentials?) throws -> GoogleCredentials {
        guard response.token_type.lowercased() == "bearer", !response.access_token.isEmpty,
              response.expires_in.isFinite, response.expires_in > 0 else { throw GoogleCalendarError.invalidResponse }
        let scopes = response.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        guard configuration.authorizationScopes.isSubset(of: scopes) else { throw GoogleCalendarError.insufficientScope }
        return GoogleCredentials(clientID: configuration.clientID, accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previous?.refreshToken,
            expiresAt: clock().addingTimeInterval(response.expires_in), scopes: scopes)
    }
    private func tokenRequest(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(parameters)
        let (data, response) = try await transport.send(request)
        if response.statusCode == 400 || response.statusCode == 401 {
            // Examine only the machine error code; never expose response bodies or request URLs.
            let error = try? JSONDecoder().decode(TokenFailure.self, from: data)
            if error?.error == "invalid_grant" { throw GoogleCalendarError.authentication }
            throw GoogleCalendarError.configuration
        }
        guard response.statusCode == 200 else { throw GoogleCalendarError.server }
        guard let value = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw GoogleCalendarError.invalidResponse }
        return value
    }
    static func formBody(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(parameters.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

private nonisolated struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Double
    let token_type: String
    let refresh_token: String?
    let scope: String?
}
private nonisolated struct TokenFailure: Decodable { let error: String }
