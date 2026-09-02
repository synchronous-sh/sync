import SwiftUI
import UIKit
import Combine

@MainActor
final class FeedRevealBox: ObservableObject {
    @Published var post: FeedPost?
}

struct VerticalFeedPager: UIViewControllerRepresentable {
    let posts: [FeedPost]
    let saveFor: (FeedPost) -> SaveItem?
    var articleSaved: (FeedPost) -> Bool = { _ in false }
    @Binding var currentID: UUID?
    var onWhy: (UUID) -> Void
    var onAsk: (UUID) -> Void
    var onOpen: (UUID) -> Void
    var onMute: () -> Void
    var onNeedMore: () -> Void = {}
    var onRefresh: () async -> Void = {}
    var scrollNonce: Int = 0
    var reveal: FeedPost? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> FeedPagingController {
        let controller = FeedPagingController()
        controller.coordinator = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.apply(self, jump: true)
        return controller
    }

    func updateUIViewController(_ controller: FeedPagingController, context: Context) {
        context.coordinator.apply(self, jump: false)
    }

    final class Coordinator {
        weak var controller: FeedPagingController?
        var currentID: Binding<UUID?> = .constant(nil)
        var onWhy: (UUID) -> Void = { _ in }
        var onAsk: (UUID) -> Void = { _ in }
        var onOpen: (UUID) -> Void = { _ in }
        var onMute: () -> Void = {}
        var onNeedMore: () -> Void = {}
        var onRefresh: () async -> Void = {}
        var saveFor: (FeedPost) -> SaveItem? = { _ in nil }
        var articleSaved: (FeedPost) -> Bool = { _ in false }
        var lastNonce = -1
        var lastIDs: [UUID] = []
        var lastRevealID: UUID?
        var lastRevealScript = ""
        var pending: VerticalFeedPager?

        func apply(_ parent: VerticalFeedPager, jump: Bool) {
            currentID = parent.$currentID
            onWhy = parent.onWhy
            onAsk = parent.onAsk
            onOpen = parent.onOpen
            onMute = parent.onMute
            onNeedMore = parent.onNeedMore
            onRefresh = parent.onRefresh
            saveFor = parent.saveFor
            articleSaved = parent.articleSaved

            guard let controller else { return }
            if controller.isBusy {
                pending = parent
                return
            }

            let ids = parent.posts.map(\.id)
            let revealID = parent.reveal?.id
            let revealScript = parent.reveal?.script ?? ""
            let shouldJump = jump || parent.scrollNonce != lastNonce
            let structureChanged = ids != lastIDs
            let revealChanged = revealID != lastRevealID || revealScript != lastRevealScript
            lastNonce = parent.scrollNonce
            lastIDs = ids
            lastRevealID = revealID
            lastRevealScript = revealScript

            if !jump, !shouldJump, !structureChanged, !revealChanged {
                return
            }
            pending = nil
            controller.render(
                posts: parent.posts,
                reveal: parent.reveal,
                currentID: parent.currentID,
                jump: shouldJump,
                rebuild: structureChanged || shouldJump,
                revealOnly: revealChanged && !structureChanged && !shouldJump,
                coordinator: self
            )
        }

        func settle() {
            guard let parent = pending else { return }
            pending = nil
            apply(parent, jump: false)
        }
    }
}

final class FeedPagingController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    weak var coordinator: VerticalFeedPager.Coordinator?
    private let scroller = UIScrollView()
    private var hosts: [UUID: UIHostingController<FeedPageView>] = [:]
    private var order: [UUID] = []
    private var lastSize: CGSize = .zero

    var isBusy: Bool {
        scroller.isTracking || scroller.isDragging || scroller.isDecelerating
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(SyncTheme.paper)
        scroller.backgroundColor = UIColor(SyncTheme.paper)
        scroller.isPagingEnabled = true
        scroller.showsVerticalScrollIndicator = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceVertical = true
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.decelerationRate = .fast
        scroller.delegate = self
        view.addSubview(scroller)

        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(SyncTheme.ink)
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        scroller.refreshControl = refresh

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(openSummary))
        swipe.direction = .left
        swipe.delegate = self
        scroller.addGestureRecognizer(swipe)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func openSummary() {
        guard let id = order[safe: currentIndex()] else { return }
        coordinator?.onOpen(id)
    }

    @objc private func pulled() {
        Task { @MainActor in
            await coordinator?.onRefresh()
            scroller.refreshControl?.endRefreshing()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroller.frame = view.bounds
        if view.bounds.size != lastSize {
            lastSize = view.bounds.size
            layoutPages(keepPage: true)
        }
    }

    func render(
        posts: [FeedPost],
        reveal: FeedPost?,
        currentID: UUID?,
        jump: Bool,
        rebuild: Bool,
        revealOnly: Bool,
        coordinator: VerticalFeedPager.Coordinator
    ) {
        if revealOnly {
            if let reveal {
                let page = pageView(reveal, coordinator: coordinator)
                hosts[reveal.id]?.rootView = page
            }
            return
        }

        let keepY = scroller.contentOffset.y
        if rebuild {
            let keep = Set(posts.map(\.id))
            for (id, host) in hosts where !keep.contains(id) {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                hosts[id] = nil
            }
            order = posts.map(\.id)
            for post in posts {
                let shown = (reveal?.id == post.id) ? (reveal ?? post) : post
                let page = pageView(shown, save: post, coordinator: coordinator)
                if let host = hosts[post.id] {
                    host.rootView = page
                } else {
                    let host = UIHostingController(rootView: page)
                    host.view.backgroundColor = UIColor(SyncTheme.paper)
                    host.safeAreaRegions = []
                    addChild(host)
                    scroller.addSubview(host.view)
                    host.didMove(toParent: self)
                    hosts[post.id] = host
                }
            }
            layoutPages(keepPage: false)
            if jump, let currentID, let index = order.firstIndex(of: currentID) {
                scroller.setContentOffset(CGPoint(x: 0, y: pageHeight * CGFloat(index)), animated: false)
            } else {
                scroller.contentOffset.y = min(keepY, max(0, scroller.contentSize.height - pageHeight))
            }
        }
    }

    private func pageView(_ shown: FeedPost, save: FeedPost? = nil, coordinator: VerticalFeedPager.Coordinator) -> FeedPageView {
        let post = save ?? shown
        return FeedPageView(
            post: shown,
            save: coordinator.saveFor(post),
            articleSaved: coordinator.articleSaved(post),
            onWhy: coordinator.onWhy,
            onAsk: coordinator.onAsk,
            onMute: coordinator.onMute
        )
    }

    private var pageHeight: CGFloat {
        max(view.bounds.height, 1)
    }

    private func layoutPages(keepPage: Bool) {
        let h = pageHeight
        let w = view.bounds.width
        let index = keepPage ? Int(round(scroller.contentOffset.y / h)) : Int(scroller.contentOffset.y / max(h, 1))
        scroller.contentSize = CGSize(width: w, height: h * CGFloat(order.count))
        for (i, id) in order.enumerated() {
            hosts[id]?.view.frame = CGRect(x: 0, y: h * CGFloat(i), width: w, height: h)
        }
        if keepPage, !order.isEmpty {
            let clamped = min(max(0, index), order.count - 1)
            scroller.contentOffset = CGPoint(x: 0, y: h * CGFloat(clamped))
        }
    }

    private func currentIndex() -> Int {
        guard pageHeight > 0, !order.isEmpty else { return 0 }
        return min(max(0, Int(round(scroller.contentOffset.y / pageHeight))), order.count - 1)
    }

    private func emitIfSettled() {
        guard !isBusy, let id = order[safe: currentIndex()] else { return }
        if coordinator?.currentID.wrappedValue != id {
            coordinator?.currentID.wrappedValue = id
        }
    }

    private func maybeNeedMore() {
        let index = currentIndex()
        if order.count - index < 12 {
            coordinator?.onNeedMore()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishedMoving()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishedMoving() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishedMoving()
    }

    private func finishedMoving() {
        emitIfSettled()
        maybeNeedMore()
        coordinator?.settle()
    }
}

private struct FeedPageView: View {
    let post: FeedPost
    let save: SaveItem?
    let articleSaved: Bool
    var onWhy: (UUID) -> Void
    var onAsk: (UUID) -> Void
    var onMute: () -> Void

    var body: some View {
        FeedCard(
            post: post,
            save: save,
            articleSaved: articleSaved,
            onWhy: onWhy,
            onAsk: onAsk,
            onMute: onMute
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
