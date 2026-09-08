import UIKit
import SwiftUI
import Combine

@MainActor
final class FeedPhotoBox: ObservableObject {
    static let shared = FeedPhotoBox()
    @Published private(set) var generation = 0
    private var inflight = Set<UUID>()

    func generationBump() {
        generation += 1
    }

    func image(for id: UUID) -> UIImage? {
        FeedImageCache.image(for: id)
    }

    func ensure(_ post: FeedPost) {
        let title = post.title.isEmpty ? post.headline : post.title
        let artID = FeedNews.photoID(url: post.headlineURL, title: title)
        if FeedImageCache.image(for: artID) != nil || FeedImageCache.image(for: post.id) != nil { return }
        guard inflight.insert(artID).inserted else { return }
        Task(priority: .userInitiated) { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = await FeedNews.loadFastImage(for: post)
            // #region agent log
            AgentDebug.log("D", "FeedPhotoBox.ensure", "post_done", [
                "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
                "nil": image == nil
            ])
            // #endregion
            await MainActor.run {
                if let image {
                    FeedImageCache.store(image, for: post.id)
                    FeedImageCache.store(image, for: artID)
                }
                self?.inflight.remove(artID)
                self?.generation += 1
            }
        }
    }

    func ensure(_ story: NewsHeadline) {
        let id = FeedNews.photoID(for: story)
        if FeedImageCache.image(for: id) != nil { return }
        guard inflight.insert(id).inserted else { return }
        Task { [weak self] in
            let image = await FeedNews.loadFastImage(for: story)
            await MainActor.run {
                if let image {
                    FeedImageCache.store(image, for: id)
                }
                self?.inflight.remove(id)
                self?.generation += 1
            }
        }
    }
}

enum FeedImageCache {
    private static let ram: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    static func image(for id: UUID) -> UIImage? {
        if let hit = ram.object(forKey: id.uuidString as NSString) { return hit }
        for name in [
            "\(id.uuidString).jpg",
            "\(id.uuidString).jpeg",
            "\(id.uuidString).png",
            "\(id.uuidString)-p4.jpg"
        ] {
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
        if let jpeg = image.jpegData(compressionQuality: 0.86) {
            _ = MediaStore.save(jpeg, id: id)
        }
    }

    private static var remoteOwner: [String: UUID] = [:]
    private static let remoteLock = NSLock()

    private static func remoteKey(_ url: URL) -> String {
        "\((url.host ?? "").lowercased())\(url.path.lowercased())"
    }

    static func remoteTaken(_ url: URL, by id: UUID) -> Bool {
        remoteLock.lock()
        defer { remoteLock.unlock() }
        if let owner = remoteOwner[remoteKey(url)], owner != id { return true }
        return false
    }

    static func claimRemote(_ url: URL, for id: UUID) {
        remoteLock.lock()
        remoteOwner[remoteKey(url)] = id
        remoteLock.unlock()
    }

    static func image(forRemote url: URL, owner id: UUID) -> UIImage? {
        if remoteTaken(url, by: id) { return nil }
        return ram.object(forKey: url.absoluteString as NSString)
    }

    static func store(_ image: UIImage, remote url: URL, owner id: UUID) {
        if remoteTaken(url, by: id) { return }
        claimRemote(url, for: id)
        ram.setObject(image, forKey: url.absoluteString as NSString)
    }

    static func prefetch(_ posts: [FeedPost]) {
        Task(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for post in posts.prefix(16) {
                    group.addTask {
                        _ = await FeedNews.loadFastImage(for: post)
                    }
                }
            }
        }
    }
}

final class FeedPhotoView: UIView {
    private let back = UIImageView()
    private let dim = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let front = UIImageView()
    private var token = UUID()
    private var loadedID: UUID?
    private var loadingID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        back.contentMode = .scaleAspectFill
        back.clipsToBounds = true
        front.contentMode = .scaleAspectFill
        front.clipsToBounds = true
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        addSubview(back)
        addSubview(blur)
        addSubview(dim)
        addSubview(front)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        back.frame = bounds
        blur.frame = bounds
        dim.frame = bounds
        front.frame = bounds
        if front.image == nil, let id = loadingID ?? loadedID, let cached = FeedImageCache.image(for: id) {
            setPhoto(cached, id: id)
        }
        applyFit()
    }

    func show(_ post: FeedPost) {
        // #region agent log
        if loadedID != nil, loadedID != post.id, front.image != nil {
            AgentDebug.log("E", "FeedImageCache.swift:show", "stale_or_switch", [
                "from": loadedID?.uuidString ?? "",
                "to": post.id.uuidString,
                "imgHost": URL(string: post.imageURL)?.host ?? "none"
            ])
        }
        // #endregion
        let title = post.title.isEmpty ? post.headline : post.title
        let artID = FeedNews.photoID(url: post.headlineURL, title: title)
        if let cached = FeedImageCache.image(for: artID) {
            setPhoto(cached, id: post.id)
            loadingID = nil
            return
        }
        if loadedID != post.id {
            setPhoto(nil, id: post.id)
        }
        if loadingID == post.id {
            return
        }
        loadingID = post.id
        let token = UUID()
        self.token = token
        Task { [weak self] in
            let photo = await FeedNews.loadFastImage(for: post)
            if let photo {
                FeedImageCache.store(photo, for: post.id)
            }
            await MainActor.run {
                guard let self, self.token == token else { return }
                self.loadingID = nil
                if let photo {
                    self.setPhoto(photo, id: post.id)
                    FeedPhotoBox.shared.generationBump()
                } else if self.loadedID == post.id, self.front.image == nil {
                    AgentDebug.log("A", "FeedPhotoView.show", "still_empty", ["title": String(post.title.prefix(40))])
                }
            }
        }
    }

    private func setPhoto(_ photo: UIImage?, id: UUID) {
        loadedID = id
        back.image = photo
        front.image = photo
        applyFit()
    }

    private func applyFit() {
        guard let photo = front.image, bounds.height > 1 else {
            back.isHidden = true
            blur.isHidden = true
            dim.isHidden = true
            front.contentMode = .scaleAspectFill
            return
        }
        let imageRatio = photo.size.width / max(photo.size.height, 1)
        let frameRatio = bounds.width / max(bounds.height, 1)
        let wide = imageRatio > frameRatio + 0.04
        back.isHidden = !wide
        blur.isHidden = !wide
        dim.isHidden = !wide
        blur.alpha = wide ? 0.72 : 0
        front.contentMode = wide ? .scaleAspectFit : .scaleAspectFill
    }
}

struct FeedBackdrop: UIViewRepresentable {
    let post: FeedPost

    func makeUIView(context: Context) -> FeedPhotoView {
        let view = FeedPhotoView()
        view.show(post)
        return view
    }

    func updateUIView(_ view: FeedPhotoView, context: Context) {
        view.show(post)
    }
}
