import Foundation
import LinkPresentation
import UIKit

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
            let image = await previewImage(for: current)
            SharePrompt.show([SharePreviewItem(url: current.shareURL, title: current.title, image: image)])
        }
    }

    @MainActor
    static func share(_ save: SaveItem) {
        Task { @MainActor in
            _ = await publish(save)
            let image = await previewImage(for: save)
            SharePrompt.show([SharePreviewItem(url: shareURL(for: save), title: save.title, image: image)])
        }
    }

    private static func previewImage(for post: FeedPost) async -> UIImage? {
        if let image = FeedImageCache.image(for: post.id) { return image }
        if !post.imageFileName.isEmpty,
           let url = MediaStore.fileURL(post.imageFileName),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return await FeedNews.loadFastImage(for: post)
    }

    private static func previewImage(for save: SaveItem) async -> UIImage? {
        if let image = FeedImageCache.image(for: save.saveID) { return image }
        if MediaStore.isVisualImage(save.imageFileName),
           let url = MediaStore.fileURL(save.imageFileName),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        if let remote = URL(string: save.sourceURL), remote.scheme?.hasPrefix("http") == true,
           let meta = await PageMeta.fetch(url: remote),
           meta.imageURL.hasPrefix("http"),
           let imageURL = URL(string: meta.imageURL),
           let data = try? await URLSession.shared.data(from: imageURL).0,
           let image = UIImage(data: data) {
            return image
        }
        return nil
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
        let source = await canonicalMediaURL(save.sourceURL)
        if imageJPEG == nil,
           let remotePage = URL(string: source), let meta = await PageMeta.fetch(url: remotePage),
           meta.imageURL.hasPrefix("http"),
           let remote = URL(string: meta.imageURL) {
            imageJPEG = await downloadedJPEG(remote)
            if imageJPEG == nil { imageURL = meta.imageURL }
        }
        let post = FeedPost(
            id: save.saveID,
            saveID: save.saveID,
            title: save.title,
            script: body,
            headline: save.title,
            headlineURL: source,
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
        var jpeg = jpegFromDisk(post)
        if jpeg == nil, let image = await previewImage(for: post),
           let data = image.jpegData(compressionQuality: 0.82) {
            jpeg = Enrichment.jpegForModel(data)
        }
        if jpeg == nil, let remote = URL(string: post.imageURL) {
            jpeg = await downloadedJPEG(remote)
        }
        var outbound = post
        if jpeg != nil { outbound.imageURL = "" }
        outbound.headlineURL = await canonicalMediaURL(post.headlineURL)
        return await publish(outbound, imageJPEG: jpeg)
    }

    private static func jpegFromDisk(_ post: FeedPost) -> Data? {
        if let image = FeedImageCache.image(for: post.id),
           let data = image.jpegData(compressionQuality: 0.82) {
            return Enrichment.jpegForModel(data)
        }
        if !post.imageFileName.isEmpty,
           let file = MediaStore.fileURL(post.imageFileName),
           let data = try? Data(contentsOf: file) {
            return Enrichment.jpegForModel(data)
        }
        return nil
    }

    private static func canonicalMediaURL(_ raw: String) async -> String {
        guard let url = URL(string: raw) else { return raw }
        let host = (url.host ?? "").lowercased()
        if host.contains("tiktok.com") {
            return await TikTokMedia.canonicalVideoURL(from: url).absoluteString
        }
        let path = url.path.lowercased()
        let needsResolve =
            host.contains("instagram.com") && (path.contains("/share/") || path.contains("/s/"))
        guard needsResolve else { return raw }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url else { return raw }
        return final.absoluteString
    }

    private static func downloadedJPEG(_ url: URL) async -> Data? {
        guard !FeedNews.isJunkPhoto(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let jpeg = Enrichment.jpegForModel(data), jpeg.count > 800 else { return nil }
        return jpeg
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
        if let source = URL(string: post.headlineURL),
           let embed = MediaEmbed.webPlayer(for: source) {
            body["embedURL"] = embed.absoluteString
        }
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

final class SharePreviewItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let image: UIImage?

    init(url: URL, title: String, image: UIImage?) {
        self.url = url
        self.title = title
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.originalURL = url
        meta.url = url
        meta.title = title
        if let image {
            let provider = NSItemProvider(object: image)
            meta.imageProvider = provider
            meta.iconProvider = provider
        }
        return meta
    }
}
