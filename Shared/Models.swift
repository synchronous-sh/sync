import Foundation
import SwiftData

@Model
final class SaveItem {
    var saveID: UUID = UUID()
    var sourceRaw: String = SourceKind.web.rawValue
    var sourceURL: String = ""
    var canonicalURL: String = ""
    var contentTypeRaw: String = ContentKind.article.rawValue
    var title: String = "Saved item"
    var summary: String = ""
    var creatorName: String = ""
    var creatorHandle: String = ""
    var rawText: String = ""
    var topicsCSV: String = ""
    var entitiesCSV: String = ""
    var processingRaw: String = ProcessingStatus.ready.rawValue
    var imageFileName: String = ""
    var mediaFileName: String = ""
    var slideFileNames: String = ""
    var savedAt: Date = Date()
    var createdAt: Date = Date()

    @Relationship(inverse: \CollectionItem.saves)
    var collections: [CollectionItem] = []

    init(
        id: UUID = UUID(),
        source: SourceKind,
        sourceURL: String,
        canonicalURL: String? = nil,
        contentType: ContentKind,
        title: String,
        summary: String = "",
        creatorName: String = "",
        creatorHandle: String = "",
        rawText: String = "",
        topics: [String] = [],
        entities: [String] = [],
        processing: ProcessingStatus = .ready,
        imageFileName: String = "",
        mediaFileName: String = "",
        slideFileNames: String = "",
        savedAt: Date = .now,
        collections: [CollectionItem] = []
    ) {
        self.saveID = id
        self.sourceRaw = source.rawValue
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL ?? sourceURL
        self.contentTypeRaw = contentType.rawValue
        self.title = title
        self.summary = summary
        self.creatorName = creatorName
        self.creatorHandle = creatorHandle
        self.rawText = rawText
        self.topicsCSV = topics.joined(separator: ",")
        self.entitiesCSV = entities.joined(separator: ",")
        self.processingRaw = processing.rawValue
        self.imageFileName = imageFileName
        self.mediaFileName = mediaFileName
        self.slideFileNames = slideFileNames
        self.savedAt = savedAt
        self.createdAt = .now
        self.collections = collections
    }

    var source: SourceKind { SourceKind(rawValue: sourceRaw) ?? .web }
    var contentType: ContentKind { ContentKind(rawValue: contentTypeRaw) ?? .article }
    var processing: ProcessingStatus { ProcessingStatus(rawValue: processingRaw) ?? .saved }
    var topics: [String] { topicsCSV.split(separator: ",").map { String($0) }.filter { !$0.isEmpty } }
    var entities: [String] { entitiesCSV.split(separator: ",").map { String($0) }.filter { !$0.isEmpty } }
    var slides: [String] {
        let extras = slideFileNames.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        var names: [String] = []
        if !imageFileName.isEmpty { names.append(imageFileName) }
        for name in extras where !names.contains(name) { names.append(name) }
        return names
    }

    var searchableBlob: String {
        [title, summary, rawText, creatorName, creatorHandle, topicsCSV, entitiesCSV, source.label]
            .joined(separator: " ")
            .lowercased()
    }
}

@Model
final class CollectionItem {
    var collectionID: UUID = UUID()
    var name: String = ""
    var isPinned: Bool = false
    var createdAt: Date = Date()
    var saves: [SaveItem] = []

    init(id: UUID = UUID(), name: String, isPinned: Bool = false, saves: [SaveItem] = []) {
        self.collectionID = id
        self.name = name
        self.isPinned = isPinned
        self.createdAt = .now
        self.saves = saves
    }
}
