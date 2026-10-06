import Foundation

nonisolated enum GoogleCalendarError: LocalizedError, Equatable {
    case configuration, authentication, cancelled, invalidCallback, insufficientScope
    case secureStorage, network, invalidResponse, forbidden, rateLimited, server
    var errorDescription: String? {
        switch self {
        case .configuration: "Google Cloudで作成したiOSタイプのOAuthクライアントIDを設定してください。"
        case .authentication: "Googleへの再ログインが必要です。"
        case .cancelled: "Googleログインをキャンセルしました。"
        case .invalidCallback: "認証応答を検証できませんでした。ログインをやり直してください。"
        case .insufficientScope: "Calendar一覧とイベントの読み取りを両方許可してください。"
        case .secureStorage: "認証情報をKeychainへ保存・取得できません。署名設定とKeychainを確認してください。"
        case .network: "Googleへ接続できません。ネットワークを確認して再読み込みしてください。"
        case .invalidResponse: "Googleの応答を解釈できません。現在の予定を保持します。"
        case .forbidden: "Google Calendarを読み取れません。APIの有効化、許可範囲、Calendarへのアクセスを確認してください。"
        case .rateLimited: "Googleの取得回数制限に達しました。時間をおいて再読み込みしてください。"
        case .server: "Google側で取得に失敗しました。時間をおいて再読み込みしてください。"
        }
    }
}

@MainActor
protocol GoogleHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral transport: no token-bearing response cache, cookies, or redirected credentials.
@MainActor
final class GoogleURLSessionTransport: GoogleHTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: NoGoogleRedirects(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as GoogleCalendarError { throw error }
        catch { throw GoogleCalendarError.network }
    }
}

private final class NoGoogleRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
