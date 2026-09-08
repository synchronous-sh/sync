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
    @MainActor private static var briefingTasks: [String: Task<FeedPost, Never>] = [:]

    @MainActor
    static func fill(
        from saves: [SaveItem],
        count: Int = 12,
        replace: Bool = false,
        resetSeen: Bool = true,
        skipHistory: Bool = true,
        onPost: ((FeedPost) -> Void)? = nil
    ) async -> [FeedPost] {
        await runFill(from: saves, count: count, replace: replace, resetSeen: resetSeen, skipHistory: skipHistory, onPost: onPost)
    }

    @MainActor
    private static func runFill(
        from saves: [SaveItem],
        count: Int,
        replace: Bool,
        resetSeen: Bool,
        skipHistory: Bool,
        onPost: ((FeedPost) -> Void)?
    ) async -> [FeedPost] {
        // #region agent log
        let t0 = CFAbsoluteTimeGetCurrent()
        AgentDebug.log("A", "FeedStudio.swift:fill", "fill_start", ["count": count, "replace": replace])
        // #endregion
        let previous = replace ? FeedStore.load() : []
        if replace {
            if resetSeen { FeedStore.clearSeen() }
            FeedStore.save([])
        }
        let existing = replace ? [] : FeedStore.load()
        var used = Set<String>()
        var usedTitles: [String] = []
        var usedPhotos = Set<String>()
        for post in existing {
            used.insert(FeedStore.fingerprint(title: post.headline.isEmpty ? post.title : post.headline, url: post.headlineURL))
            usedTitles.append(post.headline.isEmpty ? post.title : post.headline)
        }
        let fromLibrary = interests(in: saves)
        TasteEngine.ingest(saves)
        let preferred = TasteEngine.seedQueries()
        let mixed = fromLibrary.isEmpty ? starterInterests() : withAI(fromLibrary)
        let all = mixed.sorted { a, b in
            let ia = preferred.firstIndex { a.query.lowercased().contains($0.lowercased()) } ?? 80
            let ib = preferred.firstIndex { b.query.lowercased().contains($0.lowercased()) } ?? 80
            return ia < ib
        }
        let take = min(2, all.count)
        let start = existing.count % max(all.count, 1)
        let pool = all.isEmpty ? [] : (0..<take).map { all[(start + $0) % all.count] }
        // #region agent log
        AgentDebug.log("C", "FeedStudio.swift:fill", "pool", ["queries": pool.map(\.query).joined(separator: "|")])
        // #endregion

        var headlines: [[NewsHeadline]] = Array(repeating: [], count: pool.count)
        let want = max(count, 6)
        var cursor = Array(repeating: 0, count: pool.count)
        var made: [FeedPost] = []

        func emitAvailable() {
            var progress = true
            while made.count < want, progress {
                progress = false
                for i in pool.indices {
                    if made.count >= want { break }
                    let interest = pool[i]
                    while cursor[i] < headlines[i].count {
                        let raw = headlines[i][cursor[i]]
                        cursor[i] += 1
                        let print = FeedStore.fingerprint(title: raw.title, url: raw.url)
                        if used.contains(print) { continue }
                        if skipHistory, !replace, FeedStore.hasSeen(title: raw.title, url: raw.url) { continue }
                        if usedTitles.contains(where: { FeedStore.isSameStory(raw.title, $0) }) { continue }
                        let hadPhoto = raw.imageURL != nil
                        var story = raw
                        if let photo = story.imageURL {
                            let key = "\((photo.host ?? "").lowercased())\(photo.path.lowercased())"
                            if usedPhotos.contains(key) {
                                story.imageURL = nil
                            } else {
                                usedPhotos.insert(key)
                            }
                        }
                        if !hadPhoto {
                            let rest = headlines[i].suffix(from: cursor[i])
                            if rest.contains(where: { $0.imageURL != nil }) { continue }
                        }
                        let post = listPost(story: story, interest: interest)
                        if made.contains(where: { FeedStore.isSameStory(post.headline, $0.headline) }) { continue }
                        used.insert(print)
                        usedTitles.append(story.title)
                        made.append(post)
                        // #region agent log
                        AgentDebug.log("C", "FeedStudio.swift:emit", "card", [
                            "interest": interest.query,
                            "imgHost": story.imageURL?.host ?? "none",
                            "imgPath": String((story.imageURL?.path ?? "").suffix(40)),
                            "title": String(story.title.prefix(48))
                        ])
                        // #endregion
                        FeedStorySet.remember(post)
                        onPost?(post)
                        progress = true
                        break
                    }
                }
            }
        }

        await withTaskGroup(of: (Int, [NewsHeadline]).self) { group in
            for (i, interest) in pool.enumerated() {
                group.addTask {
                    var stories = await FeedNews.stories(for: interest.query, limit: 10, skipSeen: false)
                    if stories.count < 4, let extra = interest.extras.first {
                        stories.append(contentsOf: await FeedNews.stories(for: extra, limit: 8))
                    }
                    stories.sort { ($0.imageURL != nil ? 0 : 1) < ($1.imageURL != nil ? 0 : 1) }
                    return (i, stories)
                }
            }
            for await (i, stories) in group {
                headlines[i] = TasteEngine.rankNews(stories, category: pool[i].query, limit: stories.count)
                headlines[i].sort { ($0.imageURL != nil ? 0 : 1) < ($1.imageURL != nil ? 0 : 1) }
                emitAvailable()
                if made.count >= want {
                    group.cancelAll()
                    break
                }
            }
        }

        if made.isEmpty {
            let backup = await FeedNews.stories(for: "top stories", limit: 20, skipSeen: false)
            let interest = pool.first ?? Interest(
                query: "world news",
                saveID: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
                why: "",
                extras: [],
                savedAt: .now
            )
            for story in backup.prefix(12) {
                if made.count >= want { break }
                let print = FeedStore.fingerprint(title: story.title, url: story.url)
                if used.contains(print) { continue }
                let post = listPost(story: story, interest: interest)
                if made.contains(where: { FeedStore.isSameStory(post.headline, $0.headline) }) { continue }
                used.insert(print)
                made.append(post)
                FeedStorySet.remember(post)
                onPost?(post)
            }
        }
        if !made.isEmpty {
            if replace {
                FeedStore.save(made)
            } else {
                FeedStore.append(made)
            }
            Task { await ensureBriefings(made) }
        }

        if replace, made.isEmpty, !previous.isEmpty {
            FeedStore.save(previous)
            // #region agent log
            AgentDebug.log("A", "FeedStudio.swift:fill", "fill_end_prev", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)])
            // #endregion
            return previous
        }
        let out = made.isEmpty ? FeedStore.load() : made
        // #region agent log
        AgentDebug.log("A", "FeedStudio.swift:fill", "fill_end", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000), "made": made.count])
        // #endregion
        return out
    }

    @MainActor
    static func search(_ raw: String, count: Int = 8, onPost: ((FeedPost) -> Void)? = nil) async -> [FeedPost] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return [] }
        let interest = Interest(
            query: typed,
            saveID: UUID(),
            why: "",
            extras: [],
            savedAt: .now
        )
        let stories = await naturalHeadlines(typed, limit: max(count, 8))
        var made: [FeedPost] = []
        for story in stories {
            let post = listPost(story: story, interest: interest)
            if made.contains(where: { FeedStore.isSameStory($0.headline, story.title) }) { continue }
            made.append(post)
            onPost?(post)
            if made.count >= count { break }
        }
        let rest = FeedStore.load().filter { existing in
            !made.contains { FeedStore.isSameStory($0.headline, existing.headline) }
        }
        FeedStore.save(made + rest)
        Task { await ensureBriefings(made) }
        return made
    }

    @MainActor
    static func lookup(_ raw: String, count: Int = 12) async -> [FeedPost] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return [] }
        let interest = Interest(
            query: typed,
            saveID: UUID(),
            why: "",
            extras: [],
            savedAt: .now
        )
        let stories = await naturalHeadlines(typed, limit: count)
        var made: [FeedPost] = []
        for story in stories {
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

    @MainActor
    static func headlineSearch(_ raw: String, limit: Int = 12) async -> [NewsHeadline] {
        await naturalHeadlines(raw, limit: limit)
    }

    @MainActor
    static func naturalHeadlines(_ raw: String, limit: Int) async -> [NewsHeadline] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return [] }
        let plan = await SearchSense.plan(typed)
        var bag: [NewsHeadline] = []
        await withTaskGroup(of: [NewsHeadline].self) { group in
            var seenQ = Set<String>()
            for q in ([typed] + plan.queries) {
                let key = q.lowercased()
                if key.count < 2 || !seenQ.insert(key).inserted { continue }
                group.addTask {
                    await FeedNews.stories(for: q, limit: 10, skipSeen: false, requireMention: false, freshOnly: false)
                }
            }
            for await batch in group {
                bag.append(contentsOf: batch)
            }
        }
        var seen = Set<String>()
        var unique: [NewsHeadline] = []
        for item in bag {
            let key = FeedStore.fingerprint(title: item.title, url: item.url)
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(item)
        }
        let matched = await SearchSense.match(unique, intent: plan.intent, ask: typed, limit: limit)
        return matched.isEmpty ? Array(unique.prefix(limit)) : matched
    }

    @MainActor
    static func posts(forCategory category: String, count: Int = 10, onPost: ((FeedPost) -> Void)? = nil) async -> [FeedPost] {
        let topic = category == "For You" ? "Top" : category
        let t0 = CFAbsoluteTimeGetCurrent()
        let cached = NewsFeedCache.stored(topic)
        var stories = TasteEngine.rankNews(cached, category: topic, limit: max(count, 8))
        // #region agent log
        AgentDebug.log("B", "FeedStudio.posts(forCategory)", "cache", [
            "cat": category,
            "cached": cached.count,
            "ranked": stories.count
        ])
        // #endregion
        if stories.count < min(count, 6) {
            stories = TasteEngine.rankNews(
                await FeedNews.browse(category: topic, limit: max(count, 8), skipAPI: true),
                category: topic,
                limit: max(count, 8)
            )
        }
        let interest = Interest(
            query: category,
            saveID: UUID(),
            why: "",
            extras: [],
            savedAt: .now
        )
        var made: [FeedPost] = []
        for story in stories {
            if made.contains(where: { FeedStore.isSameStory($0.headline, story.title) }) { continue }
            let post = listPost(story: story, interest: interest)
            made.append(post)
            onPost?(post)
            if made.count >= count { break }
        }
        // #region agent log
        AgentDebug.log("B", "FeedStudio.posts(forCategory)", "done", [
            "cat": category,
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "n": made.count
        ])
        // #endregion
        if !made.isEmpty {
            let snapshot = made
            Task { @MainActor in
                let rest = FeedStore.load().filter { existing in
                    !snapshot.contains { FeedStore.isSameStory($0.headline, existing.headline) }
                }
                FeedStore.save(snapshot + rest)
                await ensureBriefings(snapshot)
            }
        }
        return made
    }

    private static let searchGlue: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about",
        "news", "latest", "acquire", "acquires", "acquired", "acquisition", "buy", "buys",
        "bought", "purchase", "purchases", "merger", "deal", "rumor", "rumors", "vs", "versus"
    ]

    private static func searchQueries(from raw: String) async -> [String] {
        heuristicQueries(raw)
    }

    private static func heuristicQueries(_ raw: String) -> [String] {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var queries: [String] = []
        func add(_ value: String) {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { return }
            let key = t.lowercased()
            if queries.contains(where: { $0.lowercased() == key }) { return }
            queries.append(t)
        }
        add(typed)
        add(expand(typed))
        let names = typed.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { word in
                let lower = word.lowercased()
                return word.count >= 3 && !searchGlue.contains(lower)
            }
        if names.count >= 2 {
            add(names.joined(separator: " "))
        } else {
            for name in names { add(name) }
        }
        return Array(queries.prefix(3))
    }

    private static func collectStories(queries: [String], limit: Int) async -> [NewsHeadline] {
        var stories: [NewsHeadline] = []
        await withTaskGroup(of: [NewsHeadline].self) { group in
            for query in queries {
                group.addTask {
                    await FeedNews.stories(for: query, limit: 16, skipSeen: false, requireMention: false, freshOnly: false)
                }
            }
            for await batch in group {
                stories.append(contentsOf: batch)
            }
        }
        if stories.count > limit * 3 {
            stories = Array(stories.prefix(limit * 3))
        }
        return stories
    }

    private static func rankStories(_ stories: [NewsHeadline], typed: String, queries: [String]) -> [NewsHeadline] {
        let needles = searchNeedles(typed: typed, queries: queries)
        var used = Set<String>()
        var unique: [NewsHeadline] = []
        for story in stories {
            let print = FeedStore.fingerprint(title: story.title, url: story.url)
            if used.contains(print) { continue }
            if unique.contains(where: { FeedStore.isSameStory(story.title, $0.title) }) { continue }
            used.insert(print)
            unique.append(story)
        }
        unique.sort { left, right in
            let leftHits = hitCount(left, needles: needles)
            let rightHits = hitCount(right, needles: needles)
            if leftHits != rightHits { return leftHits > rightHits }
            return (left.publishedAt ?? .distantPast) > (right.publishedAt ?? .distantPast)
        }
        if !needles.isEmpty {
            let relevant = unique.filter { hitCount($0, needles: needles) > 0 }
            if !relevant.isEmpty { unique = relevant }
        }
        return unique
    }

    private static func searchNeedles(typed: String, queries: [String]) -> [String] {
        var needles: [String] = []
        for source in [typed] + queries {
            for word in source.split(whereSeparator: \.isWhitespace) {
                let token = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
                guard token.count >= 3, !searchGlue.contains(token) else { continue }
                if needles.contains(token) { continue }
                needles.append(token)
            }
        }
        return needles
    }

    private static func hitCount(_ story: NewsHeadline, needles: [String]) -> Int {
        let hay = (story.title + " " + story.snippet).lowercased()
        return needles.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
    }

    private static func newsQuery(from raw: String) async -> String {
        (await searchQueries(from: raw)).first ?? raw
    }

    @MainActor
    static func withPhotos(_ posts: [FeedPost]) async -> [FeedPost] {
        FeedImageCache.prefetch(posts)
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
        let post = FeedPost(
            id: id,
            saveID: interest.saveID,
            title: title,
            script: script,
            headline: story.title,
            headlineURL: story.url,
            audioFileName: "",
            imageFileName: "",
            imageURL: "",
            sourceName: story.source,
            interest: interest.query,
            createdAt: .now,
            publishedAt: story.publishedAt ?? .now,
            briefingReady: true
        )
        Task(priority: .userInitiated) { _ = await FeedNews.loadFastImage(for: post) }
        return post
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
        let post = FeedPost(
            id: id,
            saveID: interest.saveID,
            title: title,
            script: script,
            headline: story.title,
            headlineURL: story.url,
            audioFileName: "",
            imageFileName: "",
            imageURL: "",
            sourceName: story.source,
            interest: interest.query,
            createdAt: .now,
            publishedAt: story.publishedAt ?? .now,
            briefingReady: false
        )
        Task(priority: .userInitiated) { _ = await FeedNews.loadFastImage(for: post) }
        return post
    }

    @MainActor
    static func post(from story: NewsHeadline, topic: String) -> FeedPost {
        let photoKey = FeedNews.photoID(for: story)
        func adoptCache(into id: UUID) {
            if let image = FeedImageCache.image(for: photoKey) ?? FeedImageCache.image(for: id) {
                FeedImageCache.store(image, for: id)
                FeedImageCache.store(image, for: photoKey)
            }
        }
        if let existing = FeedStore.load().first(where: { stored in
            (!story.url.isEmpty && stored.headlineURL == story.url)
                || FeedStore.isSameStory(stored.headline, story.title)
        }) {
            adoptCache(into: existing.id)
            return existing
        }
        let post = listPost(
            story: story,
            interest: Interest(query: topic, saveID: UUID(), why: "", extras: [], savedAt: .now),
            id: photoKey
        )
        adoptCache(into: post.id)
        var all = FeedStore.load()
        all.insert(post, at: 0)
        FeedStore.save(all)
        return post
    }

    @MainActor
    static func prepared(from story: NewsHeadline, topic: String) async -> FeedPost {
        await ensureBriefing(post(from: story, topic: topic))
    }

    @MainActor
    static func finished(_ posts: [FeedPost]) -> [FeedPost] {
        var store: [UUID: FeedPost] = [:]
        for post in FeedStore.load() { store[post.id] = post }
        return posts.map { store[$0.id] ?? $0 }
    }

    @MainActor
    static func showable(_ posts: [FeedPost]) -> [FeedPost] {
        let latest = finished(posts)
        let ready = latest.filter { !needsBriefing($0) }
        return ready.isEmpty ? latest : ready
    }

    private static func listPost(story: NewsHeadline, interest: Interest, id: UUID = UUID()) -> FeedPost {
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
            id: id,
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

    private static func briefingKey(_ post: FeedPost) -> String {
        let url = FeedStore.canonical(post.headlineURL)
        if !url.isEmpty { return "u:" + url }
        return "i:" + post.id.uuidString
    }

    @MainActor
    static func needsBriefing(_ post: FeedPost) -> Bool {
        isPlaceholder(post)
    }

    static func isPlaceholder(_ post: FeedPost) -> Bool {
        let script = post.script.replacingOccurrences(of: "\\n", with: "\n")
        let bullets = script.components(separatedBy: .newlines).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("• ") || t.hasPrefix("* ")
        }
        if bullets.contains(where: { $0.lowercased().contains("source:") }) { return true }
        if echoesHeadline(post) { return true }
        if !post.briefingReady { return true }
        return script.count < 280
    }

    static func echoesHeadline(_ post: FeedPost) -> Bool {
        let titles = [post.title, post.headline]
            .map { FeedNews.displayTitle($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 8 }
        let lines = post.script
            .replacingOccurrences(of: "\\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line -> String in
                var t = line
                while t.hasPrefix("- ") || t.hasPrefix("• ") || t.hasPrefix("* ") {
                    t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                if t.hasSuffix(".") { t = String(t.dropLast()) }
                return t
            }
            .filter { $0.count >= 8 }
        guard !lines.isEmpty, !titles.isEmpty else { return true }
        return lines.allSatisfy { line in
            titles.contains { FeedStore.isSameStory(line, $0) }
        }
    }

    @MainActor
    static func completeBriefing(_ post: FeedPost) async -> FeedPost? {
        let next = await ensureBriefing(post)
        return needsBriefing(next) ? nil : next
    }

    @MainActor
    static func ensureBriefing(_ post: FeedPost) async -> FeedPost {
        if let stored = FeedStore.load().first(where: {
            $0.id == post.id || (!post.headlineURL.isEmpty && $0.headlineURL == post.headlineURL)
        }), !needsBriefing(stored) {
            return stored
        }
        if !needsBriefing(post) { return post }
        let key = briefingKey(post)
        if let existing = briefingTasks[key] {
            return await existing.value
        }
        // #region agent log
        AgentDebug.log("B", "FeedStudio.ensureBriefing", "enter", [
            "ready": post.briefingReady,
            "scriptLen": post.script.count,
            "echo": echoesHeadline(post)
        ])
        // #endregion
        let task = Task { @MainActor in
            for _ in 0..<2 {
                if let next = await refreshSummary(post), !needsBriefing(next) {
                    return next
                }
            }
            return FeedStore.load().first(where: {
                $0.id == post.id || (!post.headlineURL.isEmpty && $0.headlineURL == post.headlineURL)
            }) ?? post
        }
        briefingTasks[key] = task
        let next = await task.value
        briefingTasks[key] = nil
        // #region agent log
        AgentDebug.log("B", "FeedStudio.ensureBriefing", "exit", [
            "ready": next.briefingReady,
            "scriptLen": next.script.count,
            "placeholder": needsBriefing(next)
        ])
        // #endregion
        return next
    }

    @MainActor
    static func ensureBriefings(_ posts: [FeedPost], prefer first: UUID? = nil, onReady: ((FeedPost) -> Void)? = nil) async {
        var pending = posts.filter { needsBriefing($0) }
        if let first, let start = pending.firstIndex(where: { $0.id == first }) {
            let head = pending.remove(at: start)
            onReady?(await ensureBriefing(head))
        }
        await withTaskGroup(of: FeedPost.self) { group in
            var index = 0
            func spawn() {
                guard index < pending.count else { return }
                let post = pending[index]
                index += 1
                group.addTask { @MainActor in
                    await ensureBriefing(post)
                }
            }
            for _ in 0..<min(5, pending.count) { spawn() }
            for await next in group {
                onReady?(next)
                spawn()
            }
        }
    }

    @MainActor
    static func refreshSummary(_ post: FeedPost) async -> FeedPost? {
        let interest = Interest(query: post.interest, saveID: post.saveID, why: "", extras: [], savedAt: .now)
        let fallback = [post.headline, post.title].first { $0.count > 8 } ?? post.title
        let excerpt = await FeedNews.articleExcerpt(url: post.headlineURL, fallback: fallback)
        let story = NewsHeadline(
            title: post.headline.isEmpty ? post.title : post.headline,
            url: post.headlineURL,
            snippet: excerpt,
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
        next.briefingReady = !echoesHeadline(next) && script.count >= 280
        // #region agent log
        AgentDebug.log("E", "FeedStudio.refreshSummary", "draft", [
            "scriptLen": script.count,
            "ready": next.briefingReady,
            "echo": echoesHeadline(next)
        ])
        // #endregion
        var all = FeedStore.load()
        if let i = all.firstIndex(where: { $0.id == post.id }) {
            all[i] = next
            FeedStore.save(all)
        } else if let i = all.firstIndex(where: {
            (!next.headlineURL.isEmpty && $0.headlineURL == next.headlineURL)
                || FeedStore.isSameStory($0.headline, next.headline)
        }) {
            all[i].script = next.script
            all[i].title = next.title
            all[i].briefingReady = next.briefingReady
            FeedStore.save(all)
        } else {
            all.insert(next, at: 0)
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
            "artificial intelligence", "world news", "climate", "space", "public health",
            "premier league", "formula one", "wildlife", "ocean",
            "architecture", "archaeology", "renewable energy", "film",
            "cities", "nutrition", "cybersecurity", "art",
            "books", "transport", "science", "economy"
        ]
        let none = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
        let ai = Interest(query: "artificial intelligence", saveID: none, why: "", extras: [], savedAt: .now)
        let rest = queries.filter { $0 != "artificial intelligence" }.shuffled().prefix(7).map {
            Interest(query: $0, saveID: none, why: "", extras: [], savedAt: .now)
        }
        return [ai] + rest
    }

    private static func withAI(_ interests: [Interest]) -> [Interest] {
        if interests.contains(where: { $0.query.lowercased().contains("artificial intelligence") || $0.query.lowercased() == "ai" }) {
            return interests
        }
        let none = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
        return [Interest(query: "artificial intelligence", saveID: none, why: "", extras: [], savedAt: .now)] + interests
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
        let system = """
            Write a news briefing for this story.
            Return JSON only with keys match, title, script.
            match: true unless this is not a real news story.
            title: a new headline. Sentence case.
            script: One paragraph of 4–5 complete sentences (what happened, who, why it matters). Then a blank line. Then 6 markdown bullets, each on its own line starting with "- ". No outlet promo, no “add as a preferred source”, no Google Discover lines.
            """
        guard let raw = await AnthropicLibrary.reply(system: system, user: user, maxTokens: 1100),
              let parsed = parse(raw, requireMatch: false),
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
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
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
        let script = (json["script"] as? String ?? "")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, script.count > 80 else { return nil }
        return (title, script)
    }
}

enum SearchSense {
    struct Plan {
        var intent: String
        var queries: [String]
    }

    static func plan(_ ask: String) async -> Plan {
        let fallback = Plan(intent: ask, queries: [ask])
        guard IntelligenceKey.isConfigured else { return fallback }
        let user = """
        Request: \(ask)
        Return JSON only: {"intent":"one sentence restating what news they want","queries":["q1","q2"]}
        queries: 2 to 4 short Google News searches. Prefer people, companies, products, and concrete topics. No quotes.
        """
        guard let raw = await AnthropicLibrary.reply(
            system: "You turn a natural-language news request into search queries. JSON only.",
            user: user,
            maxTokens: 280
        ), let json = object(raw) else { return fallback }
        let intent = (json["intent"] as? String ?? ask).trimmingCharacters(in: .whitespacesAndNewlines)
        let queries = (json["queries"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        if queries.isEmpty { return fallback }
        return Plan(intent: intent.isEmpty ? ask : intent, queries: Array(queries.prefix(4)))
    }

    static func match(_ items: [NewsHeadline], intent: String, ask: String, limit: Int) async -> [NewsHeadline] {
        guard !items.isEmpty else { return [] }
        guard IntelligenceKey.isConfigured else { return Array(items.prefix(limit)) }
        let catalog = items.prefix(24).enumerated().map { index, story in
            "[\(index)] \(story.title) — \(String(story.snippet.prefix(140)))"
        }.joined(separator: "\n")
        let user = """
        Ask: \(ask)
        Intent: \(intent)
        Stories:
        \(catalog)

        Return JSON only: {"order":[0,3,1]}
        order: 0-based indices of stories that actually match the ask, best first. Drop off-topic items. At most \(limit).
        """
        guard let raw = await AnthropicLibrary.reply(
            system: "You judge whether news headlines match a reader's request. JSON only.",
            user: user,
            maxTokens: 220
        ), let json = object(raw) else { return Array(items.prefix(limit)) }
        var order: [Int] = []
        if let ints = json["order"] as? [Int] {
            order = ints
        } else if let nums = json["order"] as? [NSNumber] {
            order = nums.map(\.intValue)
        }
        var picked: [NewsHeadline] = []
        var used = Set<Int>()
        for index in order where items.indices.contains(index) && used.insert(index).inserted {
            picked.append(items[index])
            if picked.count >= limit { break }
        }
        return picked
    }

    private static func object(_ raw: String) -> [String: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
