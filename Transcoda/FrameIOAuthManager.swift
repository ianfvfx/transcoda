import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

// OAuth "Native App" (PKCE) login against Adobe IMS, the auth provider behind
// Frame.io V4 for accounts on Adobe Authentication. No backend server and no
// Enterprise plan required — this is the credential type built for exactly
// this kind of desktop app.
//
// NEEDS LIVE VERIFICATION once a real Adobe Developer Console app exists:
// - `authorizeEndpoint`/`tokenEndpoint` below are Adobe IMS's standard hosts:
//   solid for the token endpoint, less certain for the exact authorize path.
// - `scope` is a placeholder — fill in from whatever the Developer Console's
//   OAuth Native App credential screen actually offers for Frame.io access.
// - `clientID` must be filled in after registering the app (see chat).
// - Adobe IMS's `expires_in` has historically sometimes been reported in
//   milliseconds rather than seconds for some IMS-backed products — verify
//   against a real token response before trusting long-lived sessions.
@MainActor
final class FrameIOAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = FrameIOAuthManager()

    @Published private(set) var isAuthenticated: Bool = false

    private enum Config {
        static let clientID = "a8f0855251604724a31f3456e451716a"
        // Adobe auto-generates this per-credential scheme (rather than letting
        // the app pick one) to guarantee no collisions across apps using
        // Adobe IMS — not editable in the Developer Console, used verbatim.
        static let redirectScheme = "adobe+b085406cc1a28d1501b0a00d19c0498b1d8e1899"
        static let redirectURI = "adobe+b085406cc1a28d1501b0a00d19c0498b1d8e1899://adobeid/a8f0855251604724a31f3456e451716a"
        static let authorizeEndpoint = "https://ims-na1.adobelogin.com/ims/authorize/v2"
        static let tokenEndpoint = "https://ims-na1.adobelogin.com/ims/token/v3"
        // offline_access is required for Adobe IMS to issue a refresh token at
        // all — without it every access-token expiry would force a fresh
        // interactive login instead of a silent refresh.
        static let scope = "openid,offline_access,email,additional_info.roles,profile"
    }

    private enum Keys {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let expiresAt = "expires_at"
    }

    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        isAuthenticated = !isExpired(bufferSeconds: 60)
    }

    // MARK: - Public API

    // Silently refreshes if the access token is expired but a refresh token
    // is on hand; falls all the way back to an interactive login only when
    // there's nothing usable in the Keychain yet (first run) or the refresh
    // token itself has expired (Adobe's ~14 day default for this credential
    // type — expected to happen occasionally, not a bug).
    func ensureAuthenticated(completion: @escaping (Result<Void, Error>) -> Void) {
        if !isExpired(bufferSeconds: 60) {
            completion(.success(()))
            return
        }
        if KeychainStore.get(Keys.refreshToken) != nil {
            refreshAccessToken { [weak self] result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure:
                    self?.login(completion: completion)
                }
            }
        } else {
            login(completion: completion)
        }
    }

    // Used transparently by FrameIOAPIClient before every request.
    func validAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        ensureAuthenticated { result in
            switch result {
            case .success:
                if let token = KeychainStore.get(Keys.accessToken) {
                    completion(.success(token))
                } else {
                    completion(.failure(FrameIOError.notAuthenticated))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func signOut() {
        KeychainStore.delete(Keys.accessToken)
        KeychainStore.delete(Keys.refreshToken)
        KeychainStore.delete(Keys.expiresAt)
        isAuthenticated = false
    }

    // MARK: - Login (PKCE)

    private func login(completion: @escaping (Result<Void, Error>) -> Void) {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: Config.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Config.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authURL = components?.url else {
            completion(.failure(FrameIOError.notAuthenticated))
            return
        }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: Config.redirectScheme
        ) { [weak self] callbackURL, error in
            // System completion handlers aren't guaranteed to be MainActor-
            // isolated by the compiler even though self is — hop explicitly.
            // (This whole login() flow is the highest-uncertainty part of the
            // plan; verify it builds clean in Xcode against real credentials
            // before trusting it further.)
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let nsError = error as NSError
                    let isCancel = nsError.domain == ASWebAuthenticationSessionErrorDomain
                        && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                    completion(.failure(isCancel ? FrameIOError.cancelled : error))
                    return
                }
                guard let callbackURL,
                      let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    completion(.failure(FrameIOError.notAuthenticated))
                    return
                }
                self.exchangeCodeForToken(code: code, verifier: verifier, completion: completion)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    // MARK: - Token exchange / refresh

    private func exchangeCodeForToken(code: String, verifier: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let params = [
            "grant_type": "authorization_code",
            "client_id": Config.clientID,
            "code": code,
            "redirect_uri": Config.redirectURI,
            "code_verifier": verifier
        ]
        postTokenRequest(params: params, completion: completion)
    }

    private func refreshAccessToken(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let refreshToken = KeychainStore.get(Keys.refreshToken) else {
            completion(.failure(FrameIOError.notAuthenticated))
            return
        }
        let params = [
            "grant_type": "refresh_token",
            "client_id": Config.clientID,
            "refresh_token": refreshToken
        ]
        postTokenRequest(params: params, completion: completion)
    }

    private func postTokenRequest(params: [String: String], completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: URL(string: Config.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formURLEncode(params).utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleTokenResponse(data: data, response: response, error: error, completion: completion)
            }
        }.resume()
    }

    private func handleTokenResponse(data: Data?, response: URLResponse?, error: Error?, completion: @escaping (Result<Void, Error>) -> Void) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let http = response as? HTTPURLResponse, let data else {
            completion(.failure(FrameIOError.notAuthenticated))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completion(.failure(FrameIOError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")))
            return
        }
        do {
            let token = try JSONDecoder().decode(TokenResponse.self, from: data)
            KeychainStore.set(token.accessToken, forKey: Keys.accessToken)
            if let refreshToken = token.refreshToken {
                KeychainStore.set(refreshToken, forKey: Keys.refreshToken)
            }
            let expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn)).timeIntervalSince1970
            KeychainStore.set(String(expiresAt), forKey: Keys.expiresAt)
            isAuthenticated = true
            completion(.success(()))
        } catch {
            completion(.failure(FrameIOError.decoding(error)))
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    // MARK: - Helpers

    private func isExpired(bufferSeconds: TimeInterval) -> Bool {
        guard let token = KeychainStore.get(Keys.accessToken), !token.isEmpty else { return true }
        guard let expiresAtString = KeychainStore.get(Keys.expiresAt),
              let expiresAt = TimeInterval(expiresAtString) else { return true }
        return Date().timeIntervalSince1970 + bufferSeconds >= expiresAt
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formURLEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
