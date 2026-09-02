import Foundation
import SwiftData

enum LibraryAsk {
    private static var insightCache: [UUID: VideoRead.Insight] = [:]

    struct Result {
        var answer: String
        var citations: [SaveItem]
    }

    static func answer(
        question: String,
        from saves: [SaveItem],
        focus: String? = nil,
        primary: SaveItem? = nil,
        history: [(String, String)] = [],
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> Result {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return Result(answer: "", citations: [])
        }

        var frames: [Data] = []
        if let primary {
            frames = await loadEvidence(for: primary)
        }

        let pool: [SaveItem]
        if let primary {
            pool = [primary]
        } else {
            var hits = LibrarySearch.results(query: q, in: saves)
            if hits.isEmpty { hits = Array(saves.prefix(14)) }
            pool = Array((hits + Array(saves.prefix(6))).uniquedByID().prefix(12))
        }

        if IntelligenceKey.isConfigured,
           let generated = await grounded(
            question: q,
            saves: pool,
            focus: focus,
            images: frames,
            history: history,
            onDelta: onDelta
           ) {
            return generated
        }

        let fallback = LibrarySearch.ask(query: q, in: saves)
        return Result(answer: fallback.answer, citations: fallback.citations)
    }

    @MainActor
    private static func loadEvidence(for save: SaveItem) async -> [Data] {
        if let cached = insightCache[save.saveID], !cached.frames.isEmpty {
            mergeInsight(cached, into: save)
            return Array(cached.frames.prefix(4))
        }

        if let url = MediaStore.playableURL(for: save) {
            let insight = await VideoRead.inspect(url)
            insightCache[save.saveID] = insight
            mergeInsight(insight, into: save)
            return Array(insight.frames.prefix(4))
        }

        if save.source == .youtube, let link = URL(string: save.sourceURL) {
            let captions = await YouTubeCaptions.transcript(from: link)
            if !captions.isEmpty, !save.rawText.contains(captions) {
                save.rawText = [save.rawText, "Spoken:\n\(captions)"].filter { !$0.isEmpty }.joined(separator: "\n")
                try? save.modelContext?.save()
            }
        }

        if let url = MediaStore.fileURL(save.imageFileName),
           MediaStore.isVisualImage(save.imageFileName),
           let data = try? Data(contentsOf: url),
           let jpeg = Enrichment.jpegForModel(data) {
            return [jpeg]
        }
        return []
    }

    private static func mergeInsight(_ insight: VideoRead.Insight, into save: SaveItem) {
        var chunks = save.rawText
        if !insight.ocr.isEmpty, !chunks.contains(insight.ocr) {
            chunks = [chunks, "On-screen:\n\(insight.ocr)"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if !insight.transcript.isEmpty, !chunks.contains(insight.transcript) {
            chunks = [chunks, "Spoken:\n\(insight.transcript)"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        save.rawText = chunks
        try? save.modelContext?.save()
    }

    private static func grounded(
        question: String,
        saves: [SaveItem],
        focus: String?,
        images: [Data],
        history: [(String, String)],
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> Result? {
        guard let save = saves.first else { return nil }
        let spoken = slice(save.rawText, after: "Spoken:")
        let onScreen = slice(save.rawText, after: "On-screen:")
        let prior = history.suffix(10).map { role, text in
            "\(role == "user" ? "User" : "Assistant"): \(text)"
        }.joined(separator: "\n")
        let user = """
        \(prior.isEmpty ? "" : "Conversation so far:\n\(prior)\n\n")
        New question: \(question)
        \(focus.map { "Open save: \($0)" } ?? "")

        SUMMARY:
        \(save.summary.isEmpty ? "(none)" : save.summary)

        TRANSCRIPT (spoken):
        \(spoken.isEmpty ? "(none — use frames and summary)" : String(spoken.prefix(5000)))

        ON-SCREEN TEXT FROM FRAMES:
        \(onScreen.isEmpty ? "(see attached frames)" : String(onScreen.prefix(2500)))

        Attached images are sampled video frames (or the thumbnail if no file). Answer from transcript + frames + summary, and stay consistent with the conversation so far.
        """
        guard let text = await AnthropicLibrary.reply(
            system: """
            Answer using only the summary, spoken transcript, on-screen OCR, and attached frames.
            If the user asks what someone said, quote or tightly paraphrase the TRANSCRIPT.
            Do not say you lack the content if a summary, transcript, or frames are present.
            Never tell them to watch the video. Paragraph then bullets when listing points.
            Never start with a heading, title, or "Response to …". Just answer.
            """,
            user: user,
            images: images,
            maxTokens: 900,
            onDelta: onDelta
        ) else { return nil }
        return Result(answer: strippedHeading(text), citations: [save])
    }

    static func strippedHeading(_ raw: String) -> String {
        var lines = raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .components(separatedBy: .newlines)
        while let first = lines.first {
            let t = first.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                lines.removeFirst()
                continue
            }
            let lower = t.lowercased()
            if t.hasPrefix("#") || lower.hasPrefix("response to") || lower.hasPrefix("answer to") {
                lines.removeFirst()
                continue
            }
            break
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slice(_ raw: String, after marker: String) -> String {
        guard let range = raw.range(of: marker) else {
            return marker == "Spoken:" ? raw : ""
        }
        let rest = raw[range.upperBound...]
        if let next = rest.range(of: "On-screen:"), marker == "Spoken:" {
            return String(rest[..<next.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let next = rest.range(of: "Spoken:"), marker == "On-screen:" {
            return String(rest[..<next.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum YouTubeCaptions {
    static func transcript(from url: URL) async -> String {
        guard let id = MediaEmbed.youtubeID(from: url) else { return "" }
        let listURL = URL(string: "https://www.youtube.com/api/timedtext?type=list&v=\(id)")
        guard let listURL else { return "" }
        var listRequest = URLRequest(url: listURL)
        listRequest.timeoutInterval = 8
        listRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (listData, _) = try? await URLSession.shared.data(for: listRequest),
              let listXML = String(data: listData, encoding: .utf8),
              let lang = firstLang(in: listXML) else { return "" }
        let track = URL(string: "https://www.youtube.com/api/timedtext?lang=\(lang)&v=\(id)&fmt=srv3")
        guard let track else { return "" }
        var trackRequest = URLRequest(url: track)
        trackRequest.timeoutInterval = 8
        trackRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: trackRequest),
              let xml = String(data: data, encoding: .utf8) else { return "" }
        return stripXML(xml)
    }

    private static func firstLang(in xml: String) -> String? {
        if xml.contains("lang_code=\"en\"") { return "en" }
        let pattern = #"lang_code="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              let langRange = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[langRange])
    }

    private static func stripXML(_ xml: String) -> String {
        let noTags = xml.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == SaveItem {
    func uniquedByID() -> [SaveItem] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.saveID).inserted }
    }
}
