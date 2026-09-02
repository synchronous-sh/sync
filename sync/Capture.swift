import Foundation
import SwiftData
import UIKit

enum SourceAdapter {
    static func detect(url: URL?, text: String?, hasImage: Bool) -> (SourceKind, ContentKind) {
        SourceDetect.kind(url: url, text: text, hasImage: hasImage)
    }

    static func canonicalize(_ raw: String) -> String {
        SharedLinkParser.canonicalize(raw)
    }

    static func displayTitle(url: URL?, text: String?, source: SourceKind) -> String {
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, URL(string: trimmed) == nil || !trimmed.contains("://") {
                return String(trimmed.prefix(80))
            }
        }
        if let url {
            if SpotifyLink.matches(url) {
                return "Spotify \(SpotifyLink.displayKind(url))"
            }
            let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? source.label
            let last = url.path.split(separator: "/").last.map(String.init) ?? ""
            if last.count > 2, last != "watch" { return "\(host)/\(last)" }
            return host
        }
        return "Saved item"
    }
}

enum CaptureService {
    struct Result {
        let save: SaveItem
        let wasDuplicate: Bool
    }

    @discardableResult
    static func ingest(
        urlString: String?,
        text: String?,
        imageData: Data?,
        mediaFileName: String? = nil,
        slideFileNames: [String] = [],
        context: ModelContext
    ) -> Result {
        let cleanedURL = SharedLinkParser.url(from: urlString) ?? urlString
        let parsedURL = cleanedURL.flatMap { URL(string: $0) }
        let canonical = parsedURL.map { SourceAdapter.canonicalize($0.absoluteString) } ?? ""

        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = imageData != nil
        if (cleanedURL == nil || cleanedURL?.isEmpty == true),
           (trimmedText == nil || trimmedText?.isEmpty == true),
           !hasImage,
           mediaFileName == nil || mediaFileName?.isEmpty == true,
           slideFileNames.isEmpty {
            let empty = SaveItem(
                source: .note,
                sourceURL: "",
                contentType: .text,
                title: "Saved item",
                processing: .failed
            )
            return Result(save: empty, wasDuplicate: true)
        }

        if !canonical.isEmpty,
           let all = try? context.fetch(FetchDescriptor<SaveItem>()),
           let existing = all.first(where: { $0.canonicalURL == canonical }) {
            if existing.mediaFileName.isEmpty, let mediaFileName, !mediaFileName.isEmpty {
                existing.mediaFileName = mediaFileName
                existing.processingRaw = ProcessingStatus.saved.rawValue
                try? context.save()
                Task { @MainActor in
                    await enrich(existing, url: parsedURL, imageData: imageData)
                    enrichUnprocessed(in: context)
                }
                return Result(save: existing, wasDuplicate: false)
            }
            return Result(save: existing, wasDuplicate: true)
        }

        var (source, content) = SourceAdapter.detect(
            url: parsedURL,
            text: text,
            hasImage: hasImage && parsedURL == nil && slideFileNames.isEmpty
        )
        if let mediaFileName, MediaStore.isAudiovisual(mediaFileName) {
            content = .video
        }
        if !slideFileNames.isEmpty, content != .video {
            content = .image
        }
        let title = SourceAdapter.displayTitle(url: parsedURL, text: text, source: source)

        let save = SaveItem(
            source: source,
            sourceURL: cleanedURL ?? urlString ?? "",
            canonicalURL: canonical,
            contentType: content,
            title: title,
            summary: "",
            rawText: text ?? "",
            processing: .saved,
            imageFileName: "",
            mediaFileName: mediaFileName ?? ""
        )
        context.insert(save)

        if let imageData {
            save.imageFileName = MediaStore.save(imageData, id: save.saveID)
        }
        if let first = slideFileNames.first {
            if save.imageFileName.isEmpty { save.imageFileName = first }
            save.slideFileNames = slideFileNames.filter { $0 != save.imageFileName }.joined(separator: ",")
        }

        Task { @MainActor in
            await enrich(save, url: parsedURL, imageData: imageData)
            enrichUnprocessed(in: context)
        }

        return Result(save: save, wasDuplicate: false)
    }

    @MainActor
    private static func enrich(_ save: SaveItem, url: URL?, imageData: Data?) async {
        guard let context = save.modelContext else { return }
        enrichRunning = true
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "sync.enrich") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        save.processingRaw = ProcessingStatus.processing.rawValue
        try? context.save()
        defer {
            if save.processing != .ready {
                save.processingRaw = ProcessingStatus.ready.rawValue
            }
            LibraryBrain.dequeue(save.saveID)
            try? context.save()
            enrichRunning = false
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
            }
        }

        if let imageData {
            let text = Enrichment.ocr(imageData)
            if !text.isEmpty {
                save.rawText = [save.rawText, text].filter { !$0.isEmpty }.joined(separator: "\n")
                if save.title == "Saved item" || save.source == .screenshot,
                   let line = text.split(separator: "\n").first {
                    save.title = String(line.prefix(80))
                }
            }
        }

        if let url {
            if let embed = await SocialMeta.fetch(url: url) {
                if save.source == .spotify, !embed.title.isEmpty {
                    let kind = SpotifyLink.displayKind(url)
                    if !embed.author.isEmpty, kind == "track" || kind == "album" || kind == "episode" {
                        save.title = String("\(embed.title) — \(embed.author)".prefix(80))
                    } else {
                        save.title = String(embed.title.prefix(80))
                    }
                } else if TitleMeta.isPlaceholder(save.title), !embed.title.isEmpty {
                    save.title = String(embed.title.prefix(80))
                }
                if save.creatorHandle.isEmpty, !embed.author.isEmpty {
                    if save.source == .spotify {
                        save.creatorHandle = embed.author
                    } else {
                        save.creatorHandle = embed.author.hasPrefix("@") ? embed.author : "@\(embed.author)"
                    }
                    save.creatorName = embed.author
                }
                if save.summary.isEmpty, !embed.title.isEmpty, !TitleMeta.isPlaceholder(embed.title) {
                    if save.source == .spotify, !embed.author.isEmpty {
                        save.summary = "\(embed.title) by \(embed.author)"
                    } else {
                        save.summary = embed.title
                    }
                }
                if save.imageFileName.isEmpty,
                   MediaStore.playableURL(for: save) == nil,
                   let thumb = embed.thumbnail {
                    var thumbRequest = URLRequest(url: thumb)
                    thumbRequest.timeoutInterval = 6
                    if let (data, _) = try? await URLSession.shared.data(for: thumbRequest),
                       UIImage(data: data) != nil {
                        save.imageFileName = MediaStore.save(data, id: save.saveID)
                        let overlay = Enrichment.ocr(data)
                        if !overlay.isEmpty {
                            save.rawText = [save.rawText, overlay].filter { !$0.isEmpty }.joined(separator: "\n")
                        }
                    }
                }
                if let canonical = embed.canonical {
                    save.sourceURL = canonical.absoluteString
                    save.canonicalURL = SourceAdapter.canonicalize(canonical.absoluteString)
                }
            } else if let meta = await PageMeta.fetch(url: url) {
                if TitleMeta.isPlaceholder(save.title), !TitleMeta.isPlaceholder(meta.title) {
                    save.title = meta.title
                }
                if save.summary.isEmpty, !meta.description.isEmpty, !TitleMeta.isPlaceholder(meta.description) {
                    save.summary = meta.description
                }
            }

            if TitleMeta.isPlaceholder(save.title), let handle = SocialMeta.handle(from: url) {
                save.title = "TikTok from @\(handle)"
                if save.creatorHandle.isEmpty { save.creatorHandle = "@\(handle)" }
            } else if TitleMeta.isPlaceholder(save.title), save.source == .tiktok {
                save.title = "Saved TikTok"
            }
        }

        if save.source == .tiktok,
           MediaStore.playableURL(for: save) == nil,
           let url {
            if let pulled = await TikTokMedia.pull(from: url) {
                if !pulled.caption.isEmpty {
                    if TitleMeta.isPlaceholder(save.title) {
                        save.title = String(pulled.caption.prefix(80))
                    }
                    if save.summary.isEmpty || TitleMeta.isPlaceholder(save.summary) {
                        save.summary = String(pulled.caption.prefix(400))
                    }
                    if !save.rawText.contains(pulled.caption) {
                        save.rawText = [save.rawText, "Caption:\n\(pulled.caption)"]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                    }
                }
                if save.creatorHandle.isEmpty, !pulled.author.isEmpty {
                    save.creatorHandle = pulled.author.hasPrefix("@") ? pulled.author : "@\(pulled.author)"
                    save.creatorName = pulled.author
                }
                if !pulled.spoken.isEmpty, !save.rawText.contains(pulled.spoken) {
                    save.rawText = [save.rawText, "Spoken:\n\(pulled.spoken)"]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                }
                if let video = pulled.video, video.count > 12_000,
                   !(url.path.lowercased().contains("/photo/")) {
                    save.mediaFileName = MediaStore.save(video, id: save.saveID, ext: "mp4")
                    save.contentTypeRaw = ContentKind.video.rawValue
                }
            }
        }

        if save.contentType != .video, MediaStore.playableURL(for: save) == nil {
            await SocialSlides.fill(save: save, url: url)
        }

        var extraImages: [Data] = []
        if let mediaURL = MediaStore.playableURL(for: save) {
            let insight = await VideoRead.inspect(mediaURL)
            if !insight.ocr.isEmpty {
                save.rawText = [save.rawText, "On-screen:\n\(insight.ocr)"].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if !insight.transcript.isEmpty {
                save.rawText = [save.rawText, "Spoken:\n\(insight.transcript)"].filter { !$0.isEmpty }.joined(separator: "\n")
                if TitleMeta.isPlaceholder(save.title) {
                    save.title = String(insight.transcript.prefix(80))
                }
            }
            extraImages.append(contentsOf: insight.frames)
        }

        for (index, name) in save.slides.prefix(10).enumerated() {
            guard MediaStore.isVisualImage(name),
                  let file = MediaStore.fileURL(name),
                  let data = try? Data(contentsOf: file) else { continue }
            let overlay = Enrichment.ocr(data)
            if !overlay.isEmpty, !save.rawText.contains(overlay) {
                save.rawText = [save.rawText, "On-screen (slide \(index + 1)):\n\(overlay)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            if let jpeg = Enrichment.jpegForModel(data), extraImages.count < 10 {
                extraImages.append(jpeg)
            }
            if TitleMeta.isPlaceholder(save.title),
               let line = overlay.split(separator: "\n").map(String.init).first(where: { $0.count > 8 }) {
                save.title = String(line.prefix(80))
            }
        }

        if extraImages.isEmpty, let stored = MediaStore.fileURL(save.imageFileName),
           MediaStore.isVisualImage(save.imageFileName),
           let data = try? Data(contentsOf: stored) {
            let overlay = Enrichment.ocr(data)
            if !overlay.isEmpty, !save.rawText.contains(overlay) {
                save.rawText = [save.rawText, overlay].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if TitleMeta.isPlaceholder(save.title),
               let line = overlay.split(separator: "\n").map(String.init).first(where: { $0.count > 8 }) {
                save.title = String(line.prefix(80))
            }
        }

        let classified = Enrichment.classify(
            title: save.title,
            summary: save.summary,
            rawText: save.rawText,
            url: save.sourceURL
        )
        if save.topics.isEmpty {
            save.topicsCSV = classified.topics.joined(separator: ",")
        }
        if save.entities.isEmpty {
            save.entitiesCSV = classified.entities.joined(separator: ",")
        }
        if save.summary.isEmpty {
            save.summary = Enrichment.shortSummary(from: save.rawText, fallback: "")
        }

        let bags = ((try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []).map(\.name)
        if let understood = await LibraryBrain.understand(
            save: save,
            existingCollections: bags,
            extraImages: extraImages
        ) {
            LibraryBrain.apply(understood, to: save, context: context)
            if save.collections.isEmpty {
                Enrichment.assignCollections(to: save, names: classified.collections, context: context)
            }
        } else {
            Enrichment.assignCollections(to: save, names: classified.collections, context: context)
        }

        SemanticIndex.index(save)
        save.processingRaw = ProcessingStatus.ready.rawValue
        try? context.save()
    }

    private static var enrichRunning = false

    static func needsEnrich(_ save: SaveItem) -> Bool {
        save.processing == .saved
    }

    static func enrichUnprocessed(in context: ModelContext) {
        guard !enrichRunning else { return }
        let items = (try? context.fetch(FetchDescriptor<SaveItem>())) ?? []
        let next = items.first(where: { $0.processing == .saved })
            ?? LibraryBrain.nextQueued(in: items)
        guard let next else { return }
        next.processingRaw = ProcessingStatus.processing.rawValue
        let url = URL(string: next.sourceURL)
        Task { @MainActor in
            await enrich(next, url: url, imageData: nil)
            enrichUnprocessed(in: context)
        }
    }

    static func importInbox(into context: ModelContext) {
        for item in InboxStore.pending() {
            if item.isEmpty {
                InboxStore.remove(item)
                continue
            }
            var imageData: Data?
            if let imageURL = InboxStore.imageURL(for: item) {
                imageData = try? Data(contentsOf: imageURL)
            }
            _ = ingest(
                urlString: SharedLinkParser.url(from: item.url) ?? item.url,
                text: item.text,
                imageData: imageData,
                context: context
            )
            InboxStore.remove(item)
        }
        try? context.save()
    }
}

enum TitleMeta {
    static func isPlaceholder(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return true }
        if t.contains("make your day") { return true }
        let junk = ["tiktok", "instagram", "youtube", "facebook", "x", "saved item", "web", "spotify"]
        if junk.contains(t) { return true }
        if t.hasPrefix("tiktok from") { return true }
        if t.hasPrefix("spotify ") { return true }
        if t == "saved tiktok" || t == "saved instagram" || t == "saved youtube" { return true }
        if title.contains("/") && title.count < 48 { return true }
        return isClickbait(title)
    }

    static func isClickbait(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.filter(\.isLetter)
        guard letters.count >= 8 else { return false }
        let upper = letters.filter(\.isUppercase).count
        if Double(upper) / Double(letters.count) >= 0.7 { return true }
        let lower = trimmed.lowercased()
        let hooks = ["bends the knee", "you won't believe", "wait for it", "gone wrong", "gone sexual"]
        return hooks.contains { lower.contains($0) }
    }

    static func fromSummary(_ summary: String) -> String {
        let lines = summary
            .replacingOccurrences(of: "\\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let para = lines.first {
            !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasPrefix("•") && !$0.hasPrefix("*")
        } ?? summary
        var sentence = para.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? para
        if sentence.count > 72 {
            sentence = String(sentence.prefix(72))
            if let space = sentence.lastIndex(of: " ") {
                sentence = String(sentence[..<space])
            }
        }
        return sentence.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
    }
}

enum SocialMeta {
    struct Info {
        var title: String
        var author: String
        var thumbnail: URL?
        var canonical: URL?
    }

    static func fetch(url: URL) async -> Info? {
        let resolved = await resolvedURL(url)
        let target = SpotifyLink.matches(resolved)
            ? (SpotifyLink.canonicalOpenURL(resolved) ?? resolved)
            : resolved
        guard let endpoint = oEmbedURL(for: target) else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 6
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (json["author_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:))
        if TitleMeta.isPlaceholder(title) && author.isEmpty && thumb == nil { return nil }
        return Info(title: title, author: author, thumbnail: thumb, canonical: target)
    }

    static func handle(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if let at = parts.first(where: { $0.hasPrefix("@") }) {
            return String(at.dropFirst())
        }
        return nil
    }

    private static func resolvedURL(_ url: URL) async -> URL {
        if SpotifyLink.matches(url) {
            let host = (url.host ?? "").lowercased()
            if host.contains("spotify.link") {
                var hop = URLRequest(url: url)
                hop.timeoutInterval = 5
                hop.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                if let (_, response) = try? await URLSession.shared.data(for: hop) {
                    return SpotifyLink.canonicalOpenURL(response.url ?? url) ?? response.url ?? url
                }
            }
            return SpotifyLink.canonicalOpenURL(url) ?? url
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return url }
        return response.url ?? url
    }

    private static func oEmbedURL(for url: URL) -> URL? {
        let host = (url.host ?? "").lowercased()
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        if host.contains("tiktok.com") {
            return URL(string: "https://www.tiktok.com/oembed?url=\(encoded)")
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json")
        }
        if host.contains("twitter.com") || host.contains("x.com") {
            return URL(string: "https://publish.twitter.com/oembed?url=\(encoded)")
        }
        if SpotifyLink.matches(url) {
            return URL(string: "https://open.spotify.com/oembed?url=\(encoded)")
        }
        return nil
    }
}

enum PageMeta {
    struct Info {
        var title: String
        var description: String
        var imageURL: String
    }

    static func fetch(url: URL) async -> Info? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else { return nil }

        let title = firstMatch(html, #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#)
            ?? firstMatch(html, #"<title[^>]*>([^<]+)</title>"#)
            ?? url.host ?? "Saved"
        let description = firstMatch(html, #"<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']"#)
            ?? firstMatch(html, #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']"#)
            ?? ""
        let image = firstMatch(html, #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#)
            ?? firstMatch(html, #"<meta[^>]+property=["']og:image:url["'][^>]+content=["']([^"']+)["']"#)
            ?? ""
        return Info(
            title: decode(title).trimmingCharacters(in: .whitespacesAndNewlines),
            description: String(decode(description).prefix(180)),
            imageURL: decode(image).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func firstMatch(_ html: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[swiftRange])
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
