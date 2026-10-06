import Foundation
import Security

nonisolated struct GoogleCredentials: Codable, Equatable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scopes: Set<String>
}

@MainActor
protocol GoogleCredentialStoring {
    func read() throws -> GoogleCredentials?
    func write(_ credentials: GoogleCredentials) throws
    func delete() throws
}

/// Device-local, unlocked-only Keychain storage; never written to files or UserDefaults.
@MainActor
final class GoogleKeychainCredentialStore: GoogleCredentialStoring {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.atraz.PersonalGantt.google.oauth",
            kSecAttrAccount as String: "calendar-reader",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
    func read() throws -> GoogleCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(GoogleCredentials.self, from: data)
        else { throw GoogleCalendarError.secureStorage }
        return value
    }
    func write(_ credentials: GoogleCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw GoogleCalendarError.secureStorage }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw GoogleCalendarError.secureStorage }
        } else if status != errSecSuccess { throw GoogleCalendarError.secureStorage }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleCalendarError.secureStorage }
    }
}
