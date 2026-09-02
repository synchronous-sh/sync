import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Security

enum NewsAPIKey {
    private static let service = "sh.synchronous.sync.newsapi"

    static func load() -> String {
        BundledAPIKeys.resolved(service: service, bundled: BundledAPIKeys.newsAPI)
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

struct NewsHeadline: Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
    var source: String
    var imageURL: URL?
    var publishedAt: Date?
}

enum FeedNews {
    static let earliestStory: Date = {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = 2026
        parts.month = 7
        parts.day = 1
        return parts.date ?? Date.distantPast
    }()

    static func isFresh(_ date: Date?) -> Bool {
        guard let date else { return true }
        return date >= earliestStory
    }

    static func stories(for query: String, limit: Int = 8, scrapePages: Bool = false, skipSeen: Bool = true, requireMention: Bool = false) async -> [NewsHeadline] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var items: [NewsHeadline] = []
        if NewsAPIKey.isConfigured {
            items = await newsAPI(q, limit: max(limit * 2, 16))
        }
        let relevant = items.filter { !requireMention || mentions($0, q) }
        if relevant.count < limit {
            items.append(contentsOf: await rss(
                URL(string: "https://www.bing.com/news/search?q=\(encode(q))&format=rss"),
                limit: limit * 2
            ))
            var comps = URLComponents(string: "https://news.google.com/rss/search")
            comps?.queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "hl", value: "en-US"),
                URLQueryItem(name: "gl", value: "US"),
                URLQueryItem(name: "ceid", value: "US:en")
            ]
            items.append(contentsOf: await rss(comps?.url, limit: limit * 2))
        }
        var seen = Set<String>()
        var unique: [NewsHeadline] = []
        for item in items {
            if skipSeen, FeedStore.hasSeen(title: item.title, url: item.url) { continue }
            let key = FeedStore.fingerprint(title: item.title, url: item.url)
            if seen.contains(key) { continue }
            if junk(item.title) || junk(item.snippet) { continue }
            if !isFresh(item.publishedAt) { continue }
            if requireMention, !mentions(item, q) { continue }
            seen.insert(key)
            unique.append(item)
        }
        unique.sort { left, right in
            let leftTitle = containsPhrase(left.title, q)
            let rightTitle = containsPhrase(right.title, q)
            if leftTitle != rightTitle { return leftTitle }
            return (left.publishedAt ?? .distantPast) > (right.publishedAt ?? .distantPast)
        }
        if unique.count > limit { unique = Array(unique.prefix(limit)) }
        if scrapePages {
            unique = await enrich(unique, query: q)
        }
        return unique.filter { !$0.title.isEmpty && !$0.url.isEmpty }
    }

    static func mentions(_ story: NewsHeadline, _ query: String) -> Bool {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 2 else { return false }
        let hay = story.title + " " + story.snippet
        return containsPhrase(hay, phrase)
    }

    static func about(_ story: NewsHeadline, query: String) -> Bool {
        let title = story.title.lowercased()
        let hay = (story.title + " " + story.snippet).lowercased()
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard phrase.count >= 3 else { return false }
        if phrase.contains(" ") {
            return containsPhrase(title, phrase) || containsPhrase(hay, phrase)
        }
        if phrase.count < 6 { return false }
        return containsPhrase(title, phrase)
    }

    static func containsPhrase(_ hay: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return hay.contains(phrase)
        }
        let range = NSRange(hay.startIndex..<hay.endIndex, in: hay)
        return regex.firstMatch(in: hay, range: range) != nil
    }

    static func fallbackImage(interest: String, articleURL: String, headline: String = "", snippet: String = "") async -> URL? {
        await quickPhoto(title: headline.isEmpty ? interest : headline, interest: interest)
    }

    static func quickPhoto(title: String, interest: String) async -> URL? {
        var names: [String] = []
        let interestName = interest.trimmingCharacters(in: .whitespacesAndNewlines)
        if interestName.count >= 2 { names.append(interestName) }
        var current = ""
        for ch in title {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if current.count >= 2, current.first?.isUppercase == true, current.lowercased() != interestName.lowercased() {
                    names.append(current)
                }
                current = ""
            }
        }
        if current.count >= 2, current.first?.isUppercase == true {
            names.append(current)
        }
        return await firstPortrait(Array(names.prefix(3)))
    }

    static func loadFastImage(for post: FeedPost) async -> UIImage? {
        if let cached = FeedImageCache.image(for: post.id) { return cached }
        if let url = URL(string: post.imageURL), !isAggregator(url),
           let name = await downloadImage(url, id: post.id),
           let image = diskImage(name) {
            FeedImageCache.store(image, for: post.id)
            return image
        }
        if let url = await quickPhoto(title: post.title, interest: post.interest),
           let name = await downloadImage(url, id: post.id),
           let image = diskImage(name) {
            FeedImageCache.store(image, for: post.id)
            return image
        }
        if let url = generatedImageURL(title: post.title, interest: post.interest),
           let name = await downloadImage(url, id: post.id),
           let image = diskImage(name) {
            FeedImageCache.store(image, for: post.id)
            return image
        }
        return nil
    }

    private static func diskImage(_ name: String) -> UIImage? {
        guard let url = MediaStore.fileURL(name),
              let image = UIImage(contentsOfFile: url.path),
              image.size.width >= 40 else { return nil }
        return image
    }

    private static func firstPortrait(_ names: [String]) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            for name in names {
                group.addTask { await wikipediaPortrait(name) }
            }
            var found: URL?
            for await url in group {
                if let url {
                    found = url
                    group.cancelAll()
                    break
                }
            }
            return found
        }
    }

    static func generatedImageURL(title: String, interest: String) -> URL? {
        let prompt = "photorealistic wire-service news photograph of \(title), \(interest), recognizable people or company, no text overlay, no watermark, vertical"
        let clipped = String(prompt.prefix(220))
        guard let encoded = clipped.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://image.pollinations.ai/prompt/\(encoded)?width=768&height=1280&nologo=true")
    }

    private static func newsCastPhoto(title: String, snippet: String, interest: String) async -> URL? {
        let subjects = await visualSubjects(title: title, snippet: snippet, interest: interest)
        for name in subjects {
            if let image = await wikipediaPortrait(name) { return image }
            if let image = await commonsPhoto(name) { return image }
        }
        let who = subjects.prefix(3).joined(separator: ", ")
        return generatedImageURL(title: who.isEmpty ? title : who, interest: interest)
    }

    private static func visualSubjects(title: String, snippet: String, interest: String) async -> [String] {
        let system = """
        You are a news photo editor. Pick who or what a wire photo would show.
        Return JSON only: {"subjects":["Name","Name"]}
        2 to 4 items. Famous people first (founders, CEOs, politicians), then companies or products.
        For AI/coding tools name the people and labs (Sam Altman, OpenAI, Elon Musk, xAI, Cursor) when relevant.
        Never return the news outlet. Never return generic words like technology, update, news.
        """
        let user = """
        Headline: \(title)
        Blurb: \(String(snippet.prefix(400)))
        Interest: \(interest)
        """
        if let raw = await AnthropicLibrary.reply(system: system, user: user, maxTokens: 120),
           let names = parseSubjects(raw), !names.isEmpty {
            return names
        }
        var fallback = [interest]
        for piece in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != " " }) {
            let word = String(piece)
            if word.count >= 2, word.first?.isUppercase == true { fallback.append(word) }
        }
        return Array(fallback.prefix(4))
    }

    private static func parseSubjects(_ raw: String) -> [String]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["subjects"] as? [String] else { return nil }
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }.prefix(4).map { $0 }
    }

    private static func wikipediaPortrait(_ query: String) async -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        var search = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        search?.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "namespace", value: "0"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let searchURL = search?.url else { return nil }
        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 8
        searchReq.setValue("Sync/1.0 (iOS personal library)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: searchReq),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1,
              let titles = json[1] as? [String],
              let page = titles.first,
              !page.isEmpty else { return nil }
        let path = page.replacingOccurrences(of: " ", with: "_")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        var summaryReq = URLRequest(url: summaryURL)
        summaryReq.timeoutInterval = 8
        summaryReq.setValue("Sync/1.0 (iOS personal library)", forHTTPHeaderField: "User-Agent")
        summaryReq.setValue("Sync/1.0 (iOS personal library)", forHTTPHeaderField: "Api-User-Agent")
        guard let (body, _) = try? await URLSession.shared.data(for: summaryReq),
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let original = (payload["originalimage"] as? [String: Any])?["source"] as? String
        let thumb = (payload["thumbnail"] as? [String: Any])?["source"] as? String
        for source in [original, thumb].compactMap({ $0 }) {
            if let image = URL(string: source), isPhoto(image) { return image }
        }
        return await wikipediaThumb(page)
    }

    private static func commonsPhoto(_ query: String) async -> URL? {
        var comps = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        comps?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrlimit", value: "4"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime"),
            URLQueryItem(name: "iiurlwidth", value: "1280"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Sync/1.0 (iOS personal library)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        for page in pages.values {
            guard let page = page as? [String: Any],
                  let info = (page["imageinfo"] as? [[String: Any]])?.first else { continue }
            let mime = (info["mime"] as? String ?? "").lowercased()
            if mime.contains("svg") { continue }
            let source = (info["thumburl"] as? String) ?? (info["url"] as? String)
            guard let source, let image = URL(string: source), isPhoto(image) else { continue }
            return image
        }
        return nil
    }

    static func picture(for story: NewsHeadline, interest: String, id: UUID) async -> (file: String, remote: String) {
        var remote = story.imageURL
        if remote == nil {
            remote = await fallbackImage(interest: interest, articleURL: story.url, headline: story.title, snippet: story.snippet)
        }
        if remote == nil {
            remote = generatedImageURL(title: story.title, interest: interest)
        }
        var file = ""
        if let remote {
            file = await downloadImage(remote, id: id) ?? ""
        }
        return (file, remote?.absoluteString ?? "")
    }

    static func downloadImage(_ url: URL, id: UUID) async -> String? {
        guard isPhoto(url) else { return nil }
        var request = URLRequest(url: url)
        let slow = (url.host ?? "").contains("pollinations")
        request.timeoutInterval = slow ? 16 : 6
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count > 400 else { return nil }
        if let http = response as? HTTPURLResponse,
           let type = http.value(forHTTPHeaderField: "Content-Type"),
           type.contains("svg") || type.contains("html") {
            return nil
        }
        #if canImport(UIKit)
        guard let image = UIImage(data: data), image.size.width >= 80 else { return nil }
        if let jpeg = image.jpegData(compressionQuality: 0.82) {
            return MediaStore.save(jpeg, id: id, ext: "jpg")
        }
        #endif
        return MediaStore.save(data, id: id, ext: "jpg")
    }

    private static func newsAPI(_ query: String, limit: Int) async -> [NewsHeadline] {
        let ai = await newsAPIAI(query, limit: limit)
        if !ai.isEmpty { return ai }
        return await newsAPIOrg(query, limit: limit)
    }

    private static func newsAPIAI(_ query: String, limit: Int) async -> [NewsHeadline] {
        let key = NewsAPIKey.load()
        guard !key.isEmpty else { return [] }
        guard let url = URL(string: "https://eventregistry.org/api/v1/article/getArticles") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
            request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "action": "getArticles",
            "keyword": query,
            "keywordLoc": "body",
            "keywordOper": "or",
            "lang": "eng",
            "articlesCount": min(limit, 20),
            "articlesSortBy": "date",
            "articleBodyLen": 400,
            "resultType": "articles",
            "dateStart": "2026-07-01",
            "forceMaxDataTimeWindow": 31,
            "apiKey": key
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let results = ((json["articles"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        var out: [NewsHeadline] = []
        for article in results {
            let title = displayTitle(article["title"] as? String ?? "")
            let link = (article["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 8, link.hasPrefix("http") else { continue }
            let snippet = cleanCopy(article["body"] as? String ?? "")
            let source = ((article["source"] as? [String: Any])?["title"] as? String ?? "")
            let image = (article["image"] as? String).flatMap { URL(string: $0) }
            let published = parsePublished(article["dateTimePub"] as? String ?? article["dateTime"] as? String)
            out.append(NewsHeadline(
                title: title,
                url: link,
                snippet: String(snippet.prefix(400)),
                source: source,
                imageURL: image,
                publishedAt: published
            ))
        }
        return out
    }

    private static func newsAPIOrg(_ query: String, limit: Int) async -> [NewsHeadline] {
        let key = NewsAPIKey.load()
        guard !key.isEmpty else { return [] }
        var comps = URLComponents(string: "https://newsapi.org/v2/everything")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: "\"\(query)\""),
            URLQueryItem(name: "searchIn", value: "title,description"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "sortBy", value: "publishedAt"),
            URLQueryItem(name: "from", value: "2026-07-01"),
            URLQueryItem(name: "pageSize", value: "\(min(limit, 20))")
        ]
        guard let url = comps?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let articles = json["articles"] as? [[String: Any]] else { return [] }
        var out: [NewsHeadline] = []
        for article in articles {
            let title = (article["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let link = (article["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 8, link.hasPrefix("http") else { continue }
            if title.lowercased().contains("[removed]") { continue }
            let snippet = cleanCopy(article["description"] as? String ?? article["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = ((article["source"] as? [String: Any])?["name"] as? String ?? "")
            let image = (article["urlToImage"] as? String).flatMap { URL(string: $0) }
            let published = parsePublished(article["publishedAt"] as? String)
            out.append(NewsHeadline(
                title: title,
                url: link,
                snippet: String(snippet.prefix(400)),
                source: source,
                imageURL: image,
                publishedAt: published
            ))
        }
        return out
    }

    private static func rss(_ url: URL?, limit: Int) async -> [NewsHeadline] {
        guard let url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else { return [] }
        return parseItems(xml, limit: limit)
    }

    private static func parseItems(_ xml: String, limit: Int) -> [NewsHeadline] {
        var out: [NewsHeadline] = []
        var search = xml.startIndex
        while out.count < limit, let start = xml.range(of: "<item>", range: search..<xml.endIndex),
              let end = xml.range(of: "</item>", range: start.upperBound..<xml.endIndex) {
            let item = String(xml[start.lowerBound..<end.upperBound])
            search = end.upperBound
            let title = displayTitle(decode(tag("title", in: item) ?? ""))
            var link = unwrap(tag("link", in: item) ?? "")
            if let url = URL(string: link), isAggregator(url) {
                if let publisher = sourceURL(in: item) {
                    link = publisher
                }
            }
            let rawDesc = tag("description", in: item) ?? ""
            let snippet = cleanCopy(rawDesc)
            let source = decode(tag("News:Source", in: item) ?? tag("source", in: item) ?? "")
            guard title.count > 8, !link.isEmpty else { continue }
            if let url = URL(string: link), isAggregator(url) { continue }
            if junk(snippet) || junk(title) { continue }
            let lower = (title + snippet).lowercased()
            if lower.contains("google news") { continue }
            if lower.contains("aggregates global coverage") { continue }
            var image = imageURL(in: item) ?? imageURL(in: rawDesc)
            if let img = image, isAggregator(img) { image = nil }
            let published = parsePublished(tag("pubDate", in: item) ?? tag("published", in: item))
            out.append(NewsHeadline(
                title: title,
                url: link,
                snippet: String(snippet.prefix(400)),
                source: source,
                imageURL: image,
                publishedAt: published
            ))
        }
        return out
    }

    private static func imageURL(in xml: String) -> URL? {
        let patterns = [
            #"url=["'](https?://[^"']+)["']"#,
            #"<media:content[^>]+url=["']([^"']+)["']"#,
            #"<media:thumbnail[^>]+url=["']([^"']+)["']"#,
            #"<enclosure[^>]+url=["']([^"']+)["']"#,
            #"<img[^>]+src=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            guard let match = regex.firstMatch(in: xml, range: range), match.numberOfRanges > 1,
                  let swift = Range(match.range(at: 1), in: xml),
                  let url = URL(string: decode(String(xml[swift]))) else { continue }
            if isPhoto(url) { return url }
        }
        return nil
    }

    private static func enrich(_ items: [NewsHeadline], query: String) async -> [NewsHeadline] {
        let wiki = await wikipediaThumb(query)
        return await withTaskGroup(of: (Int, NewsHeadline).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await page(item, wiki: wiki)) }
            }
            var slotted = items
            for await (index, item) in group {
                slotted[index] = item
            }
            return slotted
        }
    }

    private static func page(_ item: NewsHeadline, wiki: URL?) async -> NewsHeadline {
        var next = item
        let alreadyFilled = next.snippet.count > 40 && next.imageURL != nil
        if !alreadyFilled {
            if let url = URL(string: item.url), isAggregator(url) {
                next.url = unwrap(item.url)
            }
            if let url = URL(string: next.url), !isAggregator(url), let html = await html(url) {
                let ogTitle = meta(html, property: "og:title")
                let ogDesc = meta(html, property: "og:description") ?? meta(html, name: "description")
                if let ogTitle, ogTitle.count > 8, !ogTitle.lowercased().contains("google news") {
                    next.title = decode(ogTitle)
                }
                if let ogDesc, ogDesc.count > 40, !ogDesc.lowercased().contains("aggregat") {
                    next.snippet = cleanCopy(ogDesc)
                }
                if next.imageURL == nil, let image = imageFromHTML(html, base: url) {
                    next.imageURL = image
                }
            }
        }
        if next.imageURL == nil {
            next.imageURL = wiki
        }
        return next
    }

    private static func html(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.allowsConstrainedNetworkAccess = false
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let final = response.url, isAggregator(final) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
    }

    private static func wikipediaThumb(_ query: String) async -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: trimmed),
            URLQueryItem(name: "gsrlimit", value: "1"),
            URLQueryItem(name: "prop", value: "pageimages"),
            URLQueryItem(name: "pithumbsize", value: "1200"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Sync/1.0 (iOS personal library)", forHTTPHeaderField: "User-Agent")
        request.setValue("Sync/1.0 (iOS personal library)", forHTTPHeaderField: "Api-User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["query"] as? [String: Any],
              let pages = payload["pages"] as? [String: Any] else { return nil }
        for page in pages.values {
            guard let page = page as? [String: Any],
                  let thumb = page["thumbnail"] as? [String: Any],
                  let source = thumb["source"] as? String,
                  let image = URL(string: source),
                  isPhoto(image) else { continue }
            return image
        }
        return nil
    }

    private static func unwrap(_ raw: String) -> String {
        let decoded = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: decoded),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return decoded
        }
        let host = (comps.host ?? "").lowercased()
        if host.contains("bing.com") || host.contains("microsoft.com"),
           let dest = comps.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
           dest.hasPrefix("http") {
            return dest
        }
        return decoded
    }

    static func isAggregator(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("news.google") || host.contains("bing.com") || host.contains("news.yahoo")
    }

    private static func isPhoto(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let blob = host + path + url.absoluteString.lowercased()
        if path.hasSuffix(".svg") || path.hasSuffix(".ico") { return false }
        if blob.contains("favicon") { return false }
        if host.contains("news.google") { return false }
        if blob.contains("logo") && !blob.contains("encrypted-tbn") && !blob.contains("wikipedia") && !blob.contains("pollinations") { return false }
        return blob.contains("http")
    }

    private static func imageFromHTML(_ html: String, base: URL) -> URL? {
        let raw = meta(html, property: "og:image")
            ?? meta(html, property: "twitter:image")
            ?? meta(html, name: "twitter:image")
        guard let raw else { return nil }
        let decoded = decode(raw)
        if let image = URL(string: decoded, relativeTo: base)?.absoluteURL, isPhoto(image) {
            return image
        }
        return nil
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        let pattern = "<\(name)[^>]*>(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?</\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), match.numberOfRanges > 1,
              let swift = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[swift]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func meta(_ html: String, property: String? = nil, name: String? = nil) -> String? {
        let key = property.map { "property=[\"']\($0)[\"']" } ?? "name=[\"']\(name ?? "")[\"']"
        let pattern = "<meta[^>]+(?:\(key))[^>]+content=[\"']([^\"']+)[\"']|<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:\(key))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range) else { return nil }
        for i in 1..<match.numberOfRanges {
            if let swift = Range(match.range(at: i), in: html) {
                let value = String(html[swift]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func sourceURL(in xml: String) -> String? {
        let pattern = #"<source[^>]+url=["'](https?://[^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), match.numberOfRanges > 1,
              let swift = Range(match.range(at: 1), in: xml) else { return nil }
        return unwrap(String(xml[swift]))
    }

    static func dateLine(_ date: Date) -> String {
        let hours = Date.now.timeIntervalSince(date) / 3600
        if hours < 36 {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            return rel.localizedString(for: date, relativeTo: .now)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func parsePublished(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = rfc.date(from: raw) { return date }
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = rfc.date(from: raw) { return date }
        rfc.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return rfc.date(from: raw)
    }

    static func displayTitle(_ raw: String) -> String {
        var t = plainText(raw)
        for sep in [" - ", " | ", " — ", " – "] {
            if let range = t.range(of: sep, options: .backwards) {
                let suffix = t[range.upperBound...]
                if suffix.count < 32, !suffix.contains(".") {
                    t = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return t
    }

    static func plainText(_ raw: String) -> String {
        var t = decode(raw)
        t = t.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    static func junk(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("<a") || lower.contains("href=") { return true }
        if lower.contains("news.google") { return true }
        if FeedCopy.isChrome(text), FeedCopy.withoutChrome(text).count < 40 { return true }
        return false
    }

    static func cleanCopy(_ text: String) -> String {
        FeedCopy.withoutChrome(plainText(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
