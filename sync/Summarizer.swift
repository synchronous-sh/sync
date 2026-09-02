import Foundation

enum LibrarySummarizer {
    static func summarize(title: String, text: String, existing: String) async -> String {
        existing.isEmpty ? Enrichment.shortSummary(from: text.isEmpty ? title : text, fallback: existing) : existing
    }
}
