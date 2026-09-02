import Foundation
import SwiftData
import UIKit
import Vision

enum Enrichment {
    static let knownEntities = [
        "Playwright", "Browserbase", "Claude", "Cursor", "Supabase", "Chrome",
        "OpenAI", "GPT", "Swift", "React", "Next.js", "TikTok", "YouTube",
        "Instagram", "Figma", "Linear", "Notion", "browser-use", "Spotify"
    ]

    static let collections: [(name: String, keywords: [String])] = [
        ("AI agents", ["agent", "agents", "llm", "browserbase", "playwright", "computer-use", "claude", "cursor", "browser-use"]),
        ("Coding", ["code", "coding", "github", "swift", "python", "api", "developer", "framework"]),
        ("Startup ideas", ["startup", "saas", "founder", "idea", "distribution", "consumer"]),
        ("Design inspiration", ["design", "landing", "layout", "figma", "type", "ui"]),
        ("Places to eat", ["restaurant", "pizza", "food", "nyc", "dinner", "cafe", "bar"]),
        ("Travel", ["travel", "flight", "hotel", "city", "trip"]),
        ("Fitness", ["gym", "workout", "run", "fitness"]),
        ("Recipes", ["recipe", "cook", "ingredient", "oven"]),
        ("Fashion", ["fashion", "outfit", "wear", "style"]),
        ("Music", ["spotify.com"]),
    ]

    static func classify(title: String, summary: String, rawText: String, url: String) -> (topics: [String], entities: [String], collections: [String]) {
        let blob = [title, summary, rawText, url].joined(separator: " ").lowercased()
        var topics: [String] = []
        var collectionNames: [String] = []
        for item in collections {
            if item.keywords.contains(where: { blob.contains($0) }) {
                topics.append(item.name.lowercased())
                collectionNames.append(item.name)
            }
        }
        var entities: [String] = []
        for name in knownEntities where blob.contains(name.lowercased()) {
            entities.append(name)
        }
        return (Array(Set(topics)).sorted(), Array(Set(entities)).sorted(), collectionNames)
    }

    static func ocr(_ data: Data) -> String {
        guard let image = UIImage(data: data)?.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n") ?? ""
    }

    static func assignCollections(to save: SaveItem, names: [String], context: ModelContext) {
        CollectionHousekeeping.collapse(in: context)
        var bags = (try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let collection: CollectionItem
            if let found = CollectionHousekeeping.match(trimmed, in: bags) {
                collection = found
            } else if bags.contains(where: { !$0.saves.isEmpty || $0.isPinned }) {
                continue
            } else {
                collection = CollectionItem(name: trimmed)
                context.insert(collection)
                bags.append(collection)
            }
            if !save.collections.contains(where: { $0.collectionID == collection.collectionID }) {
                save.collections.append(collection)
            }
        }
    }

    static func jpegForModel(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1024
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return scaled.jpegData(compressionQuality: 0.72)
    }

    static func shortSummary(from text: String, fallback: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 40 { return String(cleaned.prefix(160)) }
        return fallback
    }
}

enum CollectionHousekeeping {
    static func collapse(in context: ModelContext) {
        let bags = (try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []
        let ranked = bags.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.saves.count != $1.saves.count { return $0.saves.count > $1.saves.count }
            return $0.createdAt < $1.createdAt
        }
        var keepers: [CollectionItem] = []
        for bag in ranked {
            if let host = keepers.first(where: { same($0.name, bag.name) }) {
                merge(bag, into: host, context: context)
            } else {
                keepers.append(bag)
            }
        }
        try? context.save()
    }

    static func match(_ name: String, in bags: [CollectionItem]) -> CollectionItem? {
        bags.first { same($0.name, name) }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let left = tokens(a)
        let right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if left.isSubset(of: right) || right.isSubset(of: left) { return true }
        return false
    }

    private static func tokens(_ name: String) -> Set<String> {
        let cleaned = name
            .lowercased()
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        return Set(
            cleaned.split { !$0.isLetter && !$0.isNumber }
                .map { token in
                    var word = String(token)
                    if word.hasSuffix("s"), word.count > 4 { word.removeLast() }
                    return word
                }
                .filter { $0.count > 1 && $0 != "and" && $0 != "the" && $0 != "for" }
        )
    }

    private static func merge(_ extra: CollectionItem, into host: CollectionItem, context: ModelContext) {
        guard extra.collectionID != host.collectionID else { return }
        for save in extra.saves {
            if !save.collections.contains(where: { $0.collectionID == host.collectionID }) {
                save.collections.append(host)
            }
            save.collections.removeAll { $0.collectionID == extra.collectionID }
        }
        if extra.isPinned { host.isPinned = true }
        context.delete(extra)
    }
}

enum Recap {
    struct Snapshot {
        var savedThisWeek: Int
        var savedAllTime: Int
        var interests: [String]
        var repeating: [String]
        var sources: [(name: String, count: Int)]
        var revisiting: SaveItem?
        var recent: [SaveItem]
        var isQuietWeek: Bool
    }

    static func week(_ saves: [SaveItem]) -> Snapshot {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let recentWeek = saves.filter { $0.savedAt >= start }
        let pool = recentWeek.isEmpty ? saves : recentWeek
        let topics = Dictionary(grouping: pool.flatMap(\.topics), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        let entities = Dictionary(grouping: saves.flatMap(\.entities), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }
        let sources = Dictionary(grouping: pool, by: { $0.source.label })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        let old = saves.first {
            (Calendar.current.dateComponents([.day], from: $0.savedAt, to: .now).day ?? 0) >= 30
        }
        return Snapshot(
            savedThisWeek: recentWeek.count,
            savedAllTime: saves.count,
            interests: topics.prefix(4).map(\.0),
            repeating: entities.prefix(4).map(\.0),
            sources: Array(sources.prefix(4)),
            revisiting: old,
            recent: Array(saves.prefix(5)),
            isQuietWeek: recentWeek.isEmpty && !saves.isEmpty
        )
    }
}
