import Foundation
import SwiftData

enum DemoLibraryPurge {
    private static let urls: Set<String> = [
        "https://youtube.com/watch?v=browser-use",
        "https://www.tiktok.com/@example/video/123",
        "https://x.com/example/status/1",
        "https://reddit.com/r/MachineLearning/comments/playwright",
        "https://github.com/browser-use/browser-use",
        "https://example.com/computer-use-benchmark",
        "https://instagram.com/p/joespizza",
        "https://example.com/landing-pages"
    ]

    private static let titles: Set<String> = [
        "How browser-use works",
        "Building browser agents",
        "Browserbase demo",
        "Playwright tutorial thread",
        "browser-use",
        "Computer-use benchmark",
        "Joe's Pizza",
        "5 best tools for building AI agents",
        "Landing pages that actually convert"
    ]

    private static let collectionNames: Set<String> = [
        "AI agents",
        "Startup ideas",
        "Coding",
        "Places to eat",
        "Design inspiration"
    ]

    private static var ran = false

    static func run(in context: ModelContext) {
        guard !ran else { return }
        ran = true
        let saves = (try? context.fetch(FetchDescriptor<SaveItem>())) ?? []
        var removed = false
        for save in saves where isDemo(save) {
            context.delete(save)
            removed = true
        }
        if removed { try? context.save() }
        let collections = (try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []
        var droppedBags = false
        for bag in collections {
            let name = bag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if collectionNames.contains(name), bag.saves.isEmpty {
                context.delete(bag)
                droppedBags = true
            }
        }
        guard removed || droppedBags else { return }
        try? context.save()
        FeedStore.clear()
        FeedStore.clearSeen()
        FeedStorySet.clear()
    }

    private static func isDemo(_ save: SaveItem) -> Bool {
        if urls.contains(save.sourceURL) { return true }
        return titles.contains(save.title)
    }
}

enum LibrarySearch {
    static func results(query: String, in saves: [SaveItem]) -> [SaveItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return saves.sorted { $0.savedAt > $1.savedAt } }

        let terms = q.split(separator: " ").map(String.init)
        return saves
            .map { save -> (SaveItem, Int) in
                let blob = save.searchableBlob
                var keyword = 0
                if blob.contains(q) { keyword += 40 }
                for term in terms where blob.contains(term) { keyword += 12 }

                var entity = 0
                for term in terms where save.entities.contains(where: { $0.lowercased().contains(term) }) {
                    entity += 16
                }

                let days = Calendar.current.dateComponents([.day], from: save.savedAt, to: .now).day ?? 0
                let recency = max(0, 10 - days / 7)
                let semantic = q.count >= 3 ? Int(SemanticIndex.similarity(query: q, save: save) * 55) : 0

                let score = keyword + entity + recency + semantic
                return (save, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func related(to save: SaveItem, in saves: [SaveItem]) -> [SaveItem] {
        let others = saves.filter { $0.saveID != save.saveID }
        let mineTopics = meaningfulTopics(save.topics)
        let mineEntities = meaningfulEntities(save.entities)
        let mineTokens = contentTokens(save)
        let mineHandle = save.creatorHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let ranked = others.compactMap { other -> (SaveItem, Int)? in
            var score = 0

            let sharedEntities = mineEntities.intersection(meaningfulEntities(other.entities))
            score += sharedEntities.count * 32

            let sharedTopics = mineTopics.intersection(meaningfulTopics(other.topics))
            score += sharedTopics.count * 20

            let sameCreator = !mineHandle.isEmpty
                && other.creatorHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == mineHandle
            if sameCreator { score += 40 }

            let tokenHits = mineTokens.intersection(contentTokens(other))
            if tokenHits.count >= 3 {
                score += min(20, tokenHits.count * 3)
            }

            let strong = sameCreator || !sharedEntities.isEmpty || sharedTopics.count >= 2
            guard strong, score >= 32 else { return nil }
            return (other, score)
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0.savedAt > $1.0.savedAt }
            return $0.1 > $1.1
        }
        .map(\.0)
        return Array(ranked.prefix(6))
    }

    private static let genericTopics: Set<String> = [
        "tiktok", "instagram", "youtube", "video", "videos", "social", "viral",
        "content", "post", "reel", "reels", "shorts", "web", "link", "fyp",
        "funny", "entertainment", "media", "clip", "story", "stories",
        "social media", "self-promotion", "creator", "creators", "spotify", "music"
    ]

    private static let genericEntities: Set<String> = [
        "tiktok", "instagram", "youtube", "facebook", "twitter", "x", "reddit",
        "google", "safari", "iphone", "ios", "android", "spotify"
    ]

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "your", "you",
        "are", "was", "how", "what", "when", "why", "who", "about", "into",
        "just", "like", "have", "has", "not", "but", "they", "them", "their",
        "its", "it's", "can", "will", "one", "all", "out", "get", "got",
        "saved", "save", "watch", "video", "tiktok", "instagram", "youtube",
        "creator", "featuring", "presents", "audience"
    ]

    private static func meaningfulTopics(_ topics: [String]) -> Set<String> {
        Set(topics.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 && !genericTopics.contains($0) })
    }

    private static func meaningfulEntities(_ entities: [String]) -> Set<String> {
        Set(entities.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 && !genericEntities.contains($0) })
    }

    private static func contentTokens(_ save: SaveItem) -> Set<String> {
        let text = [save.title, save.summary].joined(separator: " ").lowercased()
        return Set(
            text.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 3 && !stopwords.contains($0) }
        )
    }

    static func ask(query: String, in saves: [SaveItem]) -> (answer: String, citations: [SaveItem]) {
        let hits = results(query: query, in: saves)
        guard !hits.isEmpty else {
            return ("Nothing in your library matches that yet. Save a few things and ask again.", [])
        }

        let q = query.lowercased()
        if q.contains("restaurant") || q.contains("eat") || q.contains("nyc") {
            let food = saves.filter { $0.topics.contains(where: { $0.contains("restaurant") || $0 == "nyc" }) || $0.contentType == .place }
            let names = food.map(\.title).prefix(8).joined(separator: "\n")
            return ("Places you've saved:\n\(names)", Array(food.prefix(8)))
        }

        let topicCounts = Dictionary(grouping: hits.flatMap(\.topics), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        let entityCounts = Dictionary(grouping: hits.flatMap(\.entities), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }

        var lines = ["From \(hits.count) save\(hits.count == 1 ? "" : "s"):"]
        for (topic, count) in topicCounts.prefix(3) {
            lines.append("\(topic) — \(count)")
        }
        if let top = entityCounts.first {
            lines.append("Most mentioned: \(top.0)")
        }
        return (lines.joined(separator: "\n"), Array(hits.prefix(8)))
    }

    static func entities(in saves: [SaveItem]) -> [(name: String, count: Int)] {
        Dictionary(grouping: saves.flatMap(\.entities), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }
}
