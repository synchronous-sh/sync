import Foundation
import Security
import AuthenticationServices
import CryptoKit
import UIKit

/// Thin Supabase Auth client (Apple id_token + Google OAuth PKCE).
/// Uses the Auth REST API so we don't need the SPM package resolved to ship login.
enum SyncSupabase {
    static let redirectURL = URL(string: "synchronous://auth")!

    struct Session: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var userID: String
        var email: String?
        var expiresAt: Date

        var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
    }

    private static let sessionKey = "sync.supabase.session"
    private static let service = "sh.synchronous.sync.supabase"

    static var isConfigured: Bool {
        let url = SupabaseKeys.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SupabaseKeys.anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !key.isEmpty, url.hasPrefix("https://") else { return false }
        let placeholders = [
            "YOUR_PROJECT", "your-project", "your_anon_key", "your_key",
            "placeholder", "example", "changeme",
        ]
        if placeholders.contains(where: {
            url.localizedCaseInsensitiveContains($0) || key.localizedCaseInsensitiveContains($0)
        }) {
            return false
        }
        return true
    }

    static var currentSession: Session? {
        get { loadSession() }
        set {
            if let newValue {
                saveSession(newValue)
            } else {
                clearSession()
            }
        }
    }

    // MARK: - Auth

    static func signInWithApple(idToken: String, nonce: String? = nil) async throws -> Session {
        guard isConfigured else { throw AuthError.notConfigured }
        var body: [String: Any] = [
            "provider": "apple",
            "id_token": idToken,
        ]
        if let nonce, !nonce.isEmpty {
            body["nonce"] = nonce
        }
        let json = try await post(
            path: "/auth/v1/token?grant_type=id_token",
            body: body,
            authorized: false
        )
        return try session(from: json)
    }

    /// Opens Google in an auth session, then exchanges the PKCE code for a Supabase session.
    @MainActor
    static func signInWithGoogle() async throws -> Session {
        guard isConfigured else { throw AuthError.notConfigured }

        let verifier = randomVerifier()
        let challenge = base64URLEncoded(sha256(verifier))
        let root = SupabaseKeys.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var components = URLComponents(string: root + "/auth/v1/authorize")
        components?.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let authURL = components?.url else { throw AuthError.badResponse }

        let callbackURL = try await openAuthSession(url: authURL, callbackScheme: "synchronous")
        if let error = queryValue("error_description", in: callbackURL)
            ?? queryValue("error", in: callbackURL) {
            throw AuthError.server(error.replacingOccurrences(of: "+", with: " "))
        }
        guard let code = queryValue("code", in: callbackURL), !code.isEmpty else {
            throw AuthError.server("Google sign-in didn’t return an auth code.")
        }

        let json = try await post(
            path: "/auth/v1/token?grant_type=pkce",
            body: [
                "auth_code": code,
                "code_verifier": verifier,
            ],
            authorized: false
        )
        return try session(from: json)
    }

    static func restoreSession() async -> Session? {
        guard isConfigured, var session = loadSession() else { return nil }
        if !session.isExpired { return session }
        do {
            session = try await refresh(session.refreshToken)
            currentSession = session
            return session
        } catch {
            clearSession()
            return nil
        }
    }

    static func signOut() async {
        if let session = loadSession(), isConfigured {
            _ = try? await post(
                path: "/auth/v1/logout",
                body: [:],
                authorized: true,
                accessToken: session.accessToken,
                method: "POST"
            )
        }
        clearSession()
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case notConfigured
        case badResponse
        case canceled
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add your Supabase URL and anon key to SupabaseKeys.swift (see SupabaseKeys.example.swift)."
            case .badResponse:
                return "Supabase returned an unreadable auth response."
            case .canceled:
                return nil
            case .server(let message):
                return message
            }
        }
    }

    // MARK: - Networking

    private static func post(
        path: String,
        body: [String: Any],
        authorized: Bool,
        accessToken: String? = nil,
        method: String = "POST"
    ) async throws -> [String: Any] {
        let root = SupabaseKeys.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + path) else { throw AuthError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseKeys.anonKey, forHTTPHeaderField: "apikey")
        if authorized {
            let token = accessToken ?? loadSession()?.accessToken ?? SupabaseKeys.anonKey
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(SupabaseKeys.anonKey)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status >= 400 {
            let message = (object["error_description"] as? String)
                ?? (object["msg"] as? String)
                ?? (object["error"] as? String)
                ?? "Supabase auth failed (\(status))."
            throw AuthError.server(message)
        }
        return object
    }

    private static func refresh(_ refreshToken: String) async throws -> Session {
        let json = try await post(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": refreshToken],
            authorized: false
        )
        return try session(from: json)
    }

    private static func session(from json: [String: Any]) throws -> Session {
        guard
            let access = json["access_token"] as? String,
            let refresh = json["refresh_token"] as? String,
            let user = json["user"] as? [String: Any],
            let userID = user["id"] as? String
        else {
            throw AuthError.badResponse
        }
        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        let built = Session(
            accessToken: access,
            refreshToken: refresh,
            userID: userID,
            email: user["email"] as? String,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        currentSession = built
        return built
    }

    // MARK: - OAuth helpers

    @MainActor
    private static func openAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == ASWebAuthenticationSessionError.errorDomain,
                       ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AuthError.canceled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.badResponse)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = AuthPresentationAnchor.shared
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AuthError.server("Couldn’t open Google sign-in."))
            }
        }
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value {
            return value
        }
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            return nil
        }
        return fragment
            .split(separator: "&")
            .compactMap { part -> (String, String)? in
                let bits = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard bits.count == 2 else { return nil }
                return (bits[0], bits[1].removingPercentEncoding ?? bits[1])
            }
            .first { $0.0 == name }?
            .1
    }

    private static func randomVerifier(length: Int = 64) -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var value = ""
        value.reserveCapacity(length)
        for _ in 0..<length {
            var byte: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            value.append(charset[Int(byte) % charset.count])
        }
        return value
    }

    private static func sha256(_ input: String) -> Data {
        Data(SHA256.hash(data: Data(input.utf8)))
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private static func saveSession(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKey,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadSession() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private static func clearSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
private final class AuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return key
        }
        return scenes.flatMap(\.windows).first ?? ASPresentationAnchor()
    }
}
