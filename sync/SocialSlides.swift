import Foundation
import UIKit

enum SocialSlides {
    static func fill(save: SaveItem, url: URL?) async {
        guard let url else { return }
        let host = (url.host ?? "").lowercased()
        guard host.contains("tiktok.com") || host.contains("instagram.com") else { return }
        if save.contentType == .video { return }
        if MediaStore.playableURL(for: save) != nil { return }
        if host.contains("tiktok.com"), !TikTokLink.isPhoto(url) { return }
        if save.slides.count >= 2 { return }

        var request = URLRequest(url: pageURL(url))
        request.timeoutInterval = 12
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else { return }

        var found = imageURLs(in: html)
        if found.count < 2, host.contains("instagram.com"),
           let code = instagramCode(url) {
            found = await embedImages(code: code)
        }
        var names = save.slides
        for imageURL in found.prefix(12) {
            guard let bytes = await download(imageURL, page: url),
                  bytes.count > 8_000,
                  UIImage(data: bytes) != nil else { continue }
            let name = MediaStore.save(bytes, id: UUID(), ext: "jpg")
            if !names.contains(name) { names.append(name) }
        }
        guard names.count > save.slides.count else { return }
        if save.imageFileName.isEmpty {
            save.imageFileName = names[0]
        }
        save.slideFileNames = names.filter { $0 != save.imageFileName }.joined(separator: ",")
        if save.contentType != .video {
            save.contentTypeRaw = ContentKind.image.rawValue
        }
    }

    private static let agent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func pageURL(_ url: URL) -> URL {
        let host = (url.host ?? "").lowercased()
        if host.contains("instagram.com"), let code = instagramCode(url) {
            return URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/") ?? url
        }
        return url
    }

    private static func instagramCode(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let idx = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }),
              parts.indices.contains(idx + 1) else { return nil }
        return parts[idx + 1]
    }

    private static func embedImages(code: String) async -> [URL] {
        guard let embed = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/") else { return [] }
        var request = URLRequest(url: embed)
        request.timeoutInterval = 10
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return [] }
        return imageURLs(in: html)
    }

    private static func download(_ file: URL, page: URL) async -> Data? {
        var request = URLRequest(url: file)
        request.timeoutInterval = 16
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("json") || type.contains("html") || type.contains("text") { return nil }
        return data
    }

    private static func imageURLs(in html: String) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let cleaned = raw
                .replacingOccurrences(of: "\\u002F", with: "/")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard cleaned.hasPrefix("http"),
                  !cleaned.contains(".mp4"),
                  !cleaned.contains(".m3u8"),
                  let url = URL(string: cleaned),
                  seen.insert(cleaned).inserted else { return }
            let path = url.path.lowercased()
            let ok = path.contains(".jpg") || path.contains(".jpeg") || path.contains(".png")
                || path.contains(".webp") || path.contains(".heic")
                || cleaned.contains("scontent") || cleaned.contains("cdninstagram")
                || (cleaned.contains("tiktokcdn") && (cleaned.contains("image") || cleaned.contains("jpeg") || cleaned.contains("webp") || cleaned.contains("cover")))
            guard ok else { return }
            found.append(url)
        }

        for json in embeddedJSON(in: html) {
            walk(json) { key, value in
                let lower = key.lowercased()
                if lower.contains("image") || lower == "urllist" || lower == "url_list"
                    || lower == "display_url" || lower == "src" || lower == "origincover" {
                    if let text = value as? String { add(text) }
                    if let list = value as? [String] { list.forEach(add) }
                    if let obj = value as? [String: Any] {
                        if let text = obj["url"] as? String ?? obj["Url"] as? String { add(text) }
                        if let list = obj["url_list"] as? [String] ?? obj["UrlList"] as? [String] {
                            list.forEach(add)
                        }
                    }
                }
            }
        }

        let pattern = #"https:\\?/\\?/[a-zA-Z0-9._~:/?#\[\]@!$&'()*+,;=%-]+\.(?:jpg|jpeg|png|webp)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range).prefix(40) {
                if let swift = Range(match.range, in: html) {
                    add(String(html[swift]).replacingOccurrences(of: "\\/", with: "/"))
                }
            }
        }
        return found
    }

    private static func embeddedJSON(in html: String) -> [Any] {
        var blobs: [Any] = []
        let markers = [
            "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"",
            "id='__UNIVERSAL_DATA_FOR_REHYDRATION__'",
            "id=\"SIGI_STATE\"",
            "id='SIGI_STATE'",
            "window._sharedData =",
            "\"carousel_media\"",
        ]
        for marker in markers {
            guard let start = html.range(of: marker) else { continue }
            let from = marker.hasPrefix("window") ? start.upperBound : (html.range(of: ">", range: start.upperBound..<html.endIndex)?.upperBound ?? start.upperBound)
            let close = html.range(of: "</script>", range: from..<html.endIndex)?.lowerBound ?? html.endIndex
            var blob = String(html[from..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            if blob.hasSuffix(";") { blob.removeLast() }
            blob = blob.replacingOccurrences(of: "&quot;", with: "\"")
            if let data = blob.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                blobs.append(json)
            }
        }
        return blobs
    }

    private static func walk(_ value: Any?, visit: (String, Any) -> Void) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                visit(key, child)
                walk(child, visit: visit)
            }
        } else if let list = value as? [Any] {
            for child in list { walk(child, visit: visit) }
        }
    }
}
