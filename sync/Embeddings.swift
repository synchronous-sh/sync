import Foundation
import NaturalLanguage

enum SemanticIndex {
    private static var cache: [UUID: [Double]] = [:]
    private static var queryCache: (String, [Double])?

    static func embedding(for text: String) -> [Double]? {
        bagOfWords(String(text.prefix(1200)))
    }

    static func index(_ save: SaveItem) {
        let text = [save.title, save.summary, save.rawText, save.topicsCSV, save.entitiesCSV]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        index(id: save.saveID, text: text)
    }

    static func index(id: UUID, text: String) {
        guard let vector = bagOfWords(String(text.prefix(1200))) else { return }
        cache[id] = vector
        VectorStore.save(vector, id: id)
    }

    static func vector(for save: SaveItem) -> [Double]? {
        if let cached = cache[save.saveID] { return cached }
        if let stored = VectorStore.load(id: save.saveID) {
            cache[save.saveID] = stored
            return stored
        }
        index(save)
        return cache[save.saveID]
    }

    static func similarity(between a: SaveItem, and b: SaveItem) -> Double {
        guard let va = vector(for: a), let vb = vector(for: b) else { return 0 }
        return cosine(va, vb)
    }

    static func similarity(query: String, save: SaveItem) -> Double {
        let q: [Double]
        if let cached = queryCache, cached.0 == query {
            q = cached.1
        } else if let computed = bagOfWords(query) {
            queryCache = (query, computed)
            q = computed
        } else {
            return 0
        }
        guard let stored = cache[save.saveID] ?? VectorStore.load(id: save.saveID) else { return 0 }
        cache[save.saveID] = stored
        return cosine(q, stored)
    }

    private static func bagOfWords(_ text: String) -> [Double]? {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var sum: [Double]?
        var count = 0
        for token in tokens where token.count > 1 {
            guard let vector = embedding.vector(for: token) else { continue }
            if sum == nil {
                sum = vector
            } else {
                sum = zip(sum!, vector).map { $0 + $1 }
            }
            count += 1
            if count > 80 { break }
        }
        guard let total = sum, count > 0 else { return nil }
        let n = Double(count)
        return total.map { $0 / n }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 0 else { return 0 }
        return max(0, dot / denom)
    }
}
