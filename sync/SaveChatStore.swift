import Foundation

struct SaveChatLine: Codable, Identifiable, Hashable {
    var id: UUID
    var role: String
    var text: String
    var createdAt: Date

    static func user(_ text: String) -> SaveChatLine {
        SaveChatLine(id: UUID(), role: "user", text: text, createdAt: .now)
    }

    static func assistant(_ text: String) -> SaveChatLine {
        SaveChatLine(id: UUID(), role: "assistant", text: text, createdAt: .now)
    }
}

enum SaveChatStore {
    static func load(saveID: UUID) -> [SaveChatLine] {
        load(key: saveID.uuidString)
    }

    static func write(saveID: UUID, lines: [SaveChatLine]) {
        write(key: saveID.uuidString, lines: lines)
    }

    static func clear(saveID: UUID) {
        clear(key: saveID.uuidString)
    }

    static func load(key: String) -> [SaveChatLine] {
        guard let url = fileURL(key),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SaveChatLine].self, from: data)) ?? []
    }

    static func write(key: String, lines: [SaveChatLine]) {
        guard let url = fileURL(key) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(lines).write(to: url, options: .atomic)
    }

    static func clear(key: String) {
        guard let url = fileURL(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL(_ key: String) -> URL? {
        let safe = key
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = AppGroup.container
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safe).json")
    }
}
