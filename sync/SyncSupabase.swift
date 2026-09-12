import Foundation
import Security

/// Thin Supabase Auth client for Sign in with Apple (id_token grant).
/// Uses the Auth REST API so we don't need the SPM package resolved to ship login.
enum SyncSupabase {
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
        guard isConfigured else {
            throw AuthError.notConfigured
        }
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

    // MARK: - Types

    enum AuthError: LocalizedError {
        case notConfigured
        case badResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add your Supabase URL and anon key to SupabaseKeys.swift (see SupabaseKeys.example.swift)."
            case .badResponse:
                return "Supabase returned an unreadable auth response."
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
        let email = user["email"] as? String
        let session = Session(
            accessToken: access,
            refreshToken: refresh,
            userID: userID,
            email: email,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        currentSession = session
        return session
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
