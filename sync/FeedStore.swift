import Foundation

struct FeedPost: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var saveID: UUID
    var title: String
    var script: String
    var headline: String
    var headlineURL: String
    var audioFileName: String
    var imageFileName: String
    var imageURL: String
    var sourceName: String
    var interest: String
    var createdAt: Date
    var publishedAt: Date
    var briefingReady: Bool

    enum CodingKeys: String, CodingKey {
        case id, saveID, title, script, headline, headlineURL, audioFileName, imageFileName, imageURL, sourceName, interest, createdAt, publishedAt, briefingReady
    }

    init(
        id: UUID,
        saveID: UUID,
        title: String,
        script: String,
        headline: String,
        headlineURL: String,
        audioFileName: String,
        imageFileName: String,
        imageURL: String = "",
        sourceName: String,
        interest: String,
        createdAt: Date,
        publishedAt: Date = .now,
        briefingReady: Bool = true
    ) {
        self.id = id
        self.saveID = saveID
        self.title = title
        self.script = script
        self.headline = headline
        self.headlineURL = headlineURL
        self.audioFileName = audioFileName
        self.imageFileName = imageFileName
        self.imageURL = imageURL
        self.sourceName = sourceName
        self.interest = interest
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.briefingReady = briefingReady
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        saveID = try c.decode(UUID.self, forKey: .saveID)
        title = try c.decode(String.self, forKey: .title)
        script = try c.decode(String.self, forKey: .script)
        headline = try c.decode(String.self, forKey: .headline)
        headlineURL = try c.decode(String.self, forKey: .headlineURL)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName) ?? ""
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName) ?? ""
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        interest = try c.decodeIfPresent(String.self, forKey: .interest) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt) ?? createdAt
        briefingReady = try c.decodeIfPresent(Bool.self, forKey: .briefingReady) ?? true
    }

    var articleSlug: String {
        let raw = title.isEmpty ? headline : title
        var slug = ""
        var dash = false
        for ch in raw.lowercased() {
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
        if slug.isEmpty { slug = "story" }
        let tag = id.uuidString.split(separator: "-").first.map(String.init)?.lowercased() ?? id.uuidString.lowercased()
        return "\(slug)-\(tag)"
    }

    var shareURL: URL {
        URL(string: "https://synchronous.sh/article/\(articleSlug)")!
    }

    var shareLink: URL {
        guard let packed = packedSharePayload, packed.count < 3500 else { return shareURL }
        return URL(string: "https://synchronous.sh/article/\(articleSlug)?p=\(packed)") ?? shareURL
    }

    var packedSharePayload: String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let body: [String: String] = [
            "slug": articleSlug,
            "title": title,
            "script": script,
            "sourceName": sourceName,
            "headlineURL": headlineURL,
            "imageURL": imageURL,
            "publishedAt": iso.string(from: publishedAt)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var cardBlurb: String {
        FeedCopy.blurb(script)
    }
}

enum FeedCopy {
    static func blurb(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\n", with: "\n")
        let cut = ["\n- ", "\n•", "\n* "]
        for marker in cut {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = splitSentences(collapsed).filter { !isChrome($0) }
        let target = 260
        let cap = 320
        var picked: [String] = []
        var length = 0
        for sentence in sentences {
            let next = picked.isEmpty ? sentence.count : length + 1 + sentence.count
            if picked.count >= 2, next > target { break }
            if !picked.isEmpty, next > cap { break }
            picked.append(sentence)
            length = next
            if picked.count == 3 || length >= target { break }
        }
        if picked.isEmpty {
            return String(collapsed.prefix(280))
        }
        return picked.joined(separator: " ")
    }

    static func withoutChrome(_ text: String) -> String {
        splitSentences(text).filter { !isChrome($0) }.joined(separator: " ")
    }

    static func isChrome(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "preferred source", "see more of our stories", "stories on google",
            "add yahoo", "add msn", "add cnn", "follow us", "subscribe",
            "sign up for", "newsletter", "enable notification", "we use cookies",
            "cookie policy", "advertisement", "tap here", "read more",
            "continue reading", "for subscribers", "download our app",
            "open in the app", "related coverage", "this content is provided",
            "google news", "turn on notifications"
        ]
        return needles.contains { lower.contains($0) }
    }

    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if piece.count > 12 {
                    sentences.append(piece)
                    current = ""
                }
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty, rest.last.map({ ".!?".contains($0) }) == true {
            sentences.append(rest)
        }
        return sentences
    }
}

enum FeedStore {
    private static var fileURL: URL? {
        guard let root = AppGroup.container else { return nil }
        let dir = root.appendingPathComponent("feed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("posts.json")
    }

    private static var seenURL: URL? {
        guard let root = AppGroup.container else { return nil }
        let dir = root.appendingPathComponent("feed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("seen.json")
    }

    static func fingerprint(title: String, url: String) -> String {
        let t = normalizedTitle(title)
        return t + "|" + canonical(url)
    }

    static func hasSeen(title: String, url: String) -> Bool {
        let print = fingerprint(title: title, url: url)
        if seenKeys().contains(print) { return true }
        let urlKey = canonical(url)
        if !urlKey.isEmpty, seenKeys().contains(where: { $0.hasSuffix("|" + urlKey) }) { return true }
        return seenTitles().contains { isSameStory(title, $0) }
    }

    static func rememberHeadline(title: String, url: String) {
        var keys = seenKeys()
        let key = fingerprint(title: title, url: url)
        if keys.contains(key) { return }
        keys.append(key)
        if keys.count > 800 { keys = Array(keys.suffix(800)) }
        saveSeen(keys)
    }

    static func remember(_ posts: [FeedPost]) {
        var keys = seenKeys()
        var titles = seenTitles()
        var keySet = Set(keys)
        for post in posts {
            let headline = post.headline.isEmpty ? post.title : post.headline
            let key = fingerprint(title: headline, url: post.headlineURL)
            if !keySet.contains(key) {
                keySet.insert(key)
                keys.append(key)
            }
            if !titles.contains(where: { isSameStory(headline, $0) }) {
                titles.append(normalizedTitle(headline))
            }
        }
        if keys.count > 400 { keys = Array(keys.suffix(400)) }
        if titles.count > 400 { titles = Array(titles.suffix(400)) }
        saveSeen(keys)
        saveTitles(titles)
    }

    static func load() -> [FeedPost] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = (try? decoder.decode([FeedPost].self, from: data)) ?? []
        return all.filter { FeedNews.isFresh($0.publishedAt) }
    }

    static func save(_ posts: [FeedPost]) {
        guard let url = fileURL else { return }
        let clipped = Array(posts.filter { FeedNews.isFresh($0.publishedAt) }.suffix(200))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(clipped).write(to: url, options: .atomic)
    }

    static func append(_ extra: [FeedPost]) {
        var all = load()
        var seenURL = Set(all.map { canonical($0.headlineURL) }.filter { !$0.isEmpty })
        var seenTitle = Set(all.map { fingerprint(title: $0.headline.isEmpty ? $0.title : $0.headline, url: $0.headlineURL) })
        var seenID = Set(all.map(\.id))
        for post in extra {
            if seenID.contains(post.id) { continue }
            let headline = post.headline.isEmpty ? post.title : post.headline
            let print = fingerprint(title: headline, url: post.headlineURL)
            if seenTitle.contains(print) { continue }
            if all.contains(where: { FeedStore.isSameStory(headline, $0.headline.isEmpty ? $0.title : $0.headline) }) { continue }
            let urlKey = canonical(post.headlineURL)
            if !urlKey.isEmpty, seenURL.contains(urlKey) { continue }
            all.append(post)
            seenID.insert(post.id)
            seenTitle.insert(print)
            if !urlKey.isEmpty { seenURL.insert(urlKey) }
        }
        save(all)
        remember(extra)
    }

    static func isSameStory(_ a: String, _ b: String) -> Bool {
        let leftWords = tokens(a)
        let rightWords = tokens(b)
        let left = Set(leftWords)
        let right = Set(rightWords)
        if left.isEmpty || right.isEmpty { return false }
        let shared = left.intersection(right)
        if shared.count >= 4 { return true }
        let shorter = min(left.count, right.count)
        return shared.count >= 3 && Double(shared.count) / Double(shorter) >= 0.72
    }

    static func clear() {
        save([])
    }

    static func clearSeen() {
        saveSeen([])
        saveTitles([])
        FeedStorySet.clear()
    }

    private static func tokens(_ title: String) -> [String] {
        let t = normalizedTitle(title)
        let stop: Set<String> = [
            "the", "and", "for", "with", "from", "this", "that", "says", "after",
            "over", "into", "will", "have", "been", "they", "their", "about",
            "could", "would", "should", "amid", "into", "what", "when", "your"
        ]
        var words: [String] = []
        var current = ""
        for ch in t {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { $0.count >= 4 && !stop.contains($0) }
    }

    private static func bigrams(_ words: [String]) -> [String] {
        guard words.count >= 2 else { return [] }
        return zip(words, words.dropFirst()).map { $0 + " " + $1 }
    }

    private static func normalizedTitle(_ title: String) -> String {
        var t = title.lowercased()
        for sep in [" - ", " | ", " — ", " – "] {
            if let range = t.range(of: sep) {
                t = String(t[..<range.lowerBound])
                break
            }
        }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var titlesURL: URL? {
        guard let root = AppGroup.container else { return nil }
        let dir = root.appendingPathComponent("feed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("seen-titles.json")
    }

    private static func seenTitles() -> [String] {
        guard let url = titlesURL, let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }

    private static func saveTitles(_ keys: [String]) {
        guard let url = titlesURL else { return }
        try? JSONEncoder().encode(keys).write(to: url, options: .atomic)
    }

    private static func seenKeys() -> [String] {
        guard let url = seenURL, let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }

    private static func saveSeen(_ keys: [String]) {
        guard let url = seenURL else { return }
        try? JSONEncoder().encode(keys).write(to: url, options: .atomic)
    }

    static func canonical(_ raw: String) -> String {
        guard let url = URL(string: raw), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return raw.lowercased()
        }
        comps.fragment = nil
        comps.query = nil
        comps.user = nil
        comps.password = nil
        comps.scheme = "https"
        if let host = comps.host?.lowercased() {
            comps.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        comps.path = comps.path.lowercased()
        return comps.string ?? raw.lowercased()
    }
}
