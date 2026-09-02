import Foundation

enum FeedStorySet {
    struct Event: Codable, Sendable {
        var label: String
        var title: String
        var summary: String
        var url: String

        init(label: String, title: String, summary: String, url: String) {
            self.label = label
            self.title = title
            self.summary = summary
            self.url = url
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        }
    }

    struct Item: Sendable {
        var title: String
        var summary: String
        var url: String
    }

    static func remember(_ post: FeedPost) {
        remember(
            title: post.headline.isEmpty ? post.title : post.headline,
            summary: post.script,
            url: post.headlineURL,
            label: post.interest
        )
    }

    static func remember(title: String, summary: String = "", url: String, label: String = "") {
        FeedStore.rememberHeadline(title: title, url: url)
        var all = load()
        if covers(title: title, summary: summary, in: all) { return }
        let key = label.isEmpty ? title : label
        all.append(Event(
            label: String(key.prefix(80)),
            title: String(title.prefix(160)),
            summary: clip(summary),
            url: url
        ))
        if all.count > 80 { all = Array(all.suffix(80)) }
        save(all)
    }

    static func collapse(_ items: [Item]) async -> Set<Int> {
        var drop = Set<Int>()
        let seen = load().suffix(30)
        for (i, item) in items.enumerated() {
            if covers(title: item.title, summary: item.summary, in: Array(seen)) {
                drop.insert(i)
                continue
            }
            for (j, earlier) in items.enumerated() where j < i {
                if drop.contains(j) { continue }
                if FeedStore.isSameStory(item.title, earlier.title) {
                    drop.insert(i)
                    break
                }
            }
        }
        let leftover = items.enumerated().filter { !drop.contains($0.offset) }
        guard leftover.count >= 1, IntelligenceKey.isConfigured else { return drop }
        let judged = await llmDrop(
            seen: Array(seen),
            fresh: leftover.map { (i: $0.offset, item: $0.element) }
        )
        drop.formUnion(judged)
        return drop
    }

    private static func covers(title: String, summary: String, in events: [Event]) -> Bool {
        events.contains { event in
            if FeedStore.isSameStory(title, event.title) { return true }
            if FeedStore.isSameStory(title, event.label) { return true }
            let a = clip(summary)
            let b = event.summary
            if a.count >= 80, b.count >= 80, FeedStore.isSameStory(a, b) { return true }
            return false
        }
    }

    private static func llmDrop(seen: [Event], fresh: [(i: Int, item: Item)]) async -> Set<Int> {
        guard !fresh.isEmpty else { return [] }
        let seenBlock = seen.enumerated().map { i, event in
            "\(i + 1). \(event.title)\n   \(clip(event.summary.isEmpty ? event.label : event.summary))"
        }.joined(separator: "\n")
        let newBlock = fresh.map { row in
            "\(row.i): \(row.item.title)\n   \(clip(row.item.summary))"
        }.joined(separator: "\n")
        let system = """
        Cluster news. Same real-world event = duplicate even if headlines differ.
        Use the summaries, not just titles. Two briefs about the same flood, game, or release are duplicates.
        Return JSON only: {"drop":[indexes],"keep":[{"i":index,"event":"short event name"}]}
        Indexes are the numbers before the colon in NEW.
        drop if NEW matches SEEN or another NEW with a lower index.
        """
        let user = """
        SEEN:
        \(seenBlock.isEmpty ? "(none)" : seenBlock)

        NEW:
        \(newBlock)
        """
        guard let raw = await AnthropicLibrary.reply(system: system, user: user, maxTokens: 280) else {
            return []
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var drop = Set<Int>()
        if let list = json["drop"] as? [Int] {
            drop.formUnion(list)
        } else if let list = json["drop"] as? [String] {
            drop.formUnion(list.compactMap(Int.init))
        }
        if let keep = json["keep"] as? [[String: Any]] {
            for item in keep {
                let index = item["i"] as? Int ?? (item["i"] as? String).flatMap(Int.init)
                let event = (item["event"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index, let row = fresh.first(where: { $0.i == index }) else { continue }
                if drop.contains(index) { continue }
                remember(title: row.item.title, summary: row.item.summary, url: row.item.url, label: event)
            }
        }
        return drop
    }

    private static func clip(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(280))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clear() {
        save([])
    }

    private static var fileURL: URL? {
        guard let root = AppGroup.container else { return nil }
        let dir = root.appendingPathComponent("feed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.json")
    }

    private static func load() -> [Event] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Event].self, from: data)) ?? []
    }

    private static func save(_ events: [Event]) {
        guard let url = fileURL else { return }
        try? JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}
