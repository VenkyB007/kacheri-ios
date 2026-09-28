import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google sign-in for the web view shell. Google refuses OAuth inside web views, so sign-in runs
/// in the system browser sheet and the session is handed back (server side: Passport's
/// lib/app-handoff.js — the same flow as the Android SignInHandoff):
///
///  1. `start` makes a random verifier and opens an ASWebAuthenticationSession on
///     /app-auth/start with sha256(verifier) as the challenge.
///  2. The person signs in there; Passport sends the sheet to `ridewave://auth?code=…`, which
///     the session catches and closes on.
///  3. The caller loads the returned request: code + verifier POSTed to /app-auth/exchange
///     inside the web view, so the session cookie is set in the app.
///
/// The verifier only ever lives in memory: the sheet runs inside this app, so the app is alive
/// from start to finish.
final class SignInHandoff: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var session: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    /// True for the main-frame jump to Google's sign-in that the web login page makes.
    static func isGoogleSignIn(_ url: URL) -> Bool {
        url.host?.lowercased() == "accounts.google.com"
    }

    /// Calls back on the main thread with the exchange request, or nil if sign-in didn't finish.
    func start(anchor: UIWindow?, completion: @escaping (URLRequest?) -> Void) {
        guard session == nil else { return } // one sheet at a time
        let verifier = Self.randomVerifier()
        var start = URLComponents(url: Config.authURL, resolvingAgainstBaseURL: false)!
        start.path = "/app-auth/start"
        start.queryItems = [
            URLQueryItem(name: "app", value: Config.handoffApp),
            URLQueryItem(name: "challenge", value: Self.challenge(of: verifier)),
        ]

        let s = ASWebAuthenticationSession(url: start.url!, callbackURLScheme: Config.handoffScheme) { [weak self] returned, _ in
            DispatchQueue.main.async {
                self?.session = nil
                guard let returned, returned.host?.lowercased() == "auth",
                      let code = URLComponents(url: returned, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "code" })?.value
                else { return completion(nil) }
                completion(Self.exchange(code: code, verifier: verifier))
            }
        }
        s.presentationContextProvider = self
        // Share Safari's cookies, so someone already signed in to Google isn't asked again.
        s.prefersEphemeralWebBrowserSession = false
        self.anchor = anchor
        session = s
        if !s.start() {
            session = nil
            completion(nil)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    private static func exchange(code: String, verifier: String) -> URLRequest {
        var url = URLComponents(url: Config.authURL, resolvingAgainstBaseURL: false)!
        url.path = "/app-auth/exchange"
        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "code=\(formEncode(code))&verifier=\(formEncode(verifier))".data(using: .utf8)
        return req
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func challenge(of verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
