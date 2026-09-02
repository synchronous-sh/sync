import Foundation
import SwiftData
import Security

struct LibraryUnderstanding: Codable {
    var title: String?
    var summary: String?
    var topics: [String]?
    var entities: [String]?
    var collections: [String]?
    var contentType: String?
}

enum IntelligenceKey {
    private static let service = "sh.synchronous.sync.anthropic"

    static func load() -> String {
        BundledAPIKeys.resolved(service: service, bundled: BundledAPIKeys.anthropic)
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

enum LLMStamp {
    private static let key = "llmEnrichedSaveIDs"

    static func contains(_ id: UUID) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    static func mark(_ id: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func remove(_ id: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.remove(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum TitleLock {
    private static let key = "userLockedTitles"

    static func contains(_ id: UUID) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    static func mark(_ id: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

enum LibraryBrain {
    static func understand(
        save: SaveItem,
        existingCollections: [String],
        extraImages: [Data] = []
    ) async -> LibraryUnderstanding? {
        guard IntelligenceKey.isConfigured else { return nil }
        let material = promptMaterial(for: save, collections: existingCollections)
        var images = extraImages
        if images.isEmpty,
           MediaStore.playableURL(for: save) == nil,
           let url = MediaStore.fileURL(save.imageFileName),
           MediaStore.isVisualImage(save.imageFileName),
           let data = try? Data(contentsOf: url),
           let jpeg = Enrichment.jpegForModel(data) {
            images = [jpeg]
        }
        return await AnthropicLibrary.understand(material, images: images)
    }

    static func refineTitleAndNote(for save: SaveItem, request: String, title: String, notes: String) async -> (title: String, notes: String)? {
        guard IntelligenceKey.isConfigured else { return nil }
        let user = """
        User request: \(request)

        Existing title: \(title.isEmpty ? "(none)" : title)
        Existing notes: \(notes.isEmpty ? "(none)" : notes)

        SUMMARY:
        \(save.summary.isEmpty ? "(none)" : save.summary)

        Return JSON only: {"title":"...","notes":"..."}.
        Apply the request to the existing card. If they add a contact, email, phone, link, or reminder, append it to notes and keep the rest. Only change the title if they asked to. Return the full updated title and the full updated notes. No headings.
        """
        guard let text = await AnthropicLibrary.reply(
            system: "You patch a personal library card from a short user request. JSON only.",
            user: user,
            maxTokens: 400
        ) else { return nil }
        return parseTitleNotes(text)
    }

    private static func parseTitleNotes(_ raw: String) -> (title: String, notes: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        struct Draft: Codable { var title: String?; var notes: String? }
        guard let data = text.data(using: .utf8),
              let draft = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
        return (
            (draft.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            (draft.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func apply(
        _ result: LibraryUnderstanding,
        to save: SaveItem,
        context: ModelContext
    ) {
        if let summary = clean(result.summary), summary.count >= 24 {
            save.summary = String(summary.prefix(1600))
        }
        if !TitleLock.contains(save.saveID) {
            let proposed = clean(result.title).map { String($0.prefix(80)) }
            if let proposed, proposed.count >= 8, !TitleMeta.isClickbait(proposed) {
                save.title = proposed
            } else if !save.summary.isEmpty {
                let derived = TitleMeta.fromSummary(save.summary)
                if derived.count >= 8 {
                    save.title = derived
                }
            }
        }
        let topics = sanitizeList(result.topics, limit: 8, maxLen: 40)
        if !topics.isEmpty {
            save.topicsCSV = topics.joined(separator: ",")
        }
        let entities = sanitizeList(result.entities, limit: 10, maxLen: 48)
        if !entities.isEmpty {
            save.entitiesCSV = entities.joined(separator: ",")
        }
        if let typeRaw = result.contentType?.lowercased(),
           let kind = ContentKind(rawValue: typeRaw) {
            save.contentTypeRaw = kind.rawValue
        }
        let names = sanitizeList(result.collections, limit: 2, maxLen: 42)
        if !names.isEmpty {
            Enrichment.assignCollections(to: save, names: names, context: context)
        }
        LLMStamp.mark(save.saveID)
    }

    private static let queueKey = "llmWorkQueue"

    static func queueUnread(in context: ModelContext) {
        LLMStamp.clear()
        let items = (try? context.fetch(FetchDescriptor<SaveItem>())) ?? []
        UserDefaults.standard.set(items.map(\.saveID.uuidString), forKey: queueKey)
    }

    static func queuePlaceholders(_ items: [SaveItem]) {
        var ids = UserDefaults.standard.stringArray(forKey: queueKey) ?? []
        for save in items where save.processing == .saved {
            if !ids.contains(save.saveID.uuidString) {
                ids.append(save.saveID.uuidString)
            }
        }
        UserDefaults.standard.set(ids, forKey: queueKey)
    }

    static func nextQueued(in items: [SaveItem]) -> SaveItem? {
        let ids = UserDefaults.standard.stringArray(forKey: queueKey) ?? []
        return items.first {
            ids.contains($0.saveID.uuidString)
                && $0.processing == .saved
                && !LLMStamp.contains($0.saveID)
        }
    }

    static func dequeue(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: queueKey) ?? []
        ids.removeAll { $0 == id.uuidString }
        UserDefaults.standard.set(ids, forKey: queueKey)
    }

    @MainActor
    static func pull(context: ModelContext, reread save: SaveItem? = nil) {
        CaptureService.importInbox(into: context)
        CollectionHousekeeping.collapse(in: context)
        retitleFromSummaries(in: context)
        if let save {
            LLMStamp.remove(save.saveID)
            var ids = UserDefaults.standard.stringArray(forKey: queueKey) ?? []
            ids.removeAll { $0 == save.saveID.uuidString }
            ids.insert(save.saveID.uuidString, at: 0)
            UserDefaults.standard.set(ids, forKey: queueKey)
            save.processingRaw = ProcessingStatus.saved.rawValue
            try? context.save()
        }
        CaptureService.enrichUnprocessed(in: context)
    }

    static func relabelTitles(in context: ModelContext) {
        retitleFromSummaries(in: context)
    }

    private static func retitleFromSummaries(in context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<SaveItem>())) ?? []
        var changed = false
        for save in items {
            guard !TitleLock.contains(save.saveID) else { continue }
            guard TitleMeta.isClickbait(save.title) || TitleMeta.isPlaceholder(save.title) else { continue }
            guard !save.summary.isEmpty else { continue }
            let derived = TitleMeta.fromSummary(save.summary)
            guard derived.count >= 8, derived.caseInsensitiveCompare(save.title) != .orderedSame else { continue }
            save.title = derived
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func promptMaterial(for save: SaveItem, collections: [String]) -> String {
        let bags = collections.isEmpty
            ? Enrichment.collections.map(\.name).joined(separator: ", ")
            : collections.joined(separator: ", ")
        let body = [
            save.title,
            save.summary,
            save.creatorHandle,
            save.creatorName,
            save.sourceURL,
            save.rawText
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return """
        You organize a private personal library. Return JSON only with keys:
        title, summary, topics, entities, collections, contentType.

        An image or sampled video frames may be attached. READ on-screen text in every frame.
        Also use the spoken transcript and OCR block if present — that is the actual content.
        If several slides/frames are attached, the summary must cover every slide, not only the first.
        Never invent a niche (makeup, recipes, fashion, gym) unless it is visible, spoken, or written.

        title: 6–10 word library label of what the save is actually about, written after the summary. Sentence case. Never the viral overlay, never ALL CAPS, never a joke hook ("bends the knee", "you won't believe"). Example: "How Google settled the Epic Play billing fight" not "GOOGLE BENDS THE KNEE".
        summary: one tight paragraph (what this is and the point), then a blank line, then 3–5 lines that each start with "- " for the takeaways, steps, or facts. Use \\n for line breaks inside the JSON string. Ground every claim. No hashtags.
        topics: 3–6 lowercase topics taken from the actual content.
        entities: people, products, places, handles actually shown. Preserve casing.
        collections: 0–2 names. Prefer these existing collections: \(bags). Invent a name only if none fit.
        contentType: one of video, post, article, repository, image, text, product, place, music.
        For Spotify, entities must include the artist and track/playlist/album name. topics should be genre, campaign-useful labels (release, playlist, artist, sync, marketing), never just "spotify".

        Source: \(save.source.label)
        Material:
        \(String(body.prefix(3500)))
        """
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizeList(_ values: [String]?, limit: Int, maxLen: Int) -> [String] {
        guard let values else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.count >= 2, item.count <= maxLen else { continue }
            let key = item.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(item)
            if out.count >= limit { break }
        }
        return out
    }

}

enum AnthropicLibrary {
    struct ImageSource: Encodable {
        let type = "base64"
        let media_type: String
        let data: String
    }

    struct ContentPart: Encodable {
        let type: String
        var text: String?
        var source: ImageSource?

        enum CodingKeys: String, CodingKey {
            case type, text, source
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(source, forKey: .source)
        }
    }

    struct MessageRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: [ContentPart]
        }
        let model: String
        let max_tokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]
        var stream: Bool = false
    }

    struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    static func understand(_ material: String, images: [Data]) async -> LibraryUnderstanding? {
        let key = IntelligenceKey.load()
        guard !key.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        var parts: [ContentPart] = []
        for jpeg in images.prefix(4) {
            let payload = Enrichment.jpegForModel(jpeg) ?? jpeg
            parts.append(ContentPart(
                type: "image",
                text: nil,
                source: ImageSource(media_type: "image/jpeg", data: payload.base64EncodedString())
            ))
        }
        parts.append(ContentPart(type: "text", text: material, source: nil))
        let body = MessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 1100,
            temperature: 0.1,
            system: "Summarize only the attached frames, OCR, and transcript. JSON object only. Summary must be a paragraph then - bullets. No markdown fences.",
            messages: [.init(role: "user", content: parts)]
        )
        request.httpBody = try? JSONEncoder().encode(body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if !(200..<300).contains(http.statusCode) {
                let snippet = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                UserDefaults.standard.set(String(snippet.prefix(180)), forKey: "lastLLMError")
                return nil
            }
            UserDefaults.standard.removeObject(forKey: "lastLLMError")
            let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
            let text = decoded.content.compactMap(\.text).joined()
            return parseJSON(text)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "lastLLMError")
            return nil
        }
    }

    static func reply(
        system: String,
        user: String,
        images: [Data] = [],
        maxTokens: Int = 800,
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> String? {
        let key = IntelligenceKey.load()
        guard !key.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = onDelta == nil ? 40 : 90
        var parts: [ContentPart] = []
        for jpeg in images.prefix(4) {
            let payload = Enrichment.jpegForModel(jpeg) ?? jpeg
            parts.append(ContentPart(
                type: "image",
                text: nil,
                source: ImageSource(media_type: "image/jpeg", data: payload.base64EncodedString())
            ))
        }
        parts.append(ContentPart(type: "text", text: user, source: nil))
        let streaming = onDelta != nil
        let body = MessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: maxTokens,
            temperature: 0.2,
            system: system,
            messages: [.init(role: "user", content: parts)],
            stream: streaming
        )
        request.httpBody = try? JSONEncoder().encode(body)
        if streaming {
            return await streamReply(request: request, onDelta: onDelta)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
            let text = decoded.content.compactMap(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private static func streamReply(
        request: URLRequest,
        onDelta: (@MainActor (String) -> Void)?
    ) async -> String? {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            var full = ""
            var hold = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == "content_block_delta",
                      let delta = json["delta"] as? [String: Any],
                      let chunk = delta["text"] as? String, !chunk.isEmpty else { continue }
                hold += chunk
                let pieces = flushWords(from: &hold)
                if !pieces.isEmpty {
                    full += pieces
                    let shown = LibraryAsk.strippedHeading(full)
                    if let onDelta {
                        await onDelta(shown.isEmpty ? full : shown)
                    }
                }
            }
            if !hold.isEmpty {
                full += hold
            }
            let shown = LibraryAsk.strippedHeading(full)
            let out = shown.isEmpty ? full : shown
            if let onDelta, !out.isEmpty {
                await onDelta(out)
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
        } catch {
            return nil
        }
    }

    private static func flushWords(from hold: inout String) -> String {
        var out = ""
        while let i = hold.firstIndex(where: { $0.isWhitespace }) {
            let end = hold.index(after: i)
            out += hold[..<end]
            hold = String(hold[end...])
        }
        return out
    }

    private static func parseJSON(_ raw: String) -> LibraryUnderstanding? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LibraryUnderstanding.self, from: data)
    }
}
