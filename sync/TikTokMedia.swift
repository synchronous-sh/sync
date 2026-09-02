import Foundation

enum TikTokMedia {
    struct Pulled {
        var caption: String
        var author: String
        var spoken: String
        var video: Data?
    }

    static func pull(from url: URL) async -> Pulled? {
        let page = await resolved(url)
        var request = URLRequest(url: page)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else { return nil }

        let json = embeddedJSON(in: html)
        let caption = firstNonEmpty([
            string(in: json, keys: ["desc", "description", "text"]),
            meta(html, "og:description"),
            meta(html, "twitter:description")
        ])
        let author = firstNonEmpty([
            string(in: json, keys: ["uniqueId", "nickname", "author_name"]),
            SocialMeta.handle(from: page) ?? ""
        ])
        let spoken = firstNonEmpty([
            string(in: json, keys: ["captionText", "subtitle", "transcript"]),
            joinedSubtitles(json)
        ])
        var video: Data?
        for candidate in videoURLs(in: json, html: html).prefix(4) {
            if let file = await downloadVideo(candidate, page: page), file.count > 12_000 {
                video = file
                break
            }
        }
        if caption.isEmpty, author.isEmpty, video == nil, spoken.isEmpty {
            return nil
        }
        return Pulled(caption: caption, author: author, spoken: spoken, video: video)
    }

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func resolved(_ url: URL) async -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return url }
        return response.url ?? url
    }

    private static func downloadVideo(_ file: URL, page: URL) async -> Data? {
        var request = URLRequest(url: file)
        request.timeoutInterval = 24
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        request.setValue(page.absoluteString, forHTTPHeaderField: "Origin")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 12_000 else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("json") || type.contains("html") || type.contains("text") || type.contains("image") { return nil }
        if data.count > 8 {
            let brand = data.subdata(in: 4..<min(8, data.count))
            if let tag = String(data: brand, encoding: .ascii), tag != "ftyp", !type.contains("video"), !type.contains("mp4") {
                return nil
            }
        }
        return data
    }

    private static func embeddedJSON(in html: String) -> Any? {
        let markers = [
            "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"",
            "id='__UNIVERSAL_DATA_FOR_REHYDRATION__'",
            "id=\"SIGI_STATE\"",
            "id='SIGI_STATE'"
        ]
        for marker in markers {
            guard let start = html.range(of: marker) else { continue }
            guard let open = html.range(of: ">", range: start.upperBound..<html.endIndex) else { continue }
            guard let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { continue }
            var blob = String(html[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if blob.hasPrefix("<!--") { blob.removeFirst(4) }
            blob = blob.replacingOccurrences(of: "&quot;", with: "\"")
            if let data = blob.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
        }
        return nil
    }

    private static func videoURLs(in json: Any?, html: String) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let cleaned = unescape(raw)
            guard cleaned.hasPrefix("http"),
                  let url = URL(string: cleaned),
                  seen.insert(cleaned).inserted else { return }
            let lower = cleaned.lowercased()
            if lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png")
                || lower.contains(".webp") || lower.contains(".heic") { return }
            if lower.contains("image") && !lower.contains("video") { return }
            if lower.contains("cover") || lower.contains("thumbnail") || lower.contains("avatar") { return }
            found.append(url)
        }
        walk(json) { key, value in
            let lower = key.lowercased()
            if lower.contains("cover") || lower.contains("thumbnail") || lower.contains("avatar") { return }
            if lower == "playaddr" || lower == "downloadaddr" || lower == "play_addr" || lower == "download_addr" {
                if let text = value as? String { add(text) }
                if let obj = value as? [String: Any] {
                    if let text = obj["Url"] as? String ?? obj["url"] as? String { add(text) }
                    if let list = obj["UrlList"] as? [String] ?? obj["url_list"] as? [String] {
                        list.forEach(add)
                    }
                }
            }
            if lower == "urllist" || lower == "url_list", let list = value as? [String] {
                list.forEach(add)
            }
        }
        let pattern = #"https:\\?/\\?/v[0-9a-z.-]*tiktokcdn[^"'\\s]+"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                if let swift = Range(match.range, in: html) {
                    add(unescape(String(html[swift])))
                }
            }
        }
        return found
    }

    private static func joinedSubtitles(_ json: Any?) -> String {
        var lines: [String] = []
        walk(json) { key, value in
            let lower = key.lowercased()
            if lower.contains("subtitle") || lower.contains("caption") {
                if let text = value as? String, text.count > 12, !text.hasPrefix("http") {
                    lines.append(text)
                }
            }
        }
        return uniqued(lines).joined(separator: "\n")
    }

    private static func string(in json: Any?, keys: [String]) -> String {
        let want = Set(keys.map { $0.lowercased() })
        var hits: [String] = []
        walk(json) { key, value in
            guard want.contains(key.lowercased()), let text = value as? String else { return }
            let trimmed = unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 { hits.append(trimmed) }
        }
        return firstNonEmpty(hits)
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

    private static func meta(_ html: String, _ property: String) -> String {
        let pattern = "<meta[^>]+(?:property|name)=[\"']\(property)[\"'][^>]+content=[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let swift = Range(match.range(at: 1), in: html) else { return "" }
        return unescape(String(html[swift])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        if let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String {
            text = decoded
        }
        return text
    }

    private static func firstNonEmpty(_ values: [String]) -> String {
        for value in values {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 2 { return t }
        }
        return ""
    }

    private static func uniqued(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0.lowercased()).inserted }
    }
}
