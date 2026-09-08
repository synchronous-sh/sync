import SwiftUI
import SwiftData
import AVFoundation
import UIKit
import Combine

private enum ScreenSafe {
    static var top: CGFloat { inset.top }
    static var bottom: CGFloat { inset.bottom }

    private static var inset: UIEdgeInsets {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        let value = window?.safeAreaInsets ?? .zero
        return UIEdgeInsets(
            top: max(value.top, 20),
            left: value.left,
            bottom: max(value.bottom, 16),
            right: value.right
        )
    }
}

struct ForYouView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @State private var posts: [FeedPost] = FeedStore.load()
    @State private var loading = false
    @State private var refreshing = false
    @State private var bootstrapped = false
    @State private var loadingMore = false
    @State private var nextMix: [FeedPost] = []
    @State private var mixing = false
    @State private var message = ""
    @State private var currentID: UUID?
    @State private var feedJump = 0
    @StateObject private var revealBox = FeedRevealBox()
    @StateObject private var speaker = FeedSpeaker()

    @State private var whySave: SaveJump?
    @State private var askPost: FeedPost?
    @State private var openStory: FeedPost?
    @State private var showVoice = false
    @State private var searchDraft = ""
    @FocusState private var searchFocused: Bool
    @State private var searching = false
    @State private var searchError = ""
    @State private var showingCoach = false
    @State private var category = "For You"
    static var categoryCache: [String: [FeedPost]] = [:]
    private static var categoryInflight: Set<String> = []
    @AppStorage(CoachTour.fypCompletedKey) private var completedFYPCoach = false
    @AppStorage(CoachTour.fypRestartKey) private var restartFYPCoach = false

    var body: some View {
        Group {
            if posts.isEmpty && !loading {
                empty
            } else {
                feed
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background { KeyboardLiftLock() }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay(alignment: .top) {
            PinChromeTop {
                videoChrome
            }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
        }
        .ignoresSafeArea(edges: .top)
        .ignoresSafeArea(.keyboard)
        .coachTour(CoachTour.fyp, isPresented: $showingCoach, onFinished: {
            completedFYPCoach = true
        })
        .sheet(isPresented: $showVoice, onDismiss: {
            speaker.applyVoice()
        }) {
            NavigationStack {
                FeedVoicePicker {
                    speaker.applyVoice()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $askPost) { post in
            FeedAskSheet(post: post, save: saves.first(where: { $0.saveID == post.saveID }))
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
                .presentationBackground(SyncTheme.paper)
                .onAppear { if !speaker.isPaused { speaker.togglePause() } }
        }
        .navigationDestination(item: $whySave) { jump in
            if let save = saves.first(where: { $0.saveID == jump.id }) {
                SaveDetailView(save: save)
            }
        }
        .navigationDestination(item: $openStory) { post in
            StoryDetailView(post: post)
        }
        .onAppear {
            if openStory != nil || whySave != nil { return }
            FYPStatusBar.install()
            FYPStatusBar.wantsLightContent = true
            startFYPCoachIfNeeded()
            if currentID == nil { currentID = posts.first?.id }
            if let id = currentID, let post = posts.first(where: { $0.id == id }) {
                speakCard(post)
                FeedPhotoBox.shared.ensure(post)
                prefetchImages(around: id)
                speaker.prefetch(nearbyPosts(around: id))
            }
        }
        .onDisappear {
            if showVoice || searchFocused || askPost != nil || openStory != nil { return }
            FYPStatusBar.wantsLightContent = false
            speaker.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedVoiceDidChange)) { _ in
            speaker.applyVoice()
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedSpeechSpeedDidChange)) { _ in
            speaker.applySpeed()
        }
        .onChange(of: openStory) { _, story in
            if story == nil, let id = currentID, let post = posts.first(where: { $0.id == id }) {
                speakCard(post)
            }
        }
        .task {
            if bootstrapped { return }
            bootstrapped = true
            // #region agent log
            let t0 = CFAbsoluteTimeGetCurrent()
            AgentDebug.log("A", "ForYouView.swift:task", "fyp_task_start", ["stored": FeedStore.load().count])
            // #endregion
            TasteEngine.ingest(Array(saves))
            AppWarmup.start(saves: Array(saves))
            var all = FeedStore.load()
            if all.isEmpty {
                all = await FeedStudio.fill(from: saves, count: 12, replace: false)
            }
            posts = all
            // #region agent log
            AgentDebug.log("A", "ForYouView.swift:task", "fyp_first_paint", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000), "count": all.count])
            // #endregion
            if !all.isEmpty { Self.categoryCache["For You"] = all }
            if currentID == nil || !(posts.contains { $0.id == currentID }) {
                currentID = posts.first?.id
            }
            if let id = currentID {
                if let post = posts.first(where: { $0.id == id }) {
                    FeedPhotoBox.shared.ensure(post)
                }
                prefetchImages(around: id)
            }
            if posts.isEmpty {
                await openFreshMix()
            }
            prefetchNearbyCategories()
            Task {
                await FeedStudio.ensureBriefings(Array(all.prefix(8)))
            }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                await loadMore()
            }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                await prefetchNextMix()
            }
        }
        .onChange(of: restartFYPCoach) { _, on in
            if on { startFYPCoachIfNeeded() }
        }
        .onChange(of: category) { _, next in
            Task { await showCategory(next) }
        }
    }

    private func startFYPCoachIfNeeded() {
        guard restartFYPCoach || (!completedFYPCoach && !showingCoach) else { return }
        let replay = restartFYPCoach
        restartFYPCoach = false
        Task { @MainActor in
            if replay { try? await Task.sleep(for: .milliseconds(250)) }
            showingCoach = true
        }
    }

    private var videoChrome: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if loading || refreshing {
                    SparkleThinking(label: "", iconSize: 32, inverted: true, brandIcon: true)
                        .frame(width: 32, height: 32)
                        .accessibilityLabel("Loading")
                } else {
                    chromeButton("arrow.clockwise", "Reload") {
                        searchError = ""
                        Task {
                            if category == "For You" {
                                await refresh()
                            } else {
                                await showCategory(category, force: true)
                            }
                        }
                    }
                    .coachSpot(.fypRefresh)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await searchTopic(replace: true) }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search")
                    TextField(
                        "",
                        text: $searchDraft,
                        prompt: Text("Ask for stories").foregroundStyle(Color.white.opacity(0.72))
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .done : .search)
                        .onSubmit {
                            if searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                searchFocused = false
                            } else {
                                Task { await searchTopic(replace: true) }
                            }
                        }
                    Color.clear
                        .frame(width: 18, height: 18)
                        .overlay {
                            if searching {
                                SparkleThinking(label: "", iconSize: 13, inverted: true)
                            } else if !searchDraft.isEmpty {
                                Button {
                                    searchDraft = ""
                                    searchError = ""
                                    Task { await showCategory(category) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                            }
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
                .colorScheme(.dark)
                .coachSpot(.fypSearch)
                chromeButton("waveform", "Voice") { showVoice = true }
                    .coachSpot(.fypVoice)
                chromeButton(speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", speaker.isMuted ? "Unmute" : "Mute") {
                    speaker.toggleMute()
                }
                .coachSpot(.fypMute)
            }
            .padding(.horizontal, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(NewsCategories.feed, id: \.self) { item in
                        Button {
                            guard category != item else { return }
                            category = item
                        } label: {
                            VStack(spacing: 4) {
                                Text(item)
                                    .font(.system(size: 14, weight: category == item ? .bold : .semibold))
                                    .foregroundStyle(category == item ? Color.white : Color.white.opacity(0.58))
                                Capsule()
                                    .fill(category == item ? Color.white : Color.clear)
                                    .frame(width: 22, height: 2)
                            }
                            .frame(height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            if !searchError.isEmpty {
                Text(searchError)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, ScreenSafe.top + 6)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .animation(nil, value: searchFocused)
    }

    private func chromeButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }

    private var empty: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A feed from what you save.")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text(hint)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))

                Button("Make posts") {
                    Task { await refresh() }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(loading)
            }
            .padding(24)
            .padding(.top, 120)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var hint: String {
        if saves.isEmpty { return message.isEmpty ? "A mix of stories to start. Save a few things and this feed will follow you." : message }
        return message.isEmpty ? "We’ll pull live headlines for the people and topics in your library, then write new briefings — not recaps of your saves." : message
    }

    private var feed: some View {
        VerticalFeedPager(
            posts: posts,
            saveFor: { post in saves.first(where: { $0.saveID == post.saveID }) },
            articleSaved: { post in
                let raw = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return false }
                let canon = SourceAdapter.canonicalize(raw)
                return saves.contains {
                    (!canon.isEmpty && $0.canonicalURL == canon) || $0.sourceURL == raw
                }
            },
            currentID: $currentID,
            onWhy: { whySave = SaveJump(id: $0) },
            onAsk: { id in askPost = posts.first(where: { $0.id == id }) },
            onOpen: { id in
                speaker.stop()
                if let stored = FeedStore.load().first(where: { $0.id == id }),
                   !FeedStudio.isPlaceholder(stored) {
                    openStory = stored
                } else {
                    openStory = posts.first(where: { $0.id == id })
                }
            },
            onMute: { speaker.toggleMute() },
            onNeedMore: { Task { await loadMore() } },
            onRefresh: { await refresh() },
            scrollNonce: feedJump,
            reveal: revealBox.post,
            darkCanvas: true
        )
        .equatable()
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .onChange(of: currentID) { _, id in
            if openStory != nil { return }
            guard let id, let post = posts.first(where: { $0.id == id }) else { return }
            // #region agent log
            AgentDebug.log("C", "ForYouView.swift:currentID", "page", [
                "id": id.uuidString,
                "idx": posts.firstIndex(where: { $0.id == id }) ?? -1
            ])
            // #endregion
            speakCard(post)
            prefetchImages(around: id)
            Task { await expandNearby(around: id) }
        }
        .onChange(of: posts.count) { _, _ in
            if let id = currentID { prefetchImages(around: id) }
        }
    }

    private func showCategory(_ name: String, force: Bool = false) async {
        searching = false
        searchError = ""
        let t0 = CFAbsoluteTimeGetCurrent()
        if !force, let cached = Self.categoryCache[name], !cached.isEmpty {
            applyCategoryPosts(cached)
            // #region agent log
            AgentDebug.log("B", "ForYouView.showCategory", "memory", [
                "name": name,
                "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
                "n": cached.count
            ])
            // #endregion
            if let id = cached.first?.id {
                Task { await expandNearby(around: id) }
            }
            prefetchNearbyCategories()
            return
        }
        await loadCategory(name, force: force)
        prefetchNearbyCategories()
    }

    private func applyCategoryPosts(_ next: [FeedPost]) {
        posts = next
        currentID = next.first?.id
        feedJump += 1
        if let first = next.first {
            FeedPhotoBox.shared.ensure(first)
            speakCard(first)
            prefetchImages(around: first.id)
            Task { await FeedStudio.ensureBriefings(Array(next.prefix(8))) { adoptBriefing($0) } }
        }
    }

    private func prefetchNearbyCategories() {
        let others = Array(NewsCategories.feed.filter { $0 != category }.prefix(2))
        for name in others {
            guard Self.categoryCache[name] == nil, !Self.categoryInflight.contains(name) else { continue }
            Self.categoryInflight.insert(name)
            Task(priority: .utility) {
                let found = await fetchCategoryPosts(name)
                if !found.isEmpty {
                    Self.categoryCache[name] = found
                    FeedImageCache.prefetch(Array(found.prefix(2)))
                }
                Self.categoryInflight.remove(name)
            }
        }
    }

    private func openFreshMix() async {
        if category != "For You" {
            await showCategory(category, force: true)
            return
        }
        loading = true
        message = ""
        var batch: [FeedPost] = []
        let next = await FeedStudio.fill(from: saves, count: 12, replace: true, resetSeen: false) { post in
            batch.append(post)
            posts = batch
            if batch.count == 1 {
                currentID = post.id
                feedJump += 1
                speakCard(post)
                speaker.prefetch([post])
                FeedPhotoBox.shared.ensure(post)
            }
            if let id = currentID {
                prefetchImages(around: id)
            }
        }
        if posts.isEmpty { posts = next }
        loading = false
        if !posts.isEmpty {
            Self.categoryCache["For You"] = posts
            Task { await loadMore() }
            if let id = currentID ?? posts.first?.id {
                Task { await expandNearby(around: id) }
            }
        }
    }

    private func fetchCategoryPosts(_ name: String) async -> [FeedPost] {
        if name == "For You" {
            let stored = FeedStore.load()
            return stored.isEmpty ? await FeedStudio.fill(from: saves, count: 12, replace: false) : stored
        }
        return await FeedStudio.posts(forCategory: name, count: 10)
    }

    private func loadCategory(_ name: String? = nil, force: Bool = false) async {
        let target = name ?? category
        if !force, let cached = Self.categoryCache[target], !cached.isEmpty {
            if category == target { applyCategoryPosts(cached) }
            return
        }
        if target == "For You" {
            await refresh()
            if !posts.isEmpty { Self.categoryCache["For You"] = posts }
            return
        }
        message = ""
        speaker.stop()
        let t0 = CFAbsoluteTimeGetCurrent()
        loading = Self.categoryCache[target] == nil
        let found = await FeedStudio.posts(forCategory: target, count: 10)
        Self.categoryCache[target] = found
        // #region agent log
        AgentDebug.log("B", "ForYouView.loadCategory", "done", [
            "name": target,
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "n": found.count
        ])
        // #endregion
        if category == target {
            loading = false
            if found.isEmpty {
                message = "No fresh headlines for \(target) yet."
            } else {
                applyCategoryPosts(found)
            }
            if let id = found.first?.id {
                Task { await expandNearby(around: id) }
            }
        }
        loading = false
    }

    private func applyInstantFeed(_ next: [FeedPost]) {
        guard !next.isEmpty else { return }
        posts = next
        currentID = next.first?.id
        feedJump += 1
        Self.categoryCache[category] = next
        if let first = next.first {
            FeedPhotoBox.shared.ensure(first)
            speakCard(first)
            prefetchImages(around: first.id)
            speaker.prefetch(Array(next.prefix(3)))
        }
    }

    private func consumeFreshStack() -> [FeedPost]? {
        let current = Set(posts.prefix(1).map(\.id))
        let buffered = nextMix.filter { !current.contains($0.id) }
        if buffered.count >= 2 {
            nextMix = []
            return buffered
        }
        let idx = currentID.flatMap { id in posts.firstIndex(where: { $0.id == id }) } ?? 0
        let rest = Array(posts.dropFirst(idx + 1))
        if rest.count >= 2 {
            return rest
        }
        if !buffered.isEmpty { nextMix = []; return buffered }
        if rest.count == 1 { return rest }
        return nil
    }

    private func prefetchNextMix() async {
        guard !mixing, category == "For You" else { return }
        mixing = true
        defer { mixing = false }
        let have = Set(posts.map(\.id) + nextMix.map(\.id))
        _ = await FeedStudio.fill(from: saves, count: 8, replace: false)
        let extra = FeedStore.load().filter { !have.contains($0.id) }
        if extra.count >= 2 {
            nextMix = Array(extra.prefix(12))
            FeedImageCache.prefetch(Array(nextMix.prefix(4)))
        }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        // #region agent log
        let t0 = CFAbsoluteTimeGetCurrent()
        AgentDebug.log("A", "ForYouView.swift:refresh", "refresh_start", ["posts": posts.count, "mix": nextMix.count])
        // #endregion
        message = ""
        speaker.stop()
        if let fresh = consumeFreshStack() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            applyInstantFeed(fresh)
            // #region agent log
            AgentDebug.log("A", "ForYouView.swift:refresh", "refresh_instant", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000), "n": fresh.count])
            // #endregion
            Task { await prefetchNextMix() }
            if let id = currentID {
                Task { await expandNearby(around: id) }
            }
            return
        }
        var first = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            func finish() {
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            Task { @MainActor in
                _ = await FeedStudio.fill(from: saves, count: 8, replace: false, skipHistory: false) { post in
                    if first {
                        first = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        applyInstantFeed([post] + posts.filter { $0.id != post.id })
                        finish()
                    }
                }
                Task { await prefetchNextMix() }
                if let id = currentID {
                    Task { await expandNearby(around: id) }
                }
                AgentDebug.log("A", "ForYouView.swift:refresh", "refresh_fill_done", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)])
                finish()
            }
        }
    }

    private var canSearch: Bool {
        searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && !searching
    }

    private func searchTopic(replace: Bool = false) async {
        let q = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !searching else { return }
        searching = true
        loading = true
        searchError = ""
        message = ""
        speaker.stop()
        if replace {
            posts = []
            currentID = nil
        }
        var batch: [FeedPost] = []
        let found = await FeedStudio.search(q, count: 8) { post in
            batch.append(post)
            posts = replace ? batch : batch + posts.filter { existing in
                !batch.contains { FeedStore.isSameStory($0.headline, existing.headline) }
            }
            if batch.count == 1 {
                currentID = post.id
                feedJump += 1
                speaker.speak(post)
                searchFocused = false
            }
            prefetchImages(around: post.id)
        }
        if !found.isEmpty {
            posts = replace ? found : found + posts.filter { existing in
                !found.contains { FeedStore.isSameStory($0.headline, existing.headline) }
            }
            currentID = found.first?.id
            feedJump += 1
            if let first = found.first {
                speaker.speak(first)
                speaker.prefetch(Array(found.prefix(3)))
            }
            searchFocused = false
            if let id = found.first?.id {
                Task { await expandNearby(around: id) }
            }
        } else {
            searchError = "Nothing matched that. Try naming a person, company, or what you want to understand."
        }
        searching = false
        loading = false
    }

    private func speakCard(_ post: FeedPost) {
        if revealBox.post?.id == post.id, speaker.playingThis(post.id) {
            return
        }
        var spoken = post
        if revealBox.post?.id != post.id,
           let stored = FeedStore.load().first(where: { $0.id == post.id }),
           !FeedStudio.needsBriefing(stored) {
            spoken = stored
        }
        revealBox.post = spoken
        speaker.speak(spoken)
    }

    private func nearbyPosts(around id: UUID) -> [FeedPost] {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return [] }
        let end = min(posts.count, index + 3)
        return Array(posts[index..<end])
    }

    private func adoptBriefing(_ next: FeedPost) {
        if next.id == currentID {
            // #region agent log
            AgentDebug.log("T", "ForYouView.swift:adoptBriefing", "skip_visible", [
                "id": next.id.uuidString,
                "ready": next.briefingReady
            ])
            // #endregion
            return
        }
        // #region agent log
        AgentDebug.log("T", "ForYouView.swift:adoptBriefing", "apply_ahead", [
            "id": next.id.uuidString,
            "len": next.script.count
        ])
        // #endregion
        if let i = posts.firstIndex(where: { $0.id == next.id }) {
            posts[i] = next
        }
        if var cached = Self.categoryCache[category],
           let i = cached.firstIndex(where: { $0.id == next.id }) {
            cached[i] = next
            Self.categoryCache[category] = cached
        }
    }

    private func expandNearby(around id: UUID) async {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        let start = max(0, index)
        let end = min(posts.count, index + 8)
        guard start < end else { return }
        let slice = Array(posts[start..<end])
        let t0 = CFAbsoluteTimeGetCurrent()
        // #region agent log
        AgentDebug.log("T", "ForYouView.swift:expandNearby", "prefetch", [
            "from": start,
            "to": end,
            "n": slice.count
        ])
        // #endregion
        await FeedStudio.ensureBriefings(slice) { adoptBriefing($0) }
        // #region agent log
        AgentDebug.log("C", "ForYouView.swift:expandNearby", "done", [
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "n": slice.count
        ])
        // #endregion
        let stored = FeedStore.load()
        for i in start..<end where i < posts.count {
            if let next = stored.first(where: { $0.id == posts[i].id }),
               next.script != posts[i].script || next.briefingReady != posts[i].briefingReady {
                adoptBriefing(next)
            }
        }
    }

    private func prefetchImages(around id: UUID) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        let end = min(posts.count, index + 4)
        FeedImageCache.prefetch(Array(posts[index..<end]))
    }

    private func loadMore() async {
        guard openStory == nil, whySave == nil else { return }
        guard !loadingMore else { return }
        let index = currentID.flatMap { id in posts.firstIndex(where: { $0.id == id }) } ?? 0
        if posts.count - index >= 8 { return }
        loadingMore = true
        defer { loadingMore = false }
        let t0 = CFAbsoluteTimeGetCurrent()
        let beforeIDs = Set(posts.map(\.id))
        _ = await FeedStudio.fill(from: saves, count: 6)
        let added = FeedStore.load().filter { !beforeIDs.contains($0.id) }
        // #region agent log
        AgentDebug.log("C", "ForYouView.swift:loadMore", "done", [
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "added": added.count,
            "idx": index,
            "n": posts.count
        ])
        // #endregion
        if !added.isEmpty {
            posts.append(contentsOf: added)
        }
        if currentID == nil { currentID = posts.first?.id }
    }
}

@MainActor
final class FeedSpeaker: ObservableObject {
    @Published var isMuted = false
    @Published var isPaused = false
    var isPlaying = false
    private var player: AVPlayer?
    private let synth = AVSpeechSynthesizer()
    var playingID: UUID?

    private var lastPost: FeedPost?
    private var lastFull = false
    private var job = UUID()
    private var spokenVoice = ""

    func playingThis(_ id: UUID) -> Bool {
        playingID == id
    }

    func speak(_ post: FeedPost, force: Bool = false, full: Bool = false) {
        let voice = ElevenLabsSpeech.voiceID
        if !force, playingID == post.id, spokenVoice == voice, lastFull == full, player != nil || synth.isSpeaking { return }
        // #region agent log
        AgentDebug.log("F", "ForYouView.swift:speak", "speak_start", ["id": post.id.uuidString])
        // #endregion
        stop()
        playingID = post.id
        lastPost = post
        lastFull = full
        spokenVoice = voice
        if isPaused { isPaused = false }
        Self.activateAudio()
        startAudio(post, voice: voice, skipCache: force, full: full)
    }

    func speakRaw(_ text: String, id: UUID, force: Bool = false) {
        speak(
            FeedPost(
                id: id,
                saveID: id,
                title: "",
                script: text,
                headline: "",
                headlineURL: "",
                audioFileName: "",
                imageFileName: "",
                sourceName: "",
                interest: "",
                createdAt: .now
            ),
            force: force,
            full: true
        )
    }

    func toggleReadAloud(_ post: FeedPost) {
        if lastPost?.id == post.id, lastFull, player != nil || isPaused || synth.isSpeaking || synth.isPaused {
            togglePause()
            return
        }
        speak(post, full: true)
    }

    private static var audioReady = false
    private static func activateAudio() {
        guard !audioReady else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        audioReady = true
    }

    func prefetch(_ posts: [FeedPost]) {
        let voice = ElevenLabsSpeech.voiceID
        guard ElevenLabsKey.isConfigured else { return }
        for post in posts.prefix(1) where !post.cardBlurb.isEmpty {
            if ElevenLabsSpeech.cachedURL(id: post.id, voice: voice, text: post.cardBlurb) != nil { continue }
            Task {
                _ = await ElevenLabsSpeech.speak(post.cardBlurb, id: post.id, voice: voice)
            }
        }
    }

    func togglePause() {
        guard let post = lastPost else { return }
        if playingID == nil {
            speak(post)
            return
        }
        if isPaused {
            isPaused = false
            isPlaying = true
            applyMute()
            player?.rate = FeedSpeechSpeed.current
            player?.play()
            synth.continueSpeaking()
        } else {
            player?.pause()
            player?.rate = 0
            if synth.isSpeaking || synth.isPaused {
                synth.pauseSpeaking(at: .immediate)
            }
            isPaused = true
            isPlaying = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        applyMute()
        if isMuted {
            player?.pause()
            if synth.isSpeaking { synth.pauseSpeaking(at: .immediate) }
        } else if !isPaused {
            if player != nil {
                player?.rate = FeedSpeechSpeed.current
                player?.play()
            } else if let post = lastPost {
                startAudio(post, voice: ElevenLabsSpeech.voiceID, full: lastFull)
            }
            synth.continueSpeaking()
        }
    }

    private func applyMute() {
        player?.volume = isMuted ? 0 : 1
    }

    private func startAudio(_ post: FeedPost, voice: String, skipCache: Bool = false, full: Bool = false) {
        let spoken = full ? FeedSpeaker.summarySpeech(post.script) : post.cardBlurb
        guard !isMuted, !spoken.isEmpty else { return }
        let token = UUID()
        job = token
        if ElevenLabsKey.isConfigured {
            if !skipCache, let url = ElevenLabsSpeech.cachedURL(id: post.id, voice: voice, text: spoken) {
                play(url)
                return
            }
            Task { @MainActor in
                let file = await ElevenLabsSpeech.speak(spoken, id: post.id, voice: voice, skipCache: skipCache)
                guard job == token, playingID == post.id, !isMuted else { return }
                if let file, let url = MediaStore.fileURL(file) {
                    play(url)
                }
            }
            return
        }
        speakSystem(spoken)
    }

    private func play(_ url: URL) {
        player?.pause()
        let next = AVPlayer(url: url)
        next.automaticallyWaitsToMinimizeStalling = true
        next.volume = isMuted ? 0 : 1
        player = next
        if !isPlaying { isPlaying = true }
        if !isPaused {
            next.play()
            next.rate = FeedSpeechSpeed.current
        }
    }

    private func speakSystem(_ text: String) {
        let line = AVSpeechUtterance(string: ElevenLabsSpeech.spokenText(text))
        line.voice = FeedVoice.systemCurrent()
        line.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92 * FeedSpeechSpeed.current
        isPlaying = true
        synth.speak(line)
    }

    func applyVoice() {
        guard let post = lastPost else { return }
        speak(post, force: true, full: lastFull)
    }

    func applySpeed() {
        guard !isPaused, player != nil else { return }
        player?.rate = FeedSpeechSpeed.current
    }

    func stop() {
        job = UUID()
        player?.pause()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        playingID = nil
        spokenVoice = ""
        isPaused = false
        isPlaying = false
    }

    static func summarySpeech(_ script: String) -> String {
        ElevenLabsSpeech.spokenText(
            script
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\n- ", with: ". ")
                .replacingOccurrences(of: "\n• ", with: ". ")
                .replacingOccurrences(of: "\n* ", with: ". ")
        )
    }
}

struct SaveJump: Identifiable, Hashable {
    let id: UUID
}

struct FeedCard: View {
    let post: FeedPost
    let save: SaveItem?
    var articleSaved = false
    var onWhy: ((UUID) -> Void)? = nil
    var onAsk: ((UUID) -> Void)? = nil
    var onOpen: ((UUID) -> Void)? = nil
    var onMute: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var photos = FeedPhotoBox.shared
    @State private var remote: UIImage?
    @State private var confirmingUnsave = false
    @State private var savedHere = false
    @State private var savedID: UUID?
    @State private var showMore = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                photo(in: geo.size.width, height: geo.size.height)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)
                if !photoReady {
                    SparkleThinking(label: "", iconSize: 96, inverted: true, brandIcon: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Loading image")
                }

                Color.clear
                    .frame(width: min(220, geo.size.width * 0.52), height: min(280, geo.size.height * 0.38))
                    .contentShape(Rectangle())
                    .onTapGesture { onMute?() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.trailing, 56)
                    .padding(.bottom, 90)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(post.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 5)
                            .lineLimit(2)
                        Text(post.cardBlurb)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black, radius: 4)
                            .lineLimit(3)
                        Text(publisher)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.62))
                            .shadow(color: .black, radius: 4)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)

                    chromeActions
                }
                .padding(.leading, 18)
                .padding(.trailing, 9)
                .padding(.bottom, ScreenSafe.bottom + 64)
            }
        }
        .background(Color.black)
        .sheet(isPresented: $showMore) {
            FeedMoreSheet(post: post, onAsk: { onAsk?(post.id) }, onWhy: { if let save { onWhy?(save.saveID) } })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
        }
        .confirmationDialog("Remove from library?", isPresented: $confirmingUnsave, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { unsaveNews() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This save will be deleted.")
        }
        .onAppear {
            syncChrome()
            FeedPhotoBox.shared.ensure(post)
        }
        .task(id: post.id) {
            savedHere = false
            savedID = nil
            syncChrome()
            FeedPhotoBox.shared.ensure(post)
        }
    }

    private var chromeActions: some View {
        VStack(spacing: 7) {
            feedAction(isSaved ? "bookmark.fill" : "bookmark", isSaved ? "Remove from library" : "Save") {
                if isSaved { confirmingUnsave = true } else { saveNews() }
            }
            feedAction("sparkles", "Ask") {
                onAsk?(post.id)
            }
            feedAction("book", "Read news summary") {
                onOpen?(post.id)
            }
            feedAction("paperplane", "Share") {
                ArticleShare.share(post)
            }
            Button {
                showMore = true
            } label: {
                VStack(spacing: 5) {
                    Capsule().fill(.white.opacity(0.96)).frame(width: 23, height: 2)
                    Capsule().fill(.white.opacity(0.96)).frame(width: 14, height: 2)
                }
                .frame(width: 44, height: 35)
            }
            .accessibilityLabel("More options")
            .buttonStyle(.plain)

            Button {
                onOpen?(post.id)
            } label: {
                VStack(spacing: 3) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white)
                            .frame(width: 29, height: 29)
                        Text(String(publisher.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.black)
                    }
                    Text(publisher)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .frame(maxWidth: 47)
                }
                .frame(width: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(publisher) news summary")
        }
    }

    @ViewBuilder
    private func photo(in width: CGFloat, height: CGFloat) -> some View {
        FeedBackdrop(post: post)
            .frame(width: width, height: height)
            .clipped()
    }

    @ViewBuilder
    private func filledPhoto(_ image: UIImage, width: CGFloat, height: CGFloat) -> some View {
        let imageRatio = image.size.width / max(image.size.height, 1)
        let frameRatio = width / max(height, 1)
        let isWide = imageRatio > frameRatio + 0.04
        if isWide {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .blur(radius: 26)
                .opacity(0.42)
                .clipped()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
        }
    }

    private var publisher: String {
        let name = post.sourceName.isEmpty ? (post.interest.isEmpty ? "News" : post.interest) : post.sourceName
        return name.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    private var photoReady: Bool {
        _ = photos.generation
        let title = post.title.isEmpty ? post.headline : post.title
        let artID = FeedNews.photoID(url: post.headlineURL, title: title)
        let cache = FeedImageCache.image(for: artID) != nil || FeedImageCache.image(for: post.id) != nil
        let pack = StudioPack.image(for: artID) != nil
        // #region agent log
        if !cache {
            AgentDebug.log("E", "FeedCard.photoReady", "waiting", [
                "cache": cache,
                "pack": pack
            ])
        }
        // #endregion
        return cache
    }

    private var isSaved: Bool { articleSaved || savedHere }

    private func syncChrome() {}

    private func feedAction(_ symbol: String, _ label: String, count: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                if let count {
                    Text(count)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 44, minHeight: 43)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func saveNews() {
        guard !isSaved else { return }
        let briefing = post.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CaptureService.ingest(
            urlString: url.isEmpty ? nil : url,
            text: briefing.isEmpty ? post.title : briefing,
            imageData: nil,
            context: modelContext
        )
        result.save.title = post.title
        result.save.summary = briefing
        if result.save.creatorName.isEmpty {
            result.save.creatorName = post.sourceName
        }
        if result.save.topicsCSV.isEmpty, !post.interest.isEmpty {
            result.save.topicsCSV = post.interest
        }
        if result.save.imageFileName.isEmpty,
           let image = FeedImageCache.image(for: post.id) ?? remote,
           let data = image.jpegData(compressionQuality: 0.85) {
            result.save.imageFileName = MediaStore.save(data, id: result.save.saveID)
        }
        try? modelContext.save()
        savedID = result.save.saveID
        savedHere = true
        LibraryBrain.pull(context: modelContext, reread: result.save)
    }

    private func unsaveNews() {
        let raw = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let canon = SourceAdapter.canonicalize(raw)
        let items = (try? modelContext.fetch(FetchDescriptor<SaveItem>())) ?? []
        if let item = items.first(where: { save in
            save.saveID == savedID
                || (!canon.isEmpty && save.canonicalURL == canon)
                || save.sourceURL == raw
        }) {
            modelContext.delete(item)
            try? modelContext.save()
        }
        savedHere = false
        savedID = nil
    }
}

private struct FeedMoreSheet: View {
    let post: FeedPost
    var onAsk: () -> Void
    var onWhy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("About this video")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text(post.cardBlurb)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            moreRow("sparkles", "Ask") { dismiss(); onAsk() }
            moreRow("bookmark", "Why this") { dismiss(); onWhy() }
            moreRow("arrow.up.right", "Open original") {
                dismiss()
                if let url = URL(string: post.headlineURL), !post.headlineURL.isEmpty {
                    if !OutboundLink.open(url) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    private func moreRow(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

struct StoryDetailView: View {
    @State private var post: FeedPost
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Query(sort: \CollectionItem.name) private var collections: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @StateObject private var reader = FeedSpeaker()
    @State private var showingAsk = false
    @State private var showingSaveSheet = false
    @State private var confirmingUnsave = false
    @State private var picture: UIImage?
    @State private var savedHere = false
    @State private var savedID: UUID?
    @State private var hasAskThread = false
    @State private var page: InAppPage?


    init(post: FeedPost) {
        _post = State(initialValue: post)
        let fromPost = FeedImageCache.image(for: post.id)
        let fromArticle = FeedImageCache.image(for: FeedNews.photoID(url: post.headlineURL, title: post.title))
        _picture = State(initialValue: fromPost ?? fromArticle)
    }

    private var relatedSave: SaveItem? {
        saves.first(where: { $0.saveID == post.saveID })
    }

    private var savedArticle: SaveItem? {
        let raw = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let canon = SourceAdapter.canonicalize(raw)
        return saves.first { item in
            (!canon.isEmpty && item.canonicalURL == canon) || item.sourceURL == raw
        }
    }

    private var storedSave: SaveItem? {
        if let savedArticle { return savedArticle }
        if let savedID { return saves.first { $0.saveID == savedID } }
        return nil
    }

    private var isSaved: Bool { storedSave != nil || savedHere }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Text(post.sourceName.isEmpty ? "Story" : post.sourceName)
                    Text("·")
                    Text(FeedNews.dateLine(post.publishedAt))
                    if !post.interest.isEmpty {
                        Text("·")
                        Text(post.interest)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SyncTheme.inkMuted)

                Text(post.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !post.script.isEmpty {
                    SaveSummaryBlock(text: post.script)
                }

                if let url = URL(string: post.headlineURL), !post.headlineURL.isEmpty {
                    Button {
                        if !OutboundLink.open(url) {
                            page = InAppPage(id: url)
                        }
                    } label: {
                        storyActionRow(title: "Open original", symbol: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                }

                if let save = relatedSave {
                    NavigationLink {
                        SaveDetailView(save: save)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("From your library")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SyncTheme.inkMuted)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Text(save.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SyncTheme.ink)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SyncTheme.highlight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .padding(.bottom, 8)
        }
        .syncPullToRefresh(caption: "Fetching story") {
            var current = FeedStore.load().first(where: { $0.id == post.id }) ?? post
            current.briefingReady = false
            post = await FeedStudio.ensureBriefing(current)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .onAppear {
            hasAskThread = !SaveChatStore.load(saveID: post.id).isEmpty
        }
        .onDisappear { reader.stop() }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: post.id) {
            await loadPicture()
            await fillSummary()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                showingAsk = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask about this story")
                            .font(.system(size: 16, weight: .medium))
                        if hasAskThread {
                            Text("Continue the thread")
                                .font(.system(size: 12))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .foregroundStyle(SyncTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SyncTheme.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(SyncTheme.paper.opacity(0.92))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(alignment: .center, spacing: 0) {
                    NavIconButton(accessibility: reader.isPlaying ? "Pause" : "Read aloud") {
                        reader.toggleReadAloud(post)
                    } label: {
                        Image(systemName: reader.isPlaying ? "pause.fill" : "speaker.wave.2")
                    }
                    NavIconButton(accessibility: isSaved ? "Remove from library" : "Save to library") {
                        if isSaved {
                            confirmingUnsave = true
                        } else {
                            showingSaveSheet = true
                        }
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    }
                    NavIconButton(accessibility: "Share") {
                        ArticleShare.share(post)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    NavIconButton(accessibility: "Ask about this story") {
                        showingAsk = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }
            }
        }
        .sheet(item: $page) { page in
            SafariTab(url: page.url)
                .ignoresSafeArea()
        }
        .confirmationDialog("Remove from library?", isPresented: $confirmingUnsave, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { unsaveNews() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This save will be deleted.")
        }
        .sheet(isPresented: $showingSaveSheet) {
            NewsSaveSheet(collections: collections) { note, collectionName in
                saveNews(note: note, collectionName: collectionName)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
        .sheet(isPresented: $showingAsk) {
            FeedAskSheet(post: post, save: relatedSave)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SyncTheme.paper)
        }
    }

    private func storyActionRow(title: String, symbol: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: symbol)
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(SyncTheme.ink)
        .padding(14)
        .background(SyncTheme.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SyncTheme.line, lineWidth: 1)
        )
    }

    private func saveNews(note: String, collectionName: String) {
        guard !isSaved else { return }
        let briefing = post.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CaptureService.ingest(
            urlString: url.isEmpty ? nil : url,
            text: briefing.isEmpty ? post.title : briefing,
            imageData: nil,
            context: modelContext
        )
        result.save.title = post.title
        result.save.summary = briefing
        if result.save.creatorName.isEmpty {
            result.save.creatorName = post.sourceName
        }
        if result.save.topicsCSV.isEmpty, !post.interest.isEmpty {
            result.save.topicsCSV = post.interest
        }
        if result.save.imageFileName.isEmpty, let data = picture?.jpegData(compressionQuality: 0.85) {
            result.save.imageFileName = MediaStore.save(data, id: result.save.saveID)
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            result.save.rawText = SaveNote.merging(trimmedNote, into: result.save.rawText)
        }
        let bag = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bag.isEmpty {
            if let existing = CollectionHousekeeping.match(bag, in: collections) {
                if !result.save.collections.contains(where: { $0.collectionID == existing.collectionID }) {
                    result.save.collections.append(existing)
                }
            } else {
                let created = CollectionItem(name: bag)
                modelContext.insert(created)
                result.save.collections.append(created)
            }
        }
        try? modelContext.save()
        savedID = result.save.saveID
        savedHere = true
        LibraryBrain.pull(context: modelContext, reread: result.save)
    }

    private func unsaveNews() {
        if let item = storedSave {
            modelContext.delete(item)
            try? modelContext.save()
        }
        savedHere = false
        savedID = nil
    }

    private func fillSummary() async {
        let stored = FeedStore.load().first(where: {
            $0.id == post.id || (!post.headlineURL.isEmpty && $0.headlineURL == post.headlineURL)
        })
        // #region agent log
        AgentDebug.log("A", "StoryDetailView.fillSummary", "enter", [
            "scriptLen": (stored ?? post).script.count,
            "ready": (stored ?? post).briefingReady,
            "placeholder": FeedStudio.isPlaceholder(stored ?? post),
            "echo": FeedStudio.echoesHeadline(stored ?? post)
        ])
        // #endregion
        if let stored {
            post = stored
            if !FeedStudio.isPlaceholder(stored) { return }
        }
        post = await FeedStudio.ensureBriefing(post)
        // #region agent log
        AgentDebug.log("A", "StoryDetailView.fillSummary", "exit", [
            "scriptLen": post.script.count,
            "ready": post.briefingReady,
            "placeholder": FeedStudio.isPlaceholder(post)
        ])
        // #endregion
    }

    private func loadPicture() async {
        if let image = await FeedNews.loadFastImage(for: post) {
            picture = image
        }
    }
}

struct NewsSaveSheet: View {
    let collections: [CollectionItem]
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var collectionName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Note and collection are optional. Leave them blank and sync will file this from the briefing.")
                        .font(.system(size: 15))
                        .foregroundStyle(SyncTheme.inkMuted)

                    TextField("A note for yourself", text: $note, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.ink)
                        .lineLimit(2...6)
                        .padding(14)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )

                    TextField("Collection name", text: $collectionName)
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.ink)
                        .padding(14)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )

                    if !listed.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(listed) { bag in
                                    Button(bag.name) { collectionName = bag.name }
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(SyncTheme.ink)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(SyncTheme.paperRaised)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(SyncTheme.line, lineWidth: 1))
                                }
                            }
                        }
                    }

                    Button {
                        onSave(note, collectionName)
                        dismiss()
                    } label: {
                        Text("Save to library")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SyncTheme.paper)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(SyncTheme.ink)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .navigationTitle("Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SyncTheme.inkMuted)
                }
            }
        }
    }

    private var listed: [CollectionItem] {
        collections.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct FeedAskSheet: View {
    let post: FeedPost
    let save: SaveItem?
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [SaveChatLine] = []
    @State private var draft = ""
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(post.title)
                            .font(.system(size: 18, weight: .semibold, design: .serif))
                            .foregroundStyle(SyncTheme.ink)
                            .padding(.top, 8)
                        if lines.isEmpty, !loading {
                            Text("Ask anything about this briefing.")
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                        ForEach(lines) { line in
                            if !line.text.isEmpty {
                                bubble(line)
                            }
                        }
                        if loading {
                            SparkleThinking()
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)

                HStack(alignment: .center, spacing: 8) {
                    TextField("Ask about this", text: $draft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...5)
                        .onSubmit { Task { await send() } }
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? SyncTheme.ink : SyncTheme.inkMuted)
                    }
                    .disabled(!canSend)
                }
                .padding(14)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SyncTheme.line, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .medium))
                        Text("Ask")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(SyncTheme.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    if !lines.isEmpty {
                        Button("Clear") {
                            lines = []
                            SaveChatStore.clear(saveID: post.id)
                        }
                        .foregroundStyle(SyncTheme.inkMuted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(SyncTheme.ink)
                }
            }
        }
        .onAppear {
            lines = SaveChatStore.load(saveID: post.id)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loading
    }

    private func bubble(_ line: SaveChatLine) -> some View {
        let mine = line.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            ChatMarkdown.Rich(raw: mine ? line.text : LibraryAsk.strippedHeading(line.text), color: mine ? SyncTheme.paper : SyncTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(mine ? SyncTheme.ink : SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func send() async {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        lines.append(SaveChatLine.user(q))
        SaveChatStore.write(saveID: post.id, lines: lines)
        lines.append(SaveChatLine.assistant(""))
        loading = true
        let history = lines.dropLast(2).suffix(12).map { ($0.role, $0.text) }
        let answer = await FeedAsk.reply(question: q, post: post, save: save, history: Array(history)) { text in
            loading = false
            if let i = lines.indices.last {
                lines[i].text = text
            }
        }
        if let i = lines.indices.last {
            lines[i].text = answer
        }
        SaveChatStore.write(saveID: post.id, lines: lines)
        loading = false
    }
}

enum FeedAsk {
    static func reply(
        question: String,
        post: FeedPost,
        save: SaveItem?,
        history: [(String, String)],
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> String {
        if !IntelligenceKey.isConfigured {
            return "Ask isn’t available right now."
        }
        let prior = history.suffix(10).map { role, text in
            "\(role == "user" ? "User" : "Assistant"): \(text)"
        }.joined(separator: "\n")
        let related: String
        if let save {
            related = """
            Related library save: \(save.title)
            Notes: \(save.summary.isEmpty ? String(save.rawText.prefix(1200)) : save.summary)
            """
        } else {
            related = "(none)"
        }
        let user = """
        \(prior.isEmpty ? "" : "Conversation so far:\n\(prior)\n\n")
        New question: \(question)

        BRIEFING TITLE: \(post.title)
        HEADLINE: \(post.headline.isEmpty ? post.title : post.headline)
        SOURCE: \(post.sourceName)
        URL: \(post.headlineURL)
        INTEREST: \(post.interest)
        SCRIPT:
        \(post.script)

        \(related)

        Answer from this briefing. If the related save helps, use it. Never start with a heading.
        """
        guard let text = await AnthropicLibrary.reply(
            system: "You answer questions about one news briefing in a personal feed. Stay on this story. Paragraph then bullets when listing. Never start with a title.",
            user: user,
            maxTokens: 700,
            onDelta: onDelta
        ) else {
            return "Couldn’t reach the model. Try again in a moment."
        }
        return LibraryAsk.strippedHeading(text)
    }
}

private struct KeyboardLiftLock: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LockController {
        LockController()
    }

    func updateUIViewController(_ vc: LockController, context: Context) {}

    final class LockController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardFrame),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardHide),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            stripHostingKeyboard()
        }

        @objc private func keyboardHide(_ note: Notification) {
            pin(0, note: note)
        }

        @objc private func keyboardFrame(_ note: Notification) {
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = view.window?.bounds ?? UIScreen.main.bounds
            pin(max(0, screen.maxY - frame.minY), note: note)
        }

        private func pin(_ keyboardHeight: CGFloat, note: Notification) {
            stripHostingKeyboard()
        }

        private func stripHostingKeyboard() {
            guard #available(iOS 16.4, *) else { return }
            var vc: UIViewController? = parent ?? self
            while let current = vc {
                if current.responds(to: Selector(("setSafeAreaRegions:"))) {
                    let raw = (current.value(forKey: "safeAreaRegions") as? UInt) ?? 3
                    current.setValue(raw & ~2, forKey: "safeAreaRegions")
                }
                vc = current.parent
            }
        }
    }
}

private struct PinChromeTop<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PinView {
        let view = PinView()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: AnyView(content))
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        context.coordinator.host = host
        view.host = host
        view.addSubview(host.view)
        return view
    }

    func updateUIView(_ uiView: PinView, context: Context) {
        context.coordinator.host?.rootView = AnyView(content)
        uiView.invalidateIntrinsicContentSize()
        uiView.setNeedsLayout()
    }

    final class Coordinator {
        var host: UIHostingController<AnyView>?
    }

    final class PinView: UIView {
        var host: UIHostingController<AnyView>?

        override var intrinsicContentSize: CGSize {
            let width = bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width
            let height = host?.view.sizeThatFits(
                CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
            ).height ?? 120
            return CGSize(width: UIView.noIntrinsicMetric, height: height)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(relayout),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(relayout),
                name: UIResponder.keyboardDidChangeFrameNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func relayout() {
            setNeedsLayout()
            layoutIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = host?.view.sizeThatFits(
                CGSize(width: bounds.width, height: UIView.layoutFittingExpandedSize.height)
            ).height ?? bounds.height
            host?.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(height, 1))
            transform = .identity
            let y = convert(CGPoint.zero, to: window).y
            if window != nil, abs(y) > 0.5 {
                transform = CGAffineTransform(translationX: 0, y: -y)
            }
        }
    }
}

