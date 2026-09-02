import Foundation

enum FeedStudio {
    private static let skip = Set([
        "tiktok", "instagram", "youtube", "facebook", "twitter", "x", "reddit",
        "google", "spotify", "video", "videos", "social", "viral", "content",
        "post", "reel", "reels", "shorts", "music", "coding",
        "startup ideas", "design inspiration", "places to eat", "travel",
        "fitness", "recipes", "fashion", "web", "link", "entertainment",
        "app", "news", "update", "song", "album", "artist", "chrome",
        "apple", "iphone", "internet", "website", "blog", "podcast", "live",
        "official", "new", "best", "top", "free", "online",
        "release", "playlist", "playlists", "genre", "marketing",
        "campaign", "track", "tracks", "single", "album", "ep"
    ])

    @MainActor
    static func fill(
        from saves: [SaveItem],
        count: Int = 12,
        replace: Bool = false,
        onPost: ((FeedPost) -> Void)? = nil
    ) async -> [FeedPost] {
        await runFill(from: saves, count: count, replace: replace, onPost: onPost)
    }

    @MainActor
    private static func runFill(
        from saves: [SaveItem],
        count: Int,
        replace: Bool,
        onPost: ((FeedPost) -> Void)?
    ) async -> [FeedPost] {
        let previous = replace ? FeedStore.load() : []
        if replace {
            FeedStore.clearSeen()
        }
        let existing = FeedStore.load()
        var used = Set<String>()
        var usedTitles: [String] = []
        for post in existing {
            used.insert(FeedStore.fingerprint(title: post.headline.isEmpty ? post.title : post.headline, url: post.headlineURL))
            usedTitles.append(post.headline.isEmpty ? post.title : post.headline)
        }
        let all = {
            let fromLibrary = interests(in: saves)
            return fromLibrary.isEmpty ? starterInterests() : fromLibrary
        }()
        let take = min(8, all.count)
        let start = existing.count % max(all.count, 1)
        let pool = all.isEmpty ? [] : (0..<take).map { all[(start + $0) % all.count] }

        var headlines: [[NewsHeadline]] = Array(repeating: [], count: pool.count)
        let want = max(count, 8)

        await withTaskGroup(of: (Int, [NewsHeadline]).self) { group in
            for (i, interest) in pool.enumerated() {
                group.addTask {
                    var stories = await FeedNews.stories(for: interest.query, limit: 24)
                    if stories.count < 8 {
                        for extra in interest.extras.prefix(2) {
                            stories.append(contentsOf: await FeedNews.stories(for: extra, limit: 12))
                        }
                    }
                    stories.sort { ($0.imageURL != nil ? 0 : 1) < ($1.imageURL != nil ? 0 : 1) }
                    return (i, stories)
                }
            }
            for await (i, stories) in group {
                headlines[i] = stories
            }
        }

        var candidates: [(index: Int, interest: Interest, story: NewsHeadline)] = []
        var cursor = Array(repeating: 0, count: pool.count)
        let cap = max(want * 3, 12)
        while candidates.count < cap {
            var added = false
            for i in pool.indices {
                if candidates.count >= cap { break }
                let interest = pool[i]
                while cursor[i] < headlines[i].count {
                    let story = headlines[i][cursor[i]]
                    cursor[i] += 1
                    let print = FeedStore.fingerprint(title: story.title, url: story.url)
                    if used.contains(print) { continue }
                    if !replace, FeedStore.hasSeen(title: story.title, url: story.url) { continue }
                    if usedTitles.contains(where: { FeedStore.isSameStory(story.title, $0) }) { continue }
                    used.insert(print)
                    usedTitles.append(story.title)
                    candidates.append((i, interest, story))
                    added = true
                    break
                }
            }
            if !added { break }
        }

        if candidates.isEmpty {
            let backup = await FeedNews.stories(for: "top stories", limit: 20, skipSeen: false)
            let interest = pool.first ?? Interest(
                query: "world news",
                saveID: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
                why: "",
                extras: [],
                savedAt: .now
            )
            for story in backup.prefix(12) {
                let print = FeedStore.fingerprint(title: story.title, url: story.url)
                if used.contains(print) { continue }
                used.insert(print)
                candidates.append((0, interest, story))
            }
        }

        var made: [FeedPost] = []
        var replacedStore = !replace
        for pair in candidates {
            let post = listPost(story: pair.story, interest: pair.interest)
            if made.contains(where: { FeedStore.isSameStory(post.headline, $0.headline) }) { continue }
            made.append(post)
            if replace, !replacedStore {
                FeedStore.save([post])
                replacedStore = true
            } else {
                FeedStore.append([post])
            }
            FeedStorySet.remember(post)
            onPost?(post)
            if made.count >= want { break }
        }
        if !made.isEmpty {
            Task { await ensureBriefings(made) }
        }

        if replace, made.isEmpty, !previous.isEmpty {
            FeedStore.save(previous)
            return previous
        }
        return FeedStore.load()
    }

    @MainActor
    static func search(_ raw: String, count: Int = 8, onPost: ((FeedPost) -> Void)? = nil) async -> [FeedPost] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return [] }
        let topic = expand(await newsQuery(from: typed))
        var extras: [String] = []
        for item in [typed, topic] {
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = t.lowercased()
            if t.count < 2 { continue }
            if extras.contains(where: { $0.lowercased() == key }) { continue }
            extras.append(t)
        }
        let interest = Interest(
            query: topic,
            saveID: UUID(),
            why: "",
            extras: extras,
            savedAt: .now
        )
        var stories = await FeedNews.stories(for: topic, limit: 20, skipSeen: false, requireMention: true)
        if stories.count < 8 {
            for extra in interest.extras where extra.lowercased() != topic.lowercased() {
                stories.append(contentsOf: await FeedNews.stories(for: extra, limit: 12, skipSeen: false, requireMention: true))
            }
        }
        stories.sort {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
        var used = Set<String>()
        var unique: [NewsHeadline] = []
        for story in stories {
            let print = FeedStore.fingerprint(title: story.title, url: story.url)
            if used.contains(print) { continue }
            if unique.contains(where: { FeedStore.isSameStory(story.title, $0.title) }) { continue }
            used.insert(print)
            unique.append(story)
            if unique.count >= max(count * 2, 10) { break }
        }

        var made: [FeedPost] = []
        await withTaskGroup(of: FeedPost?.self) { group in
            for story in unique {
                group.addTask {
                    if let post = await draftedPost(story: story, interest: interest) {
                        return post
                    }
                    return await fallbackPost(story: story, interest: interest)
                }
            }
            for await post in group {
                guard let post else { continue }
                if made.contains(where: { FeedStore.isSameStory(post.headline, $0.headline) }) { continue }
                made.append(post)
                onPost?(post)
                if made.count >= count {
                    group.cancelAll()
                    break
                }
            }
        }
        made.sort { $0.publishedAt > $1.publishedAt }
        let rest = FeedStore.load().filter { existing in
            !made.contains { FeedStore.isSameStory($0.headline, existing.headline) }
        }
        FeedStore.save(made + rest)
        return made
    }

    @MainActor
    static func lookup(_ raw: String, count: Int = 12) async -> [FeedPost] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return [] }
        let topic = expand(typed)
        let interest = Interest(
            query: topic,
            saveID: UUID(),
            why: "",
            extras: typed.lowercased() == topic.lowercased() ? [] : [typed],
            savedAt: .now
        )
        var stories = await FeedNews.stories(for: topic, limit: max(count * 2, 16), skipSeen: false, requireMention: true)
        if stories.count < 6, typed.lowercased() != topic.lowercased() {
            stories.append(contentsOf: await FeedNews.stories(for: typed, limit: 12, skipSeen: false, requireMention: true))
        }
        var used = Set<String>()
        var unique: [NewsHeadline] = []
        for story in stories {
            let print = FeedStore.fingerprint(title: story.title, url: story.url)
            if used.contains(print) { continue }
            if unique.contains(where: { FeedStore.isSameStory(story.title, $0.title) }) { continue }
            used.insert(print)
            unique.append(story)
            if unique.count >= count { break }
        }
        var made: [FeedPost] = []
        for story in unique {
            let post = listPost(story: story, interest: interest)
            if made.contains(where: { FeedStore.isSameStory($0.headline, post.headline) }) { continue }
            made.append(post)
        }
        let rest = FeedStore.load().filter { existing in
            !made.contains { FeedStore.isSameStory($0.headline, existing.headline) }
        }
        FeedStore.save(made + rest)
        Task { await ensureBriefings(made) }
        return made
    }

    private static func newsQuery(from raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count <= 6, !trimmed.contains("?") { return trimmed }
        guard IntelligenceKey.isConfigured else { return trimmed }
        let reply = await AnthropicLibrary.reply(
            system: "Turn the user's words into a short news search query. 2 to 6 words. No quotes. No punctuation besides spaces. Output only the query.",
            user: trimmed,
            maxTokens: 40
        )
        guard let reply else { return trimmed }
        let first = reply
            .replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let line = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count >= 2 ? line : trimmed
    }

    @MainActor
    static func withPhotos(_ posts: [FeedPost]) async -> [FeedPost] {
        for post in posts {
            if FeedImageCache.image(for: post.id) != nil { continue }
            _ = await FeedNews.loadFastImage(for: post)
        }
        return posts
    }

    private static func draftedPost(story: NewsHeadline, interest: Interest) async -> FeedPost? {
        guard let draft = await briefing(story: story, interest: interest) else { return nil }
        let title = FeedNews.displayTitle(draft.title)
        let script = draft.script
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FeedNews.junk(title) || FeedNews.junk(script) { return nil }
        let hasBullets = script.contains("- ") || script.contains("• ") || script.contains("\n* ")
        guard hasBullets else { return nil }
        let id = UUID()
        let pic = await FeedNews.picture(for: story, interest: interest.query, id: id)
        guard !pic.file.isEmpty || !pic.remote.isEmpty else { return nil }
        return FeedPost(
            id: id,
            saveID: interest.saveID,
            title: title,
            script: script,
            headline: story.title,
            headlineURL: story.url,
            audioFileName: "",
            imageFileName: pic.file,
            imageURL: pic.remote,
            sourceName: story.source,
            interest: interest.query,
            createdAt: .now,
            publishedAt: story.publishedAt ?? .now
        )
    }

    private static func fallbackPost(story: NewsHeadline, interest: Interest) async -> FeedPost? {
        let title = FeedNews.displayTitle(story.title)
        guard !title.isEmpty, !FeedNews.junk(title) else { return nil }
        let snippet = story.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let para = snippet.count > 40 ? snippet : title
        var bullets: [String] = []
        for piece in para.split(whereSeparator: { ".!?".contains($0) }) {
            let line = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.count < 12 { continue }
            bullets.append("- \(line).")
            if bullets.count == 4 { break }
        }
        if bullets.isEmpty {
            bullets = ["- \(title).", "- Source: \(story.source.isEmpty ? "news" : story.source)."]
        }
        let script = "\(para)\n\n\(bullets.joined(separator: "\n"))"
        let id = UUID()
        let pic = await FeedNews.picture(for: story, interest: interest.query, id: id)
        return FeedPost(
            id: id,
            saveID: interest.saveID,
            title: title,
            script: script,
            headline: story.title,
            headlineURL: story.url,
            audioFileName: "",
            imageFileName: pic.file,
            imageURL: pic.remote,
            sourceName: story.source,
            interest: interest.query,
            createdAt: .now,
            publishedAt: story.publishedAt ?? .now,
            briefingReady: false
        )
    }

    private static func listPost(story: NewsHeadline, interest: Interest) -> FeedPost {
        let title = FeedNews.displayTitle(story.title)
        let snippet = story.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let para = snippet.count > 40 ? snippet : (title.isEmpty ? story.title : title)
        var bullets: [String] = []
        for piece in para.split(whereSeparator: { ".!?".contains($0) }) {
            let line = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.count < 12 { continue }
            bullets.append("- \(line).")
            if bullets.count == 4 { break }
        }
        if bullets.isEmpty {
            bullets = ["- \(title.isEmpty ? story.title : title).", "- Source: \(story.source.isEmpty ? "news" : story.source)."]
        }
        return FeedPost(
            id: UUID(),
            saveID: interest.saveID,
            title: title.isEmpty ? story.title : title,
            script: "\(para)\n\n\(bullets.joined(separator: "\n"))",
            headline: story.title,
            headlineURL: story.url,
            audioFileName: "",
            imageFileName: "",
            imageURL: story.imageURL?.absoluteString ?? "",
            sourceName: story.source,
            interest: interest.query,
            createdAt: .now,
            publishedAt: story.publishedAt ?? .now,
            briefingReady: false
        )
    }

    @MainActor
    static func needsBriefing(_ post: FeedPost) -> Bool {
        isPlaceholder(post)
    }

    static func isPlaceholder(_ post: FeedPost) -> Bool {
        if !post.briefingReady { return true }
        let script = post.script.replacingOccurrences(of: "\\n", with: "\n")
        let bullets = script.components(separatedBy: .newlines).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("• ") || t.hasPrefix("* ")
        }
        if bullets.isEmpty { return true }
        if bullets.contains(where: { $0.lowercased().contains("source:") }) { return true }
        return bullets.count < 4
    }

    @MainActor
    static func completeBriefing(_ post: FeedPost) async -> FeedPost? {
        let next = await ensureBriefing(post)
        return needsBriefing(next) ? nil : next
    }

    @MainActor
    static func ensureBriefing(_ post: FeedPost) async -> FeedPost {
        if !needsBriefing(post) { return post }
        for _ in 0..<3 {
            if let next = await refreshSummary(post), !needsBriefing(next) {
                return next
            }
        }
        return FeedStore.load().first(where: { $0.id == post.id }) ?? post
    }

    @MainActor
    static func ensureBriefings(_ posts: [FeedPost], prefer first: UUID? = nil) async {
        var pending = posts.filter { needsBriefing($0) }
        if let first, let start = posts.firstIndex(where: { $0.id == first }) {
            let ordered = Array(posts[start...]) + Array(posts[..<start])
            pending = ordered.filter { needsBriefing($0) }
        }
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            func spawn() {
                guard index < pending.count else { return }
                let post = pending[index]
                index += 1
                group.addTask { @MainActor in
                    _ = await ensureBriefing(post)
                }
            }
            for _ in 0..<min(3, pending.count) { spawn() }
            for await _ in group {
                spawn()
            }
        }
    }

    @MainActor
    static func refreshSummary(_ post: FeedPost) async -> FeedPost? {
        let interest = Interest(query: post.interest, saveID: post.saveID, why: "", extras: [], savedAt: .now)
        let story = NewsHeadline(
            title: post.headline.isEmpty ? post.title : post.headline,
            url: post.headlineURL,
            snippet: post.script,
            source: post.sourceName,
            imageURL: URL(string: post.imageURL),
            publishedAt: post.publishedAt
        )
        guard let draft = await briefing(story: story, interest: interest) else { return nil }
        let title = FeedNews.displayTitle(draft.title)
        let script = draft.script
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FeedNews.junk(title) || FeedNews.junk(script) { return nil }
        var next = post
        if !title.isEmpty { next.title = title }
        next.script = script
        next.briefingReady = true
        var all = FeedStore.load()
        if let i = all.firstIndex(where: { $0.id == post.id }) {
            all[i] = next
            FeedStore.save(all)
        }
        return next
    }

    private struct Interest: Sendable {
        var query: String
        var saveID: UUID
        var why: String
        var extras: [String]
        var savedAt: Date
    }

    private static func starterInterests() -> [Interest] {
        let queries = [
            "world news", "climate", "space", "public health",
            "premier league", "formula one", "wildlife", "ocean",
            "architecture", "archaeology", "renewable energy", "film",
            "cities", "nutrition", "cybersecurity", "art",
            "books", "transport", "science", "economy"
        ].shuffled()
        let none = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
        return queries.prefix(8).map {
            Interest(query: $0, saveID: none, why: "", extras: [], savedAt: .now)
        }
    }

    private static func interests(in saves: [SaveItem]) -> [Interest] {
        var seen = Set<String>()
        var buckets: [String: [Interest]] = [:]
        let ranked = saves.sorted { $0.savedAt > $1.savedAt }

        func lane(for save: SaveItem) -> String {
            if save.source == .spotify || save.contentType == .music { return "music" }
            return save.source.rawValue
        }

        func add(_ raw: String, save: SaveItem) {
            let t = expand(raw)
            guard usable(t) else { return }
            let key = t.lowercased()
            guard !seen.contains(key) else { return }
            let existing = buckets.values.flatMap { $0 }
            if existing.contains(where: {
                let q = $0.query.lowercased()
                return q != key && q.contains(key) && q.count > t.count
            }) {
                return
            }
            for (name, list) in buckets {
                buckets[name] = list.filter {
                    let q = $0.query.lowercased()
                    let keep = q == key || !(key.contains(q) && t.count > $0.query.count)
                    if !keep { seen.remove(q) }
                    return keep
                }
            }
            seen.insert(key)
            let why = [save.title, save.summary].filter { !$0.isEmpty }.joined(separator: " — ")
            let extras = contextWords(from: why, excluding: t)
            let item = Interest(
                query: String(t.prefix(48)),
                saveID: save.saveID,
                why: String(why.prefix(220)),
                extras: extras,
                savedAt: save.savedAt
            )
            buckets[lane(for: save), default: []].append(item)
        }

        for save in ranked {
            if save.source == .spotify || save.contentType == .music {
                if save.title.contains("—") {
                    let artist = save.title.split(separator: "—").last.map(String.init) ?? ""
                    add(artist, save: save)
                }
                add(save.creatorName, save: save)
                continue
            }
            if let topic = save.topics.first(where: { usable(expand($0)) }) {
                add(topic, save: save)
            } else if let entity = save.entities.first(where: { usable(expand($0)) }) {
                add(entity, save: save)
            } else {
                add(save.creatorName, save: save)
            }
        }

        for save in ranked where save.source != .spotify && save.contentType != .music {
            for topic in save.topics { add(topic, save: save) }
            for entity in save.entities { add(entity, save: save) }
            let handle = save.creatorHandle.replacingOccurrences(of: "@", with: "")
            if handle.count > 3 { add(handle, save: save) }
        }

        let preferred = ["note", "web", "screenshot", "github", "youtube", "tiktok", "instagram", "x", "reddit", "music"]
        let lanes = buckets.keys.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? 99
            let ib = preferred.firstIndex(of: b) ?? 99
            if ia != ib { return ia < ib }
            return a < b
        }

        var mixed: [Interest] = []
        var cursor: [String: Int] = [:]
        var musicCount = 0
        let musicCap = 3
        let totalCap = 14
        while mixed.count < totalCap {
            var added = false
            for lane in lanes {
                if mixed.count >= totalCap { break }
                let list = buckets[lane] ?? []
                let i = cursor[lane] ?? 0
                guard i < list.count else { continue }
                cursor[lane] = i + 1
                if lane == "music" && musicCount >= musicCap { continue }
                mixed.append(list[i])
                if lane == "music" { musicCount += 1 }
                added = true
            }
            if !added { break }
        }
        return mixed
    }

    private static func contextWords(from why: String, excluding: String) -> [String] {
        let skipWord = excluding.lowercased()
        var words: [String] = []
        var current = ""
        for ch in why {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var seen = Set<String>()
        var extra: [String] = []
        for word in words {
            let lower = word.lowercased()
            if lower == skipWord { continue }
            if skip.contains(lower) { continue }
            if lower.count < 4 { continue }
            if seen.contains(lower) { continue }
            seen.insert(lower)
            extra.append(word)
            if extra.count >= 3 { break }
        }
        return extra
    }

    private static func expand(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t.lowercased() {
        case "f1", "f 1":
            return "formula one"
        case "ai", "a.i", "a.i.", "a.i. ":
            return "artificial intelligence"
        case "llm", "llms":
            return "large language model"
        case "ml":
            return "machine learning"
        default:
            return t
        }
    }

    private static func usable(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 4 { return false }
        return !skip.contains(t.lowercased())
    }

    private static func briefing(story: NewsHeadline, interest: Interest) async -> (title: String, script: String)? {
        let excerpt = FeedNews.cleanCopy(story.snippet.isEmpty ? story.title : story.snippet)
        let user = """
        Interest (targeting only, never mention the library or that they saved anything): \(interest.query)
        Related context: \(interest.extras.joined(separator: ", "))
        Why they follow this (private, do not quote): \(interest.why)
        News title: \(story.title)
        Outlet: \(story.source.isEmpty ? "unknown" : story.source)
        Article excerpt: \(excerpt)
        URL: \(story.url)
        """
        let starter = interest.why.isEmpty
        let system: String
        if starter {
            system = """
            Write a short feed post for this news item.
            Return JSON only with keys match, title, script.
            match: true unless this is not a real news story.
            title: a new headline. Sentence case.
            script: First a short paragraph of 2–3 complete sentences that summarize the news (what happened and why it matters). No outlet promo, no “add as a preferred source”, no Google Discover lines. Then a blank line. Then 4 to 6 markdown bullets, each on its own line starting with "- ". Bullets are required.
            """
        } else {
            system = """
        You decide if a news item belongs in a personal feed, then write the post if it does.
        Return JSON only with keys match, title, script.

        match: true only if the news is about the SAME person, artist, product, company, place, or topic as the interest, in the SAME sense as the private save context.
        Same word, different meaning is match false. Example: interest is Lake Ontario (the body of water) → a WNBA / Toronto / sports story that merely mentions Ontario is false. Several different news items about that lake are all true — do not reject a second water-levels or shoreline story just because you already saw one about the lake.
        Homonyms, acronyms, different people with a similar name, and loosely related news are match false.
        If match is false, return {"match":false,"title":"","script":""}.
        If match is true:
        Do not say "you saved" or mention the library.
        title: a new headline for this story. Sentence case.
        script: First a short paragraph of 2–3 complete sentences that summarize the news (what happened and why it matters). No outlet promo, no “add as a preferred source”, no Google Discover lines. Then a blank line. Then 4 to 6 markdown bullets, each on its own line starting with "- ", covering what happened, why it matters, and any numbers or dates. Bullets are required.
        """
        }
        guard let raw = await AnthropicLibrary.reply(system: system, user: user, maxTokens: 700),
              let parsed = parse(raw, requireMatch: !starter),
              !recycled(parsed.script) else {
            return nil
        }
        return parsed
    }

    private static func recycled(_ script: String) -> Bool {
        let lower = script.lowercased()
        return lower.contains("you saved") || lower.contains("your library") || lower.contains("you shared")
    }

    private static func parse(_ raw: String, requireMatch: Bool = true) -> (title: String, script: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let match: Bool
        if let flag = json["match"] as? Bool {
            match = flag
        } else if let text = json["match"] as? String {
            match = text.lowercased() == "true" || text == "1"
        } else {
            match = !requireMatch
        }
        guard match || !requireMatch else { return nil }
        let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let script = (json["script"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, script.count > 40 else { return nil }
        guard script.contains("- ") || script.contains("•") else { return nil }
        return (title, script)
    }
}
