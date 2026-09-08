import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO)
import ImageIO
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

struct NewsHeadline: Equatable, Sendable, Codable {
    var title: String
    var url: String
    var snippet: String
    var source: String
    var imageURL: URL?
    var publishedAt: Date?

    var identity: String { url + "\u{1e}" + title }
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

    static func stories(for query: String, limit: Int = 8, scrapePages: Bool = false, skipSeen: Bool = true, requireMention: Bool = false, freshOnly: Bool = true) async -> [NewsHeadline] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var items: [NewsHeadline] = []
        await withTaskGroup(of: [NewsHeadline].self) { group in
            group.addTask {
                await rss(
                    URL(string: "https://news.google.com/rss/search?q=\(encode(q))&hl=en-US&gl=US&ceid=US:en"),
                    limit: limit * 3,
                    fresh: true
                )
            }
            group.addTask {
                await rss(
                    URL(string: "https://www.bing.com/news/search?q=\(encode(q))&format=rss"),
                    limit: limit * 2,
                    fresh: true
                )
            }
            group.addTask {
                await rss(
                    URL(string: "https://news.search.yahoo.com/rss?p=\(encode(q))"),
                    limit: limit * 2,
                    fresh: true
                )
            }
            for await batch in group {
                items.append(contentsOf: batch)
                let ready = uniqued(items, query: q, limit: limit, skipSeen: skipSeen, requireMention: requireMention, freshOnly: freshOnly)
                if ready.count >= min(limit, 4) {
                    group.cancelAll()
                    items = ready
                    break
                }
            }
        }
        if uniqued(items, query: q, limit: limit, skipSeen: skipSeen, requireMention: requireMention, freshOnly: freshOnly).count < limit {
            items.append(contentsOf: await newsAPIAI(q, limit: max(limit, 16)))
        }
        // #region agent log
        AgentDebug.log("N", "FeedNews.swift:stories", "raw", ["q": String(q.prefix(32)), "raw": items.count])
        // #endregion
        let generic = q.lowercased() == "top stories" || q.lowercased().hasSuffix(" news")
        if generic, items.filter({ $0.imageURL != nil }).count < max(3, limit / 2), items.count < limit {
            items.append(contentsOf: await picturedFeeds(category: "Top", limit: 12))
        }
        var unique = uniqued(items, query: q, limit: limit, skipSeen: skipSeen, requireMention: requireMention, freshOnly: freshOnly)
        // #region agent log
        AgentDebug.log("N", "FeedNews.swift:stories", "search", [
            "q": String(q.prefix(40)),
            "n": unique.count,
            "first": unique.first.map { String($0.title.prefix(48)) } ?? ""
        ])
        // #endregion
        if scrapePages {
            unique = await enrich(unique, query: q)
        }
        return unique.filter { !$0.title.isEmpty && !$0.url.isEmpty }
    }

    private static func uniqued(
        _ items: [NewsHeadline],
        query q: String,
        limit: Int,
        skipSeen: Bool,
        requireMention: Bool,
        freshOnly: Bool
    ) -> [NewsHeadline] {
        var seen = Set<String>()
        var unique: [NewsHeadline] = []
        for item in items {
            if skipSeen, FeedStore.hasSeen(title: item.title, url: item.url) { continue }
            let key = FeedStore.fingerprint(title: item.title, url: item.url)
            if seen.contains(key) { continue }
            if junk(item.title) || junk(item.snippet) { continue }
            if freshOnly, !isFresh(item.publishedAt) { continue }
            if requireMention, !mentions(item, q) { continue }
            seen.insert(key)
            unique.append(item)
        }
        let hits = unique.filter { mentions($0, q) || containsPhrase($0.title, q) || $0.title.lowercased().contains(q.lowercased()) }
        if !hits.isEmpty { unique = hits }
        unique.sort { left, right in
            let leftPhoto = left.imageURL != nil
            let rightPhoto = right.imageURL != nil
            if leftPhoto != rightPhoto { return leftPhoto }
            let leftTitle = containsPhrase(left.title, q)
            let rightTitle = containsPhrase(right.title, q)
            if leftTitle != rightTitle { return leftTitle }
            return (left.publishedAt ?? .distantPast) > (right.publishedAt ?? .distantPast)
        }
        if unique.count > limit { unique = Array(unique.prefix(limit)) }
        return unique
    }

    private static let photoSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static let snappy: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    static func browse(category: String, limit: Int = 12, fresh: Bool = false, skipAPI: Bool = false) async -> [NewsHeadline] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var items: [NewsHeadline] = []
        await withTaskGroup(of: [NewsHeadline].self) { group in
            group.addTask { await picturedFeeds(category: category, limit: limit * 2, fresh: fresh) }
            if let topic = topicFeed(category) {
                group.addTask { await rss(topic, limit: limit * 2, fresh: fresh) }
            }
            for await batch in group {
                items.append(contentsOf: batch)
            }
        }
        var seen = Set<String>()
        var unique: [NewsHeadline] = []
        func absorb(_ batch: [NewsHeadline]) {
            for item in batch {
                let key = FeedStore.fingerprint(title: item.title, url: item.url)
                if seen.contains(key) { continue }
                if junk(item.title) || junk(item.snippet) { continue }
                if !matches(category, item) { continue }
                seen.insert(key)
                unique.append(item)
            }
        }
        absorb(items)
        // #region agent log
        AgentDebug.log("A", "FeedNews.browse", "rss", [
            "cat": category,
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "n": unique.count,
            "skipAPI": skipAPI
        ])
        // #endregion
        if skipAPI || unique.count >= limit {
            return TasteEngine.rankNews(unique, category: category, limit: limit)
        }
        let api = await newsAPIAI(NewsTabView.query(for: category), limit: limit * 2, category: category)
        absorb(api.filter { matches(category, $0) })
        // #region agent log
        AgentDebug.log("A", "FeedNews.browse", "api", [
            "cat": category,
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "n": unique.count
        ])
        // #endregion
        return TasteEngine.rankNews(Array(unique.prefix(max(limit * 3, 24))), category: category, limit: limit)
    }

    static func searchHeadlines(_ query: String, limit: Int = 12) async -> [NewsHeadline] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var items = await newsAPIAI(q, limit: limit * 2)
        if items.count < 4 {
            items.append(contentsOf: await rss(
                URL(string: "https://news.google.com/rss/search?q=\(encode(q))&hl=en-US&gl=US&ceid=US:en"),
                limit: limit * 2
            ))
        }
        var seen = Set<String>()
        var unique: [NewsHeadline] = []
        for item in items {
            let key = FeedStore.fingerprint(title: item.title, url: item.url)
            if seen.contains(key) { continue }
            if junk(item.title) || junk(item.snippet) { continue }
            seen.insert(key)
            unique.append(item)
            if unique.count >= limit { break }
        }
        return unique
    }

    static func fillPhotos(_ items: [NewsHeadline]) async -> [NewsHeadline] {
        await withTaskGroup(of: (Int, NewsHeadline).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    var next = item
                    if next.imageURL == nil || (next.imageURL.map(isJunkPhoto) ?? false) {
                        if let url = URL(string: next.url), let photo = await articlePhotos(url).first {
                            next.imageURL = photo
                        }
                    }
                    return (index, next)
                }
            }
            var slotted = items
            for await (index, item) in group {
                slotted[index] = item
            }
            return slotted
        }
    }

    private static func topicFeed(_ category: String) -> URL? {
        let topic: String? = switch category {
        case "Top", "For You": nil
        case "U.S.": "NATION"
        case "World": "WORLD"
        case "Business": "BUSINESS"
        case "Technology": "TECHNOLOGY"
        case "Science": "SCIENCE"
        case "Entertainment": "ENTERTAINMENT"
        case "Sports": "SPORTS"
        case "Lifestyle": "HEALTH"
        default: nil
        }
        if let topic {
            return URL(string: "https://news.google.com/rss/headlines/section/topic/\(topic)?hl=en-US&gl=US&ceid=US:en")
        }
        if category == "Top" || category == "For You" {
            return URL(string: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en")
        }
        return URL(string: "https://news.google.com/rss/search?q=\(encode(NewsTabView.query(for: category)))&hl=en-US&gl=US&ceid=US:en")
    }

    private static func picturedFeeds(category: String = "Top", limit: Int = 20, fresh: Bool = false) async -> [NewsHeadline] {
        let yahoo: String? = switch category {
        case "World": "world"
        case "Science": "science"
        case "Technology": "tech"
        case "Business": "finance"
        case "Sports": "sports"
        case "Entertainment": "entertainment"
        case "Lifestyle", "Food": "health"
        default: nil
        }
        var urls: [URL?] = []
        if let path = yahoo {
            urls.append(URL(string: "https://news.yahoo.com/rss/\(path)"))
        }
        switch category {
        case "Top", "For You":
            urls.append(contentsOf: [
                URL(string: "https://news.yahoo.com/rss/"),
                URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
                URL(string: "https://feeds.bbci.co.uk/news/rss.xml"),
                URL(string: "https://www.theguardian.com/us/rss")
            ])
        case "Science":
            urls.append(URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Science.xml"))
        case "Business":
            urls.append(URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Business.xml"))
        case "Sports":
            urls.append(contentsOf: [
                URL(string: "https://feeds.bbci.co.uk/sport/rss.xml"),
                URL(string: "https://www.espn.com/espn/rss/news"),
                URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Sports.xml")
            ])
        case "Technology":
            urls.append(URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml"))
        case "U.S.":
            urls.append(URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/US.xml"))
        case "World":
            urls.append(URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml"))
        default:
            break
        }
        var out: [NewsHeadline] = []
        await withTaskGroup(of: [NewsHeadline].self) { group in
            for url in urls.compactMap({ $0 }) {
                group.addTask { await rss(url, limit: limit, fresh: fresh) }
            }
            for await batch in group {
                out.append(contentsOf: batch)
            }
        }
        return out.filter { $0.imageURL != nil || matches(category, $0) }
    }

    private static func matches(_ category: String, _ item: NewsHeadline) -> Bool {
        if category == "Top" || category == "For You" { return true }
        let blob = [item.title, item.snippet, item.source, item.url].joined(separator: " ").lowercased()
        func any(_ words: [String]) -> Bool { words.contains { blob.contains($0) } }
        switch category {
        case "Sports":
            return any([
                "sport", "nfl", "nba", "mlb", "nhl", "ncaa", "wnba", "mls",
                "soccer", "football", "basketball", "baseball", "hockey", "tennis",
                "golf", "olympics", "premier league", "la liga", "serie a", "bundesliga",
                "fifa", "uefa", "world cup", "playoff", "espn", "quarterback", "touchdown",
                "inning", "home run", "coach", "athlete", "boxing", "ufc", "mma",
                "formula 1", "f1", "nascar", "cricket", "rugby", "wimbledon", "masters",
                "super bowl", "world series", "stanley cup", "march madness"
            ])
        case "Business":
            return any([
                "business", "market", "stock", "shares", "investor", "economy", "bank",
                "fed ", "inflation", "revenue", "earnings", "ipo", "merger", "trade",
                "wall street", "nasdaq", "dow ", "ceo", "company", "corp"
            ])
        case "Technology":
            return any([
                "tech", "software", "app ", "ai ", "artificial intelligence", "chip",
                "google", "apple", "microsoft", "meta", "amazon", "openai", "startup",
                "cyber", "robot", "iphone", "android", "semiconductor"
            ])
        case "Science":
            return any([
                "science", "scientist", "nasa", "space", "physics", "biology", "climate",
                "research", "study finds", "quantum", "genome", "telescope", "lab "
            ])
        case "Entertainment":
            return any([
                "movie", "film", "actor", "actress", "hollywood", "netflix", "music",
                "album", "oscar", "grammy", "tv ", "series", "celebrity", "concert"
            ])
        case "Food":
            return any([
                "food", "recipe", "restaurant", "chef", "cooking", "cuisine", "dining"
            ])
        case "Lifestyle":
            return any([
                "health", "wellness", "fitness", "sleep", "diet", "mental health", "lifestyle"
            ])
        case "History":
            return any([
                "history", "historic", "archaeolog", "ancient", "museum", "artifact",
                "civil war", "empire", "excavation", "heritage"
            ])
        case "World", "U.S.":
            return true
        default:
            return true
        }
    }

    private static func wikiImage(for title: String) async -> URL? {
        let cleaned = title
            .split(separator: "—").first
            .map(String.init) ?? title
        let short = cleaned
            .replacingOccurrences(of: #"\s[-–|].*$"#, with: "", options: .regularExpression)
            .split(separator: " ")
            .prefix(5)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard short.count >= 3,
              let encoded = short.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        guard let (data, _) = try? await snappy.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let pageTitle = json["title"] as? String ?? ""
        guard titleOverlap(pageTitle, title) else { return nil }
        let thumb = (json["originalimage"] as? [String: Any])?["source"] as? String
            ?? (json["thumbnail"] as? [String: Any])?["source"] as? String
        guard let thumb, let image = URL(string: thumb), isPhoto(image) || isWikiPhoto(image) else { return nil }
        return image
    }

    private static func titleOverlap(_ page: String, _ headline: String) -> Bool {
        func tokens(_ raw: String) -> Set<String> {
            Set(
                raw.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                    .filter { $0.count >= 4 && !["this", "that", "with", "from", "have", "will", "about", "after", "before"].contains($0) }
            )
        }
        let shared = tokens(page).intersection(tokens(headline))
        return shared.count >= 2 || shared.contains(where: { $0.count >= 8 })
    }

    private static func isWikiPhoto(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("wikipedia") || host.contains("wikimedia")
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
        var current = ""
        for ch in title {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if current.count >= 2, current.first?.isUppercase == true {
                    names.append(current)
                }
                current = ""
            }
        }
        if current.count >= 2, current.first?.isUppercase == true {
            names.append(current)
        }
        let skip: Set<String> = [
            "ai", "news", "world", "business", "technology", "science", "top", "stories",
            "update", "live", "latest", "the", "and"
        ]
        names = names.filter { !skip.contains($0.lowercased()) }
        return await firstPortrait(Array(names.prefix(3)))
    }

    static func loadFastImage(title: String, interest: String, imageURL: String, id: UUID, articleURL: String = "", allowGuess: Bool = true, vertical: Bool = false, summary: String = "") async -> UIImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        if let cached = FeedImageCache.image(for: id) {
            // #region agent log
            AgentDebug.log("A", "FeedNews.loadFastImage", "cache_hit", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)])
            // #endregion
            return cached
        }
        let story = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = "\(title). \(story.isEmpty ? "" : String(story.prefix(140)))"
        Task(priority: .utility) {
            guard FeedImageCache.image(for: id) == nil else { return }
            if let image = await StudioImage.fast(prompt: prompt, id: id, vertical: false) {
                FeedImageCache.store(image, for: id)
                await MainActor.run { FeedPhotoBox.shared.generationBump() }
            }
        }
        let pack = StudioPack.image(for: id)
        // #region agent log
        AgentDebug.log("B", "FeedNews.loadFastImage", "pack_return", [
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "packNil": pack == nil,
            "w": Int(pack?.size.width ?? 0)
        ])
        // #endregion
        return pack
    }

    private static func guaranteedPhoto(id: UUID) async -> UIImage? {
        let seed = String(id.uuidString.prefix(8))
        guard let url = URL(string: "https://picsum.photos/seed/\(seed)/768/1280") else { return nil }
        if let name = await downloadImage(url, id: id, skipFilter: true, timeout: 12, maxPixel: 960),
           let image = diskImage(name) ?? FeedImageCache.image(for: id) {
            FeedImageCache.store(image, for: id)
            return image
        }
        return nil
    }

    static func loadHeroImage(for post: FeedPost) async -> UIImage? {
        await loadFastImage(for: post)
    }

    static func loadFastImage(for post: FeedPost) async -> UIImage? {
        let artID = photoID(url: post.headlineURL, title: post.title.isEmpty ? post.headline : post.title)
        if let cached = FeedImageCache.image(for: artID) {
            FeedImageCache.store(cached, for: post.id)
            return cached
        }
        let title = post.title.isEmpty ? post.headline : post.title
        let summary = post.script.isEmpty ? post.headline : post.script
        let image = await loadFastImage(
            title: title,
            interest: post.interest,
            imageURL: "",
            id: artID,
            articleURL: post.headlineURL,
            allowGuess: true,
            vertical: true,
            summary: summary
        )
        if let image {
            FeedImageCache.store(image, for: post.id)
        }
        return image
    }

    static func loadFastImage(for story: NewsHeadline) async -> UIImage? {
        let id = photoID(for: story)
        if let cached = FeedImageCache.image(for: id) { return cached }
        return await loadFastImage(
            title: story.title,
            interest: story.source,
            imageURL: "",
            id: id,
            articleURL: story.url,
            allowGuess: true,
            summary: story.snippet
        )
    }

    static func photoID(for story: NewsHeadline) -> UUID {
        photoID(url: story.url, title: story.title)
    }

    static func photoID(url: String, title: String) -> UUID {
        let key = "art-v3|" + (url.isEmpty ? title : url)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in Array(key.utf8).enumerated() {
            bytes[i % 16] ^= byte
            bytes[(i &* 3) % 16] &+= byte &* 31
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func diskImage(_ name: String) -> UIImage? {
        guard let url = MediaStore.fileURL(name),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image
    }

    private static func usableImage(_ name: String) -> UIImage? {
        guard let image = diskImage(name), isUsablePhoto(image) else { return nil }
        return image
    }

    private static func isUsablePhoto(_ image: UIImage) -> Bool {
        let w = image.size.width * image.scale
        let h = image.size.height * image.scale
        guard w >= 140, h >= 90 else { return false }
        let ratio = w / max(h, 1)
        if ratio > 6.5 || ratio < 0.2 { return false }
        return true
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
                    // #region agent log
                    AgentDebug.log("A", "FeedNews.swift:firstPortrait", "portrait", [
                        "names": names.prefix(3).joined(separator: "|"),
                        "host": url.host ?? "",
                        "path": String(url.path.suffix(48))
                    ])
                    // #endregion
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
        let artID = photoID(url: story.url, title: story.title)
        let image = await loadFastImage(
            title: story.title,
            interest: interest,
            imageURL: "",
            id: artID,
            articleURL: story.url,
            allowGuess: true,
            vertical: true,
            summary: story.snippet
        )
        guard let image, let jpeg = image.jpegData(compressionQuality: 0.86) else {
            return ("", "")
        }
        FeedImageCache.store(image, for: id)
        return (MediaStore.save(jpeg, id: id), "")
    }

    static func downloadImage(_ url: URL, id: UUID, referer: String = "", skipFilter: Bool = false, timeout: TimeInterval = 8, maxPixel: Int = 960) async -> String? {
        if !skipFilter, !isPhoto(url) { return nil }
        var target = url
        if target.scheme == "http",
           var comps = URLComponents(url: target, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            target = comps.url ?? target
        }
        var request = URLRequest(url: target)
        let slow = (target.host ?? "").contains("pollinations") || (target.host ?? "").contains("wsrv.nl")
        request.timeoutInterval = slow ? max(timeout, 12) : timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .responsiveData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let ref = URL(string: referer),
           ref.scheme?.hasPrefix("http") == true,
           !isAggregator(ref) {
            request.setValue(ref.absoluteString, forHTTPHeaderField: "Referer")
        }
        guard let (data, response) = try? await photoSession.data(for: request),
              data.count > 400 else { return nil }
        if let saved = persistImage(data, response: response, id: id, skipFilter: skipFilter, maxPixel: maxPixel) {
            return saved
        }
        if let proxy = proxied(target), proxy != target {
            var next = URLRequest(url: proxy)
            next.timeoutInterval = 8
            next.networkServiceType = .responsiveData
            next.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            if let (proxiedData, proxiedResponse) = try? await photoSession.data(for: next),
               let saved = persistImage(proxiedData, response: proxiedResponse, id: id, skipFilter: skipFilter, maxPixel: maxPixel) {
                return saved
            }
        }
        return nil
    }

    private static func persistImage(_ data: Data, response: URLResponse, id: UUID, skipFilter: Bool, maxPixel: Int = 960) -> String? {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        if let http = response as? HTTPURLResponse,
           let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.contains("svg") || type.contains("html") || type.contains("text/html") {
            return nil
        }
        #if canImport(UIKit)
        guard let image = decodeImage(from: data, maxPixel: maxPixel) else { return nil }
        if !skipFilter, !isUsablePhoto(image) { return nil }
        FeedImageCache.store(image, for: id)
        if let jpeg = image.jpegData(compressionQuality: 0.82) {
            return MediaStore.save(jpeg, id: id, ext: "jpg")
        }
        #endif
        return MediaStore.save(data, id: id, ext: "jpg")
    }

    private static func decodeImage(from data: Data, maxPixel: Int = 960) -> UIImage? {
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
#endif
        return UIImage(data: data)
    }

    private static func newsAPIAI(_ query: String, limit: Int, category: String? = nil) async -> [NewsHeadline] {
        let key = NewsAPIKey.load()
        guard !key.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let top = category == "Top" || category == "For You" || trimmed.lowercased() == "top stories"
        var body: [String: Any] = [
            "action": "getArticles",
            "lang": "eng",
            "articlesCount": min(max(limit, 8), 50),
            "articlesSortBy": "date",
            "articleBodyLen": 1200,
            "resultType": "articles",
            "dataType": ["news"],
            "forceMaxDataTimeWindow": top ? 31 : 180,
            "isDuplicateFilter": "skipDuplicates",
            "includeArticleImage": true,
            "includeArticleBasicInfo": true,
            "includeSourceTitle": true,
            "apiKey": key
        ]
        if top {
            body["sourceLocationUri"] = "http://en.wikipedia.org/wiki/United_States"
        } else if let uri = newsAPICategoryURI(category) {
            body["categoryUri"] = uri
        } else if trimmed.count >= 2 {
            body["keyword"] = trimmed
            body["keywordOper"] = "and"
        }
        if let loc = newsAPILocationURI(category) {
            body["sourceLocationUri"] = loc
        }
        let endpoints = [
            "https://eventregistry.org/api/v1/article/getArticles",
            "https://newsapi.ai/api/v1/article/getArticles"
        ]
        return await withTaskGroup(of: [NewsHeadline].self) { group in
            for endpoint in endpoints {
                group.addTask { await newsAPIAIRequest(url: endpoint, body: body) }
            }
            var found: [NewsHeadline] = []
            for await batch in group {
                if !batch.isEmpty {
                    found = batch
                    group.cancelAll()
                    break
                }
            }
            return found
        }
    }

    private static func newsAPIAIRequest(url endpoint: String, body: [String: Any]) async -> [NewsHeadline] {
        guard let url = URL(string: endpoint) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseNewsAPIArticles(json)
    }

    private static func newsAPICategoryURI(_ category: String?) -> String? {
        switch category {
        case "Business": "news/Business"
        case "Technology": "news/Technology"
        case "Science": "news/Science"
        case "Sports": "news/Sports"
        case "Entertainment": "news/Arts_and_Entertainment"
        case "Lifestyle", "Food": "news/Health"
        default: nil
        }
    }

    private static func newsAPILocationURI(_ category: String?) -> String? {
        switch category {
        case "U.S.": "http://en.wikipedia.org/wiki/United_States"
        default: nil
        }
    }

    private static func parseNewsAPIArticles(_ json: [String: Any]) -> [NewsHeadline] {
        let results = ((json["articles"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        var out: [NewsHeadline] = []
        for article in results {
            let title = displayTitle(article["title"] as? String ?? "")
            let link = (article["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 8, link.hasPrefix("http") else { continue }
            let snippet = cleanCopy(article["body"] as? String ?? article["dataType"] as? String ?? "")
            let source = ((article["source"] as? [String: Any])?["title"] as? String ?? "")
            let image = newsAPIImage(article)
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

    private static func newsAPIImage(_ article: [String: Any]) -> URL? {
        if let raw = article["image"] as? String, let url = URL(string: raw), looksLikeImage(url) || raw.hasPrefix("http") {
            return url
        }
        if let dict = article["image"] as? [String: Any] {
            for key in ["url", "src", "source"] {
                if let raw = dict[key] as? String, let url = URL(string: raw) { return url }
            }
        }
        if let links = article["links"] as? [String] {
            for raw in links {
                if let url = URL(string: raw), looksLikeImage(url) { return url }
            }
        }
        return nil
    }

    private static func rss(_ url: URL?, limit: Int, fresh: Bool = false) async -> [NewsHeadline] {
        guard let url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        let xml = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let parsed = parseItems(xml, limit: limit)
        // #region agent log
        AgentDebug.log("N", "FeedNews.swift:rss", "parse", [
            "host": url.host ?? "",
            "bytes": data.count,
            "n": parsed.count
        ])
        // #endregion
        return parsed
    }

    private static func parseItems(_ xml: String, limit: Int) -> [NewsHeadline] {
        var out: [NewsHeadline] = []
        var search = xml.startIndex
        while out.count < limit,
              let start = xml.range(of: "<item", options: .caseInsensitive, range: search..<xml.endIndex),
              let end = xml.range(of: "</item>", options: .caseInsensitive, range: start.upperBound..<xml.endIndex) {
            let item = String(xml[start.lowerBound..<end.upperBound])
            search = end.upperBound
            let title = displayTitle(decode(tag("title", in: item) ?? ""))
            var link = unwrap(tag("link", in: item) ?? "")
            let rawDesc = tag("description", in: item) ?? ""
            if URL(string: link).map(isAggregator) == true,
               let article = publisherArticle(in: item) ?? publisherArticle(in: rawDesc) {
                link = article
            }
            let snippet = cleanCopy(rawDesc)
            let source = decode(tag("News:Source", in: item) ?? tag("source", in: item) ?? "")
            guard title.count > 8, !link.isEmpty else { continue }
            if junk(snippet) || junk(title) { continue }
            let lower = (title + snippet).lowercased()
            if lower.contains("google news") { continue }
            if lower.contains("aggregates global coverage") { continue }
            var image = imageURL(in: item) ?? imageURL(in: rawDesc)
            if let img = image, isJunkPhoto(img) { image = nil }
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
            #"<media:content[^>]+url=["']([^"']+)["']"#,
            #"<media:thumbnail[^>]+url=["']([^"']+)["']"#,
            #"<enclosure[^>]+(?:type=["']image[^"']*["'][^>]+)?url=["']([^"']+)["']"#,
            #"<img[^>]+src=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            for match in regex.matches(in: xml, options: [], range: range) {
                guard match.numberOfRanges > 1 else { continue }
                for i in 1..<match.numberOfRanges {
                    guard let swift = Range(match.range(at: i), in: xml) else { continue }
                    let raw = decode(String(xml[swift])).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: raw), looksLikeImage(url) else { continue }
                    if isJunkPhoto(url) { continue }
                    return url
                }
            }
        }
        return nil
    }

    private static func enrich(_ items: [NewsHeadline], query: String) async -> [NewsHeadline] {
        await withTaskGroup(of: (Int, NewsHeadline).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await page(item, wiki: nil)) }
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
        if next.imageURL.map(isJunkPhoto) == true {
            next.imageURL = nil
        }
        let needsPage = next.snippet.count <= 40 || next.imageURL == nil || (next.imageURL.map(isJunkPhoto) ?? true)
        if needsPage {
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
                if let image = imagesFromHTML(html, base: url).first {
                    next.imageURL = image
                }
            }
        }
        return next
    }

    static func articleExcerpt(url raw: String, fallback: String) async -> String {
        let backup = cleanCopy(fallback)
        guard let start = URL(string: raw) else { return backup }
        let page = await resolvedArticle(start) ?? start
        guard let html = await html(page) else { return backup }
        let og = meta(html, property: "og:description")
            ?? meta(html, name: "description")
            ?? ""
        var paras: [String] = []
        let pattern = #"<p[^>]*>(.*?)</p>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, options: [], range: range).prefix(12) {
                guard match.numberOfRanges > 1, let swift = Range(match.range(at: 1), in: html) else { continue }
                let line = cleanCopy(String(html[swift]))
                if line.count < 40 { continue }
                if line.lowercased().contains("subscribe") { continue }
                paras.append(line)
                if paras.joined(separator: " ").count > 3200 { break }
            }
        }
        let combined = cleanCopy(([og] + paras).filter { !$0.isEmpty }.joined(separator: "\n"))
        if combined.count < 80 { return backup }
        return String(combined.prefix(2800))
    }

    private static func html(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.allowsConstrainedNetworkAccess = false
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
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

    private static func safeReferer(_ raw: String) -> String {
        guard let url = URL(string: raw),
              url.scheme?.hasPrefix("http") == true,
              !isAggregator(url) else { return "" }
        return url.absoluteString
    }

    static func isAggregator(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("news.google") || host.contains("bing.com") || host.contains("news.yahoo")
    }

    static func isJunkPhoto(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let blob = host + " " + path
        if path.hasSuffix(".svg") || path.hasSuffix(".ico") || path.hasSuffix(".gif") { return true }
        if path == "/" || path.isEmpty { return true }
        if isAggregator(url), !looksLikeImage(url) { return true }
        if !looksLikeImage(url), path.split(separator: "/").count <= 1 { return true }
        let banned = [
            "favicon", "wordmark", "masthead", "sprite", "placeholder",
            "default-image", "og-default", "site-icon", "apple-touch", "brandmark",
            "flag_of", "flag-of", "us-flag", "american-flag", "seal_of", "coat_of_arms",
            "apple-touch-icon", "default-og", "sharing-default"
        ]
        if banned.contains(where: { blob.contains($0) }) { return true }
        let file = path.split(separator: "/").last.map(String.init) ?? ""
        if file.hasPrefix("logo") || file.contains("favicon") { return true }
        if host.contains("gstatic.com"), blob.contains("icon"), !blob.contains("encrypted-tbn") { return true }
        return false
    }

    private static func looksLikeImage(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", "/image", "/img", "/photo", "attachments", "encrypted-tbn", "tnimage", "fife", "media.zenfs", "ichef.bbci", "static01.nyt", "i.guim", "googleusercontent"]
            .contains { text.contains($0) }
    }

    private static func isPhoto(_ url: URL) -> Bool {
        !isJunkPhoto(url) && url.absoluteString.lowercased().contains("http")
    }

    private static func publisherArticle(in xml: String) -> String? {
        let pattern = #"https?://[^"'<\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, options: [], range: range) {
            guard let swift = Range(match.range, in: xml),
                  let url = URL(string: decode(String(xml[swift])).trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))) else { continue }
            if isAggregator(url) { continue }
            let path = url.path
            if path.count < 12 { continue }
            let lower = path.lowercased()
            if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp") {
                continue
            }
            return url.absoluteString
        }
        return nil
    }

    private static func resolvedArticle(_ url: URL?) async -> URL? {
        guard let url else { return nil }
        if !isAggregator(url) { return url }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let final = response.url, !isAggregator(final), final.path.count > 1 {
            return final
        }
        if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
           let found = publisherArticle(in: html),
           let dest = URL(string: found),
           !isAggregator(dest) {
            return dest
        }
        return nil
    }

    private static func articlePhoto(_ url: URL) async -> URL? {
        await articlePhotos(url).first
    }

    private static func articlePhotos(_ url: URL) async -> [URL] {
        guard let article = await resolvedArticle(url), let html = await html(article) else { return [] }
        return imagesFromHTML(html, base: article)
    }

    private static func imagesFromHTML(_ html: String, base: URL) -> [URL] {
        var found: [URL] = []
        func add(_ raw: String?) {
            guard let raw, let image = absolutePhoto(raw, base: base) else { return }
            if found.contains(image) { return }
            found.append(image)
        }
        for raw in [
            meta(html, property: "og:image"),
            meta(html, property: "og:image:url"),
            meta(html, property: "og:image:secure_url"),
            meta(html, property: "twitter:image"),
            meta(html, name: "twitter:image"),
            meta(html, property: "twitter:image:src")
        ] {
            add(raw)
        }
        let linkPattern = #"<link[^>]+rel=["']image_src["'][^>]+href=["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
               let swift = Range(match.range(at: 1), in: html) {
                add(String(html[swift]))
            }
        }
        let imgPattern = #"<img[^>]+(?:src|data-src|data-original)=["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let articleHost = (base.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
            for match in regex.matches(in: html, options: [], range: range).prefix(12) {
                guard match.numberOfRanges > 1, let swift = Range(match.range(at: 1), in: html) else { continue }
                let raw = decode(String(html[swift]))
                if raw.contains("1x1") || raw.contains("pixel") || raw.contains("spacer") { continue }
                guard let image = absolutePhoto(raw, base: base) else { continue }
                let host = (image.host ?? "").lowercased()
                let related = host.contains(articleHost) || host.contains("wp.com") || host.contains("cloudfront")
                    || host.contains("googleusercontent") || host.contains("gstatic") || host.contains("twimg")
                    || host.contains("fbcdn") || host.contains("npr.org") || host.contains("nyt.com")
                if related { add(raw) }
            }
        }
        return found
    }

    private static func parsePhotoURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        if text.hasPrefix("//") { text = "https:" + text }
        if let url = URL(string: text), url.scheme != nil { return url }
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            return URL(string: encoded)
        }
        return nil
    }

    private static func proxied(_ url: URL) -> URL? {
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://wsrv.nl/?url=\(encoded)&output=jpg")
    }

    private static func absolutePhoto(_ raw: String, base: URL) -> URL? {
        let text = decode(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text
        for item in [text, encoded] {
            if let image = URL(string: item, relativeTo: base)?.absoluteURL, isPhoto(image) {
                return image
            }
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
        let plain = FeedCopy.withoutChrome(plainText(text))
        let lower = plain.lowercased()
        if lower.contains("news.google") { return true }
        if FeedCopy.isChrome(plain), plain.count < 40 { return true }
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
