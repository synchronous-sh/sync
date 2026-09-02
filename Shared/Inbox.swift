import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AppGroup {
    static let id = "group.sh.synchronous.sync"
    static let defaultsKey = "pendingInbox"
    static let pasteboardName = "sh.synchronous.sync.inbox"
    nonisolated(unsafe) static let pingName = "sh.synchronous.sync.inbox" as CFString

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var inboxDirectory: URL? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }

    static func pingHost() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(pingName),
            nil,
            nil,
            true
        )
    }
}

struct InboxItem: Codable, Equatable {
    var id: UUID
    var url: String?
    var text: String?
    var imageRelativePath: String?
    var createdAt: Date

    var isEmpty: Bool {
        let urlEmpty = url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let textEmpty = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return urlEmpty && textEmpty && imageRelativePath == nil
    }
}

enum InboxStore {
    static func enqueue(_ item: InboxItem) throws {
        guard !item.isEmpty else { throw InboxError.empty }

        var wroteFile = false
        if let dir = AppGroup.inboxDirectory {
            let file = dir.appendingPathComponent("\(item.id.uuidString).json")
            try JSONEncoder().encode(item).write(to: file, options: .atomic)
            wroteFile = FileManager.default.fileExists(atPath: file.path)
        }

        var items = loadDefaults()
        items.removeAll { $0.id == item.id }
        items.append(item)
        saveDefaults(items)

        var all = pending()
        if !all.contains(where: { $0.id == item.id }) {
            all.append(item)
        }
        writePasteboard(all)

        let verified = pending().contains(where: { $0.id == item.id })
        guard wroteFile || verified else { throw InboxError.noAppGroup }

        AppGroup.pingHost()
    }

    static func pending() -> [InboxItem] {
        var items = loadDefaults()
        if let dir = AppGroup.inboxDirectory {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let item = try? JSONDecoder().decode(InboxItem.self, from: data),
                   !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
            }
        }
        for item in readPasteboard() where !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    static func remove(_ item: InboxItem) {
        if let dir = AppGroup.inboxDirectory {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(item.id.uuidString).json"))
            if let rel = item.imageRelativePath {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(rel))
            }
        }
        saveDefaults(loadDefaults().filter { $0.id != item.id })
        writePasteboard(pending().filter { $0.id != item.id })
    }

    static func writeImage(_ data: Data, id: UUID) throws -> String {
        guard let dir = AppGroup.inboxDirectory else { throw InboxError.noAppGroup }
        let name = "\(id.uuidString).jpg"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func imageURL(for item: InboxItem) -> URL? {
        guard let rel = item.imageRelativePath, let dir = AppGroup.inboxDirectory else { return nil }
        return dir.appendingPathComponent(rel)
    }

    private static func loadDefaults() -> [InboxItem] {
        guard let data = AppGroup.defaults?.data(forKey: AppGroup.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([InboxItem].self, from: data)) ?? []
    }

    private static func saveDefaults(_ items: [InboxItem]) {
        guard let defaults = AppGroup.defaults else { return }
        defaults.set(try? JSONEncoder().encode(items), forKey: AppGroup.defaultsKey)
        defaults.synchronize()
    }

    private static func writePasteboard(_ items: [InboxItem]) {
        #if canImport(UIKit)
        guard let data = try? JSONEncoder().encode(items) else { return }
        let board = UIPasteboard(name: UIPasteboard.Name(AppGroup.pasteboardName), create: true)
        board?.setData(data, forPasteboardType: "public.json")
        #endif
    }

    private static func readPasteboard() -> [InboxItem] {
        #if canImport(UIKit)
        let board = UIPasteboard(name: UIPasteboard.Name(AppGroup.pasteboardName), create: false)
        guard let data = board?.data(forPasteboardType: "public.json") else { return [] }
        return (try? JSONDecoder().decode([InboxItem].self, from: data)) ?? []
        #else
        return []
        #endif
    }
}

enum InboxError: Error {
    case noAppGroup
    case empty
}

enum SaveNote {
    static func merging(_ note: String, into raw: String) -> String {
        let clipped = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipped.isEmpty else { return raw }
        if raw.contains(clipped) { return raw }
        return ["Note:\n\(clipped)", raw].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func stripping(from raw: String) -> String {
        guard let note = text(in: raw) else { return raw }
        var rest = raw
        let block = "Note:\n\(note)"
        if let range = rest.range(of: block) {
            rest.removeSubrange(range)
        } else if rest.lowercased().hasPrefix("note:") {
            if let split = rest.range(of: "\n\n") {
                rest = String(rest[split.upperBound...])
            } else {
                rest = ""
            }
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacing(_ note: String, in raw: String) -> String {
        merging(note, into: stripping(from: raw))
    }

    static func text(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("note:") else { return nil }
        var rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = rest.range(of: "\n\n") {
            rest = String(rest[..<range.lowerBound])
        } else if let range = rest.range(of: "\nSpoken:") ?? rest.range(of: "\nOn-screen:") {
            rest = String(rest[..<range.lowerBound])
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}

enum SharedLinkParser {
    static func url(from raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.lowercased().hasPrefix("spotify:") {
            if let url = URL(string: trimmed), let open = SpotifyLink.canonicalOpenURL(url) {
                return open.absoluteString
            }
        }
        if trimmed.hasPrefix("www.") { trimmed = "https://\(trimmed)" }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return trimmed
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector?.firstMatch(in: trimmed, options: [], range: range),
              let swiftRange = Range(match.range, in: trimmed) else { return nil }
        var found = String(trimmed[swiftRange])
        if found.hasPrefix("www.") { found = "https://\(found)" }
        return found
    }

    static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), SpotifyLink.matches(url),
           let open = SpotifyLink.canonicalOpenURL(url) {
            return open.absoluteString
        }
        guard var comps = URLComponents(string: trimmed) else {
            return raw
        }
        comps.fragment = nil
        comps.queryItems = comps.queryItems?.filter { item in
            let name = item.name.lowercased()
            let drop = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
                        "fbclid", "gclid", "igshid", "igsh", "si", "feature", "pp", "ref", "ref_src",
                        "s", "t", "context"]
            return !drop.contains(name) && !name.hasPrefix("utm_")
        }
        if comps.queryItems?.isEmpty == true {
            comps.queryItems = nil
        }
        if let host = comps.host?.lowercased() {
            comps.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        comps.scheme = comps.scheme?.lowercased()
        return comps.url?.absoluteString ?? raw
    }
}
