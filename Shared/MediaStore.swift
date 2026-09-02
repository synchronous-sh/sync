import Foundation

enum MediaStore {
    static func directory() -> URL {
        let base = AppGroup.container
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: dir.path
        )
        return dir
    }

    static func save(_ data: Data, id: UUID, ext: String = "jpg") -> String {
        let name = "\(id.uuidString).\(ext)"
        try? data.write(to: directory().appendingPathComponent(name), options: .atomic)
        return name
    }

    static func save(_ data: Data, named name: String) -> String {
        try? data.write(to: directory().appendingPathComponent(name), options: .atomic)
        return name
    }

    static func importFile(from source: URL, id: UUID) -> String? {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        let name = "\(id.uuidString).\(ext)"
        let dest = directory().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return name
        } catch {
            guard let data = try? Data(contentsOf: source) else { return nil }
            try? data.write(to: dest, options: .atomic)
            return FileManager.default.fileExists(atPath: dest.path) ? name : nil
        }
    }

    static func fileURL(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let url = directory().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func isVisualImage(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(
            (name as NSString).pathExtension.lowercased()
        )
    }

    static func playableURL(for save: SaveItem) -> URL? {
        if isAudiovisual(save.mediaFileName), let url = fileURL(save.mediaFileName) {
            return url
        }
        let id = save.saveID.uuidString
        for ext in ["mp4", "mov", "m4v", "m4a"] {
            if let url = fileURL("\(id).\(ext)") { return url }
        }
        return nil
    }

    static func isAudiovisual(_ name: String) -> Bool {
        ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac", "caf"].contains(
            (name as NSString).pathExtension.lowercased()
        )
    }
}
