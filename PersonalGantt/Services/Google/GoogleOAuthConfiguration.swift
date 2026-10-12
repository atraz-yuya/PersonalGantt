import Foundation
import CryptoKit
import Security

nonisolated struct GoogleOAuthConfiguration: Equatable, Sendable {
    let clientID: String
    var writebackEnabled = false
    static let writebackScope = "https://www.googleapis.com/auth/calendar.app.created"
    var authorizationScopes: Set<String> { writebackEnabled ? Self.scopes.union([Self.writebackScope]) : Self.scopes }
    static let scopes: Set<String> = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly"
    ]
    var callbackScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    var redirectURI: String { "\(callbackScheme):/oauthredirect" }
    var isValid: Bool {
        let suffix = ".apps.googleusercontent.com"
        let prefix = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : ""
        return !prefix.isEmpty && prefix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

nonisolated struct GoogleOAuthAttempt: Sendable {
    let configuration: GoogleOAuthConfiguration
    let verifier: String
    let state: String
    static func make(configuration: GoogleOAuthConfiguration) throws -> Self {
        guard configuration.isValid else { throw GoogleCalendarError.configuration }
        return try Self(configuration: configuration, verifier: random(), state: random())
    }
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
    var authorizationURL: URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.authorizationScopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account")
        ]
        return url.url!
    }
    func authorizationCode(from callback: URL) throws -> String {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == configuration.callbackScheme, url.host == nil,
              url.path == "/oauthredirect", url.fragment == nil else { throw GoogleCalendarError.invalidCallback }
        let items = url.queryItems ?? []
        // Reject ambiguity rather than accepting duplicate state/code parameters.
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == state else { throw GoogleCalendarError.invalidCallback }
        if single("error") == "access_denied" { throw GoogleCalendarError.cancelled }
        guard !items.contains(where: { $0.name == "error" }),
              let code = single("code"), !code.isEmpty else { throw GoogleCalendarError.invalidCallback }
        return code
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleCalendarError.authentication }
        return Data(bytes).base64URLEncoded
    }
}

private nonisolated extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
