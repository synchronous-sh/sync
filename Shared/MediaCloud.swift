import Foundation
import CloudKit

extension Notification.Name {
    static let mediaCloudReady = Notification.Name("sync.mediaCloudReady")
}

enum MediaCloud {
    private static let recordType = "MediaFile"
    private static let stampKey = "mediaCloud.uploaded.v1"
    private static let maxBytes = 90_000_000
    private static var lastCount = -1
    private static var lastAt = Date.distantPast

    private static var database: CKDatabase {
        CKContainer(identifier: "iCloud.sh.synchronous.sync").privateCloudDatabase
    }

    static func push(_ name: String) {
        guard !name.isEmpty else { return }
        Task.detached(priority: .utility) {
            await upload(name)
        }
    }

    static func reconcile(names: [String]) {
        let unique = Array(Set(names.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return }
        if unique.count == lastCount, Date().timeIntervalSince(lastAt) < 45 { return }
        lastCount = unique.count
        lastAt = Date()
        Task.detached(priority: .utility) {
            for name in unique {
                if MediaStore.fileURL(name) != nil {
                    await upload(name)
                } else {
                    await download(name)
                }
            }
        }
    }

    static func ensure(_ names: [String]) async {
        for name in names where !name.isEmpty {
            if MediaStore.fileURL(name) == nil {
                await download(name)
            } else {
                await upload(name)
            }
        }
    }

    private static func upload(_ name: String) async {
        guard let file = MediaStore.fileURL(name) else { return }
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber else { return }
        let bytes = size.intValue
        guard bytes > 800, bytes < maxBytes else { return }
        if uploaded.contains(name) { return }
        let id = CKRecord.ID(recordName: recordName(for: name))
        do {
            let record = (try? await database.record(for: id)) ?? CKRecord(recordType: recordType, recordID: id)
            record["name"] = name as CKRecordValue
            record["file"] = CKAsset(fileURL: file)
            _ = try await database.save(record)
            markUploaded(name)
        } catch {
            return
        }
    }

    private static func download(_ name: String) async {
        if MediaStore.fileURL(name) != nil { return }
        let id = CKRecord.ID(recordName: recordName(for: name))
        guard let record = try? await database.record(for: id),
              let asset = record["file"] as? CKAsset,
              let source = asset.fileURL else { return }
        let dest = MediaStore.directory().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            markUploaded(name)
            await MainActor.run {
                NotificationCenter.default.post(name: .mediaCloudReady, object: name)
            }
        } catch {
            if let data = try? Data(contentsOf: source), data.count > 800 {
                _ = MediaStore.save(data, named: name)
                markUploaded(name)
                await MainActor.run {
                    NotificationCenter.default.post(name: .mediaCloudReady, object: name)
                }
            }
        }
    }

    private static func recordName(for name: String) -> String {
        let trimmed = name.replacingOccurrences(of: "/", with: "-")
        return String(trimmed.prefix(240))
    }

    private static var uploaded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: stampKey) ?? [])
    }

    private static func markUploaded(_ name: String) {
        var next = uploaded
        next.insert(name)
        UserDefaults.standard.set(Array(next), forKey: stampKey)
    }
}
