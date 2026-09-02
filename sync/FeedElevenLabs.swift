import Foundation
import Security

enum ElevenLabsKey {
    private static let service = "sh.synchronous.sync.elevenlabs"

    static func load() -> String {
        BundledAPIKeys.resolved(service: service, bundled: BundledAPIKeys.elevenLabs)
    }

    static func save(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static var isConfigured: Bool { !load().isEmpty }
}

struct ElevenLabsVoice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var category: String
    var previewURL: URL?

    var subtitle: String {
        category.isEmpty ? "ElevenLabs" : category.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum ElevenLabsSpeech {
    static let defaultVoice = "nPczCjzI2devNBz1zQrb"
    static let defaultVoiceName = "Brian"
    private static let blockedVoiceIDs: Set<String> = ["Xb7hH8G0CnM2EvxU5F7n"]
    static let voiceIDKey = "elevenLabsVoiceID"
    static let voiceNameKey = "elevenLabsVoiceName"
    private static var memoryID = ""
    private static var memoryName = ""
    static var lastError = ""

    static var voiceID: String {
        get {
            if blockedVoiceIDs.contains(memoryID) { memoryID = "" }
            if !memoryID.isEmpty { return memoryID }
            memoryID = defaultVoice
            memoryName = defaultVoiceName
            UserDefaults.standard.set(defaultVoice, forKey: voiceIDKey)
            UserDefaults.standard.set(defaultVoiceName, forKey: voiceNameKey)
            AppGroup.defaults?.set(defaultVoice, forKey: voiceIDKey)
            AppGroup.defaults?.set(defaultVoiceName, forKey: voiceNameKey)
            return defaultVoice
        }
        set {
            memoryID = newValue
            UserDefaults.standard.set(newValue, forKey: voiceIDKey)
            AppGroup.defaults?.set(newValue, forKey: voiceIDKey)
        }
    }

    static var voiceName: String {
        get {
            if !memoryName.isEmpty { return memoryName }
            if let stored = AppGroup.defaults?.string(forKey: voiceNameKey), !stored.isEmpty {
                memoryName = stored.lowercased() == "alice" ? defaultVoiceName : stored
                return memoryName
            }
            let stored = UserDefaults.standard.string(forKey: voiceNameKey) ?? ""
            return stored.isEmpty || stored.lowercased() == "alice" ? defaultVoiceName : stored
        }
        set {
            memoryName = newValue
            UserDefaults.standard.set(newValue, forKey: voiceNameKey)
            AppGroup.defaults?.set(newValue, forKey: voiceNameKey)
        }
    }

    static func isAllowed(_ voice: ElevenLabsVoice) -> Bool {
        if blockedVoiceIDs.contains(voice.id) { return false }
        return voice.name.lowercased() != "alice"
    }

    static func select(_ voice: ElevenLabsVoice) {
        voiceID = voice.id
        voiceName = voice.name
        NotificationCenter.default.post(name: .feedVoiceDidChange, object: nil)
    }

    static func spokenText(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "\\n", with: "\n")
        out = out.replacingOccurrences(of: #"(?m)^-\s+"#, with: "", options: .regularExpression)
        return String(out.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cacheName(id: UUID, voice: String, text: String) -> String {
        let tag = voice.filter { $0.isLetter || $0.isNumber }
        let stamp = String(text.hashValue, radix: 16).replacingOccurrences(of: "-", with: "m")
        return "feed-\(id.uuidString)-\(tag)-\(stamp).mp3"
    }

    static func cachedURL(id: UUID, voice: String, text: String) -> URL? {
        MediaStore.fileURL(cacheName(id: id, voice: voice, text: text))
    }

    static func speak(_ text: String, id: UUID, voice: String? = nil, skipCache: Bool = false) async -> String? {
        let key = ElevenLabsKey.load()
        guard !key.isEmpty else { return nil }
        let clipped = spokenText(text)
        guard !clipped.isEmpty else { return nil }
        let chosen = (voice?.isEmpty == false) ? voice! : voiceID
        if !skipCache, let existing = cachedURL(id: id, voice: chosen, text: clipped) {
            return existing.lastPathComponent
        }
        lastError = ""
        let models = ["eleven_flash_v2_5", "eleven_turbo_v2_5", "eleven_multilingual_v2"]
        for model in models {
            if let file = await request(key: key, text: clipped, voice: chosen, model: model, id: id) {
                return file
            }
        }
        return nil
    }

    static func voices() async -> [ElevenLabsVoice] {
        let key = ElevenLabsKey.load()
        guard !key.isEmpty else { return fallbackVoices }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { return fallbackVoices }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["voices"] as? [[String: Any]] else {
            return fallbackVoices.filter(isAllowed)
        }
        let parsed: [ElevenLabsVoice] = raw.compactMap { item in
            guard let id = item["voice_id"] as? String, !id.isEmpty,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            return ElevenLabsVoice(
                id: id,
                name: name,
                category: item["category"] as? String ?? "",
                previewURL: (item["preview_url"] as? String).flatMap(URL.init(string:))
            )
        }
        .filter(isAllowed)
        return parsed.isEmpty ? fallbackVoices.filter(isAllowed) : parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let fallbackVoices: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "nPczCjzI2devNBz1zQrb", name: "Brian", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "FGY2WhTYpPnrIDTdsKH5", name: "Laura", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "TX3LPaxmHKxFdv7VOQHJ", name: "Liam", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "iP95p4xoKVk53GoZ742B", name: "Chris", category: "premade", previewURL: nil),
        ElevenLabsVoice(id: "cgSgspJ2msm6clMCkdW9", name: "Jessica", category: "premade", previewURL: nil),
    ]

    private static func request(key: String, text: String, voice: String, model: String, id: UUID) async -> String? {
        let encoded = voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voice
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(encoded)?output_format=mp3_44100_128") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": model
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !(200..<300).contains(code) || type.contains("json") || data.count < 200 {
                lastError = "Voice isn’t available right now."
                return nil
            }
            lastError = ""
            return MediaStore.save(data, named: cacheName(id: id, voice: voice, text: text))
        } catch {
            lastError = "Voice isn’t available right now."
            return nil
        }
    }
}

extension Notification.Name {
    static let feedVoiceDidChange = Notification.Name("feedVoiceDidChange")
    static let feedSpeechSpeedDidChange = Notification.Name("feedSpeechSpeedDidChange")
}
