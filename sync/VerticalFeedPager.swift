import SwiftUI
import UIKit
import Combine

@MainActor
final class FeedRevealBox: ObservableObject {
    @Published var post: FeedPost?
}

struct VerticalFeedPager: UIViewControllerRepresentable, Equatable {
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
    var darkCanvas: Bool = true

    static func == (lhs: VerticalFeedPager, rhs: VerticalFeedPager) -> Bool {
        lhs.posts.map(\.id) == rhs.posts.map(\.id)
            && lhs.posts.map(\.script) == rhs.posts.map(\.script)
            && lhs.currentID == rhs.currentID
            && lhs.scrollNonce == rhs.scrollNonce
            && lhs.reveal?.id == rhs.reveal?.id
            && lhs.reveal?.script == rhs.reveal?.script
            && lhs.darkCanvas == rhs.darkCanvas
    }

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

    @MainActor
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
        var lastScripts: [UUID: String] = [:]
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
            controller.setCanvas(dark: parent.darkCanvas)
            let nonceChanged = parent.scrollNonce != lastNonce
            if controller.isBusy, !jump, !nonceChanged {
                pending = parent
                // #region agent log
                AgentDebug.log("A", "VerticalFeedPager.swift:apply", "defer_busy", ["n": parent.posts.count])
                // #endregion
                return
            }

            let ids = parent.posts.map(\.id)
            let scripts = Dictionary(parent.posts.map { ($0.id, $0.script) }, uniquingKeysWith: { _, b in b })
            let revealID = parent.reveal?.id
            let revealScript = parent.reveal?.script ?? ""
            let shouldJump = jump || parent.scrollNonce != lastNonce
            let structureChanged = ids != lastIDs
            let copyChangedIDs = ids.filter { scripts[$0] != lastScripts[$0] }
            let copyChanged = !copyChangedIDs.isEmpty
            let revealChanged = revealID != lastRevealID || revealScript != lastRevealScript
            if controller.isBusy, !shouldJump {
                pending = parent
                // #region agent log
                AgentDebug.log("A", "VerticalFeedPager.swift:apply", "defer_busy_late", [
                    "structure": structureChanged,
                    "copy": copyChanged,
                    "reveal": revealChanged
                ])
                // #endregion
                return
            }
            lastNonce = parent.scrollNonce
            lastIDs = ids
            lastScripts = scripts
            lastRevealID = revealID
            if revealChanged {
                lastRevealScript = revealScript
            }

            if !jump, !shouldJump, !structureChanged, !revealChanged, !copyChanged {
                return
            }
            // #region agent log
            AgentDebug.log("B", "VerticalFeedPager.swift:apply", "pager_render", [
                "jump": shouldJump,
                "rebuild": structureChanged || shouldJump,
                "copy": copyChangedIDs.count,
                "reveal": revealChanged,
                "busy": controller.isBusy,
                "n": ids.count
            ])
            // #endregion
            pending = nil
            controller.render(
                posts: parent.posts,
                reveal: parent.reveal,
                currentID: parent.currentID,
                jump: shouldJump,
                rebuild: structureChanged || shouldJump,
                revealOnly: (revealChanged || copyChanged) && !structureChanged && !shouldJump,
                patchIDs: Set(copyChangedIDs + (revealID.map { [$0] } ?? [])),
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
    private var catalog: [UUID: FeedPost] = [:]
    private var lastWindowIndex = -1
    private var reveal: FeedPost?
    private var refreshHost: UIHostingController<SyncRefreshMark>?
    private var refreshing = false

    var isBusy: Bool {
        scroller.isTracking || scroller.isDragging || scroller.isDecelerating
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setCanvas(dark: true)
        view.insetsLayoutMarginsFromSafeArea = false
        scroller.insetsLayoutMarginsFromSafeArea = false
        scroller.isPagingEnabled = true
        scroller.showsVerticalScrollIndicator = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceVertical = true
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.decelerationRate = .fast
        scroller.delegate = self
        view.addSubview(scroller)

        let mark = UIHostingController(rootView: SyncRefreshMark(inverted: true))
        mark.view.backgroundColor = .clear
        mark.view.isUserInteractionEnabled = false
        mark.view.alpha = 0
        addChild(mark)
        view.addSubview(mark.view)
        mark.didMove(toParent: self)
        refreshHost = mark

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(openSummary))
        swipe.direction = .left
        swipe.delegate = self
        scroller.addGestureRecognizer(swipe)
    }

    func setCanvas(dark: Bool) {
        let color: UIColor = dark ? .black : UIColor(SyncTheme.paper)
        view.backgroundColor = color
        scroller.backgroundColor = color
        scroller.refreshControl = nil
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
        beginRefresh()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateRefreshMark()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishedMoving() }
        let pull = currentIndex() == 0 ? -scrollView.contentOffset.y : 0
        if pull > 76, !refreshing {
            beginRefresh()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroller.frame = view.bounds
        layoutRefreshMark()
        if view.bounds.size != lastSize {
            lastSize = view.bounds.size
            layoutPages(keepPage: true)
            lastWindowIndex = -1
            syncWindow(recycle: !isBusy)
        }
    }

    func render(
        posts: [FeedPost],
        reveal: FeedPost?,
        currentID: UUID?,
        jump: Bool,
        rebuild: Bool,
        revealOnly: Bool,
        patchIDs: Set<UUID> = [],
        coordinator: VerticalFeedPager.Coordinator
    ) {
        catalog = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        self.reveal = reveal
        order = posts.map(\.id)
        if revealOnly {
            guard !isBusy else { return }
            // #region agent log
            AgentDebug.log("D", "VerticalFeedPager.swift:render", "patch_rootView", ["n": patchIDs.count, "busy": isBusy])
            // #endregion
            let visible = coordinator.currentID.wrappedValue
            let targets = patchIDs.isEmpty ? Set(hosts.keys) : patchIDs
            for id in targets where id != visible {
                guard let post = catalog[id], let host = hosts[id] else { continue }
                let shown = (reveal?.id == post.id) ? (reveal ?? post) : post
                host.rootView = pageView(shown, save: post, coordinator: coordinator)
            }
            return
        }

        let keepY = scroller.contentOffset.y
        layoutPages(keepPage: false)
        if jump, let currentID, let index = order.firstIndex(of: currentID) {
            scroller.setContentOffset(CGPoint(x: 0, y: pageHeight * CGFloat(index)), animated: false)
        } else if !jump {
            scroller.contentOffset.y = min(keepY, max(0, scroller.contentSize.height - pageHeight))
        }
        // #region agent log
        AgentDebug.log("C", "VerticalFeedPager.swift:render", "layout_sync", [
            "jump": jump,
            "rebuild": rebuild,
            "recycle": jump,
            "busy": isBusy,
            "hosts": hosts.count
        ])
        // #endregion
        syncWindow(coordinator: coordinator, recycle: jump || rebuild)
        prefetchWindowPhotos()
    }

    private func pageView(_ shown: FeedPost, save: FeedPost? = nil, coordinator: VerticalFeedPager.Coordinator) -> FeedPageView {
        let post = save ?? shown
        return FeedPageView(
            post: shown,
            save: coordinator.saveFor(post),
            articleSaved: coordinator.articleSaved(post),
            onWhy: coordinator.onWhy,
            onAsk: coordinator.onAsk,
            onOpen: coordinator.onOpen,
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

    private func syncWindow(coordinator: VerticalFeedPager.Coordinator? = nil, recycle: Bool) {
        let coord = coordinator ?? self.coordinator
        guard let coord else { return }
        let idx = currentIndex()
        lastWindowIndex = idx
        let lo = max(0, idx - 1)
        let hi = min(order.count - 1, idx + 1)
        guard hi >= lo, !order.isEmpty else { return }
        let keep = Set(order[lo...hi])
        if recycle {
            var dropped = 0
            for (id, host) in hosts where !keep.contains(id) {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                hosts[id] = nil
                dropped += 1
            }
            if dropped > 0 {
                // #region agent log
                AgentDebug.log("C", "VerticalFeedPager.swift:syncWindow", "recycle_drop", [
                    "dropped": dropped,
                    "busy": isBusy,
                    "idx": idx
                ])
                // #endregion
            }
        }
        let h = pageHeight
        let w = view.bounds.width
        scroller.contentSize = CGSize(width: w, height: h * CGFloat(order.count))
        for i in lo...hi {
            let id = order[i]
            guard var post = catalog[id] else { continue }
            // #region agent log
            let tStore = CFAbsoluteTimeGetCurrent()
            // #endregion
            if let stored = FeedStore.load().first(where: { $0.id == id }),
               stored.script.count > post.script.count {
                post = stored
                catalog[id] = stored
            }
            // #region agent log
            let storeMs = Int((CFAbsoluteTimeGetCurrent() - tStore) * 1000)
            if storeMs >= 4 {
                AgentDebug.log("A", "VerticalFeedPager.swift:syncWindow", "store_lookup", [
                    "ms": storeMs,
                    "idx": i
                ])
            }
            // #endregion
            if let host = hosts[id] {
                host.view.frame = CGRect(x: 0, y: h * CGFloat(i), width: w, height: h)
                continue
            }
            let shown = (reveal?.id == post.id) ? (reveal ?? post) : post
            let host = UIHostingController(rootView: pageView(shown, save: post, coordinator: coord))
            host.view.backgroundColor = .black
            host.safeAreaRegions = []
            addChild(host)
            scroller.addSubview(host.view)
            host.didMove(toParent: self)
            host.view.frame = CGRect(x: 0, y: h * CGFloat(i), width: w, height: h)
            hosts[id] = host
            FeedPhotoBox.shared.ensure(post)
            // #region agent log
            AgentDebug.log("E", "VerticalFeedPager.swift:syncWindow", "host_create", ["idx": i, "busy": isBusy])
            // #endregion
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
        if order.count - index < 4 {
            coordinator?.onNeedMore()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishedMoving()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishedMoving()
    }

    private func finishedMoving() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let idx = currentIndex()
        emitIfSettled()
        maybeNeedMore()
        syncWindow(recycle: true)
        prefetchWindowPhotos()
        coordinator?.settle()
        // #region agent log
        AgentDebug.log("B", "VerticalFeedPager.swift:finishedMoving", "settle", [
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "idx": idx,
            "hosts": hosts.count,
            "n": order.count
        ])
        // #endregion
    }

    private func prefetchWindowPhotos() {
        let idx = currentIndex()
        let hi = min(order.count - 1, idx + 2)
        guard hi >= idx else { return }
        for i in idx...hi {
            let id = order[i]
            if let post = catalog[id] {
                FeedPhotoBox.shared.ensure(post)
            }
        }
    }

    private func updateRefreshMark() {
        let pull = currentIndex() == 0 ? -scroller.contentOffset.y : 0
        refreshHost?.view.alpha = refreshing ? 1 : min(1, max(0, (pull - 18) / 50))
        layoutRefreshMark()
    }

    private func layoutRefreshMark() {
        guard let mark = refreshHost?.view else { return }
        view.bringSubviewToFront(mark)
        mark.frame = CGRect(x: 0, y: 92, width: view.bounds.width, height: 56)
    }

    private func beginRefresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshHost?.view.alpha = 1
        layoutRefreshMark()
        scroller.setContentOffset(.zero, animated: false)
        let action = coordinator?.onRefresh
        Task { @MainActor in
            await action?()
            self.scroller.setContentOffset(.zero, animated: false)
            self.refreshing = false
            UIView.animate(withDuration: 0.12) {
                self.refreshHost?.view.alpha = 0
            }
            self.coordinator?.settle()
        }
    }
}

private struct FeedPageView: View {
    let post: FeedPost
    let save: SaveItem?
    let articleSaved: Bool
    var onWhy: (UUID) -> Void
    var onAsk: (UUID) -> Void
    var onOpen: (UUID) -> Void
    var onMute: () -> Void

    var body: some View {
        FeedCard(
            post: post,
            save: save,
            articleSaved: articleSaved,
            onWhy: onWhy,
            onAsk: onAsk,
            onOpen: onOpen,
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
