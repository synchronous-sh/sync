import Foundation
import SwiftData

enum LibraryContainer {
    static let shared: ModelContainer = make()

    static func make() -> ModelContainer {
        let schema = Schema([SaveItem.self, CollectionItem.self])
        let cloud = ModelConfiguration(
            "KeepLibraryV4",
            schema: schema,
            groupContainer: .identifier(AppGroup.id),
            cloudKitDatabase: .private("iCloud.sh.synchronous.sync")
        )
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return container
        }
        let grouped = ModelConfiguration(
            "KeepLibraryV4",
            schema: schema,
            groupContainer: .identifier(AppGroup.id),
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(for: schema, configurations: [grouped]) {
            return container
        }
        let url = storeURL()
        let file = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: [file])
    }

    private static func storeURL() -> URL {
        let root = AppGroup.container
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("LibraryStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        return dir.appendingPathComponent("KeepLibraryV4.store")
    }
}

enum DirectSave {
    @discardableResult
    static func insert(
        urlString: String?,
        text: String?,
        mediaFileName: String? = nil,
        slideFileNames: [String] = [],
        notes: String? = nil,
        collectionName: String? = nil,
        into context: ModelContext
    ) throws -> SaveItem {
        let cleaned = SharedLinkParser.url(from: urlString) ?? urlString
        let parsed = cleaned.flatMap { URL(string: $0) }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMedia = !(mediaFileName?.isEmpty ?? true) || !slideFileNames.isEmpty
        guard (cleaned?.isEmpty == false) || (trimmed?.isEmpty == false) || hasMedia else {
            throw InboxError.empty
        }

        let canonical = parsed.map { SharedLinkParser.canonicalize($0.absoluteString) } ?? (cleaned ?? "")

        if !canonical.isEmpty,
           let all = try? context.fetch(FetchDescriptor<SaveItem>()),
           let existing = all.first(where: {
               $0.canonicalURL == canonical || $0.sourceURL == cleaned
           }) {
            if existing.mediaFileName.isEmpty, let mediaFileName, !mediaFileName.isEmpty {
                existing.mediaFileName = mediaFileName
                existing.processingRaw = ProcessingStatus.saved.rawValue
            }
            if existing.imageFileName.isEmpty, let first = slideFileNames.first {
                existing.imageFileName = first
            }
            if !slideFileNames.isEmpty {
                var names = existing.slides
                for name in slideFileNames where !names.contains(name) { names.append(name) }
                existing.slideFileNames = names.filter { $0 != existing.imageFileName }.joined(separator: ",")
            }
            attach(notes: notes, collectionName: collectionName, to: existing, context: context)
            try context.save()
            AppGroup.pingHost()
            return existing
        }
        var (source, content) = SourceDetect.kind(url: parsed, text: trimmed, hasImage: false)
        if hasMedia, MediaStore.isAudiovisual(mediaFileName ?? "") {
            content = .video
            if parsed == nil { source = .tiktok }
        }
        if !slideFileNames.isEmpty, content != .video {
            content = .image
        }

        let title: String
        if let trimmed, !trimmed.isEmpty, SharedLinkParser.url(from: trimmed) == nil {
            title = String(trimmed.prefix(80))
        } else if let parsed, SpotifyLink.matches(parsed) {
            title = "Spotify \(SpotifyLink.displayKind(parsed))"
        } else if let parsed {
            let hostName = parsed.host?.replacingOccurrences(of: "www.", with: "") ?? source.label
            let last = parsed.path.split(separator: "/").last.map(String.init) ?? ""
            title = last.count > 2 ? "\(hostName)/\(last)" : hostName
        } else {
            title = "Saved item"
        }

        let save = SaveItem(
            source: source,
            sourceURL: cleaned ?? "",
            canonicalURL: canonical.isEmpty ? (cleaned ?? "") : canonical,
            contentType: content,
            title: title,
            rawText: trimmed ?? "",
            processing: .saved,
            mediaFileName: mediaFileName ?? ""
        )
        if let first = slideFileNames.first {
            save.imageFileName = first
            save.slideFileNames = slideFileNames.dropFirst().joined(separator: ",")
            if save.contentTypeRaw != ContentKind.video.rawValue {
                save.contentTypeRaw = ContentKind.image.rawValue
            }
        }
        context.insert(save)
        attach(notes: notes, collectionName: collectionName, to: save, context: context)
        try context.save()
        AppGroup.pingHost()
        return save
    }

    private static func attach(
        notes: String?,
        collectionName: String?,
        to save: SaveItem,
        context: ModelContext
    ) {
        if let note = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            save.rawText = SaveNote.merging(note, into: save.rawText)
        }
        let bagName = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bagName.isEmpty else { return }
        let bags = (try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []
        let collection: CollectionItem
        if let found = bags.first(where: { $0.name.compare(bagName, options: .caseInsensitive) == .orderedSame }) {
            collection = found
        } else {
            collection = CollectionItem(name: bagName)
            context.insert(collection)
        }
        if !save.collections.contains(where: { $0.collectionID == collection.collectionID }) {
            save.collections.append(collection)
        }
    }
}
