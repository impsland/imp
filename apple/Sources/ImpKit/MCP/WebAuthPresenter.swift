import Foundation
import AuthenticationServices
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shows the authorization page in the system's web authentication sheet. Ephemeral: it shares no
/// cookies with Safari, so signing in never leaves the person signed in to the service in their browser.
public final class WebAuthPresenter: NSObject, MCPSignInPresenter, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    public override init() { super.init() }

    public func present(_ authorizeURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: callbackScheme) { url, error in
                    if let url { return cont.resume(returning: url) }
                    if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                        return cont.resume(throwing: MCPSignInError.cancelled)
                    }
                    cont.resume(throwing: MCPSignInError.failed(error?.localizedDescription ?? ""))
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = self
                self.running = session   // the session must outlive this closure
                if !session.start() { cont.resume(throwing: MCPSignInError.failed(String(localized: "The sign-in sheet could not open."))) }
            }
        }
    }

    private var running: ASWebAuthenticationSession?

    @MainActor public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
        #endif
    }
}
