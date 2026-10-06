import AuthenticationServices
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
protocol GoogleWebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// OS-owned browser UI; no embedded web view and no password handling.
@MainActor
final class GoogleWebAuthenticator: NSObject, GoogleWebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, any Error>?
    private var attemptID: UUID?
    private var anchor: ASPresentationAnchor?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard session == nil else { throw GoogleCalendarError.authentication }
        try _Concurrency.Task<Never, Never>.checkCancellation()
        #if os(macOS)
        anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        #else
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        #endif
        guard anchor != nil else { throw GoogleCalendarError.authentication }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                attemptID = id
                if _Concurrency.Task<Never, Never>.isCancelled {
                    finish(id: id, result: .failure(CancellationError()))
                    return
                }
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callback, error in
                    _Concurrency.Task { @MainActor in
                        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                            self?.finish(id: id, result: .failure(GoogleCalendarError.cancelled))
                        } else if let callback {
                            self?.finish(id: id, result: .success(callback))
                        } else {
                            self?.finish(id: id, result: .failure(GoogleCalendarError.authentication))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(id: id, result: .failure(GoogleCalendarError.authentication)) }
            }
        } onCancel: {
            _Concurrency.Task { @MainActor [weak self] in
                guard self?.attemptID == id else { return }
                self?.session?.cancel()
                self?.finish(id: id, result: .failure(CancellationError()))
            }
        }
    }

    private func finish(id: UUID, result: Result<URL, any Error>) {
        guard attemptID == id, let continuation = pending else { return }
        pending = nil
        attemptID = nil
        session = nil
        anchor = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Set before starting; the live UI always presents from an existing window.
        anchor!
    }
}
