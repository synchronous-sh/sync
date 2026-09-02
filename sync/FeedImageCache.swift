import UIKit

enum FeedImageCache {
    private static let ram = NSCache<NSString, UIImage>()

    static func image(for id: UUID) -> UIImage? {
        if let hit = ram.object(forKey: id.uuidString as NSString) { return hit }
        for ext in ["jpg", "jpeg", "png"] {
            let name = "\(id.uuidString).\(ext)"
            guard let url = MediaStore.fileURL(name),
                  let image = UIImage(contentsOfFile: url.path),
                  image.size.width >= 40 else { continue }
            ram.setObject(image, forKey: id.uuidString as NSString)
            return image
        }
        return nil
    }

    static func store(_ image: UIImage, for id: UUID) {
        ram.setObject(image, forKey: id.uuidString as NSString)
    }

    static func prefetch(_ posts: [FeedPost]) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for post in posts.prefix(4) {
                    group.addTask {
                        if image(for: post.id) != nil { return }
                        _ = await FeedNews.loadFastImage(for: post)
                    }
                }
            }
        }
    }
}
