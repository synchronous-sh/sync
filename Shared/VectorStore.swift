import Foundation

enum VectorStore {
    private static var directory: URL? {
        guard let root = AppGroup.container else { return nil }
        let dir = root.appendingPathComponent("vectors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ vector: [Double], id: UUID) {
        guard let dir = directory else { return }
        let data = try? JSONEncoder().encode(vector)
        try? data?.write(to: dir.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    static func load(id: UUID) -> [Double]? {
        guard let dir = directory else { return nil }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json")) else {
            return nil
        }
        return try? JSONDecoder().decode([Double].self, from: data)
    }

    static func hasVector(id: UUID) -> Bool {
        guard let dir = directory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id.uuidString).json").path)
    }
}
