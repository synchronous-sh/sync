import Foundation

enum ArticleShare {
    @MainActor
    static func share(_ post: FeedPost) {
        Task { @MainActor in
            var current = post
            if FeedStudio.needsBriefing(current) {
                current = await FeedStudio.ensureBriefing(current)
            }
            for _ in 0..<3 {
                if await publish(current) { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            SharePrompt.show([current.shareURL])
        }
    }

    @MainActor
    static func share(_ save: SaveItem) {
        Task { @MainActor in
            _ = await publish(save)
            SharePrompt.show([shareURL(for: save)])
        }
    }

    static func shareURL(for save: SaveItem) -> URL {
        URL(string: "https://synchronous.sh/article/\(slug(for: save))")!
    }

    static func slug(for save: SaveItem) -> String {
        slug(title: save.title, id: save.saveID)
    }

    static func slug(title: String, id: UUID) -> String {
        var slug = ""
        var dash = false
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                dash = false
            } else if !slug.isEmpty, !dash {
                slug.append("-")
                dash = true
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 48 { slug = String(slug.prefix(48)) }
        if slug.isEmpty { slug = "save" }
        let tag = id.uuidString.split(separator: "-").first.map(String.init)?.lowercased() ?? id.uuidString.lowercased()
        return "\(slug)-\(tag)"
    }

    static func publish(_ save: SaveItem) async -> Bool {
        let script = save.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = save.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = script.isEmpty ? String(fallback.prefix(8000)) : script
        var imageURL = ""
        var imageJPEG: Data?
        if let file = MediaStore.fileURL(save.imageFileName),
           let data = try? Data(contentsOf: file) {
            imageJPEG = Enrichment.jpegForModel(data)
        }
        if imageJPEG == nil,
           let source = URL(string: save.sourceURL), let meta = await PageMeta.fetch(url: source),
           meta.imageURL.hasPrefix("http") {
            imageURL = meta.imageURL
        }
        let post = FeedPost(
            id: save.saveID,
            saveID: save.saveID,
            title: save.title,
            script: body,
            headline: save.title,
            headlineURL: save.sourceURL,
            audioFileName: "",
            imageFileName: save.imageFileName,
            imageURL: imageURL,
            sourceName: save.source.label,
            interest: save.topics.first ?? save.source.label,
            createdAt: save.createdAt,
            publishedAt: save.savedAt,
            briefingReady: !body.isEmpty
        )
        return await publish(post, imageJPEG: imageJPEG)
    }

    static func publish(_ post: FeedPost) async -> Bool {
        var jpeg: Data?
        if post.imageURL.isEmpty,
           let file = MediaStore.fileURL(post.imageFileName),
           let data = try? Data(contentsOf: file) {
            jpeg = Enrichment.jpegForModel(data)
        }
        return await publish(post, imageJPEG: jpeg)
    }

    static func publish(_ post: FeedPost, imageJPEG: Data?) async -> Bool {
        guard let url = URL(string: "https://www.synchronous.sh/api/articles") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let secret = BundledAPIKeys.resolved(
            service: "sh.synchronous.sync.article-publish",
            bundled: BundledAPIKeys.articlePublish
        )
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var body: [String: String] = [
            "slug": post.articleSlug,
            "title": post.title,
            "script": post.script,
            "sourceName": post.sourceName,
            "headlineURL": post.headlineURL,
            "imageURL": post.imageURL,
            "publishedAt": iso.string(from: post.publishedAt)
        ]
        if let imageJPEG, !imageJPEG.isEmpty {
            body["imageBase64"] = imageJPEG.base64EncodedString()
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["ok"] as? Bool == false {
            return false
        }
        return true
    }
}
