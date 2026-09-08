import SwiftUI
import SwiftData
import UIKit

enum NewsCategories {
    static let feed = ["For You", "U.S.", "World", "History", "Business", "Technology", "Science", "Entertainment", "Lifestyle", "Food", "Sports"]
    static let articles = ["Top", "U.S.", "World", "History", "Business", "Technology", "Science", "Entertainment", "Lifestyle", "Food", "Sports"]
}

enum NewsFeedCache {
    private static let diskKey = "news.tab.headlines.v3"
    private static let stampKey = "news.tab.fetchedAt.v3"
    private static let maxAge: TimeInterval = 20 * 60
    private static var memory: [String: [NewsHeadline]] = [:]
    private static var fetchedAt: [String: Date] = [:]
    private static var inflight: [String: Task<[NewsHeadline], Never>] = [:]
    private static var didHydrate = false

    static func stored(_ category: String) -> [NewsHeadline] {
        hydrate()
        return memory[category] ?? []
    }

    static func snapshot(_ category: String) -> [NewsHeadline] {
        hydrate()
        guard let at = fetchedAt[category], Date().timeIntervalSince(at) < maxAge else { return [] }
        return memory[category] ?? []
    }

    static func warm() {
        Task(priority: .utility) { await warmAll() }
    }

    static func warmAll() async {
        hydrate()
        for name in NewsCategories.articles {
            let items = await fetch(name, force: snapshot(name).isEmpty)
            guard !items.isEmpty else { continue }
            let pictured = await FeedNews.fillPhotos(Array(items.prefix(12)))
            if !pictured.isEmpty {
                memory[name] = pictured
                fetchedAt[name] = Date()
                persist()
            }
        }
    }

    static func fetch(_ category: String, force: Bool = false, skipAPI: Bool = false) async -> [NewsHeadline] {
        hydrate()
        if !force,
           let cached = memory[category], !cached.isEmpty,
           let at = fetchedAt[category],
           Date().timeIntervalSince(at) < maxAge {
            return cached
        }
        if !force, let existing = inflight[category] {
            return await existing.value
        }
        if force {
            let items = await FeedNews.browse(category: category, limit: 12, fresh: true, skipAPI: skipAPI)
            if !items.isEmpty {
                memory[category] = items
                fetchedAt[category] = Date()
                persist()
            }
            return items
        }
        let task = Task<[NewsHeadline], Never> {
            let items = await FeedNews.browse(category: category, limit: 12, fresh: false, skipAPI: skipAPI)
            if !items.isEmpty {
                memory[category] = items
                fetchedAt[category] = Date()
                persist()
            }
            return items
        }
        inflight[category] = task
        let items = await task.value
        inflight[category] = nil
        return items
    }

    private static func hydrate() {
        guard !didHydrate else { return }
        didHydrate = true
        guard let data = UserDefaults.standard.data(forKey: diskKey),
              let decoded = try? JSONDecoder().decode([String: [NewsHeadline]].self, from: data)
        else { return }
        memory = decoded
        if let stamps = UserDefaults.standard.dictionary(forKey: stampKey) as? [String: Double] {
            fetchedAt = stamps.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    private static func persist() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: diskKey)
        let stamps = fetchedAt.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(stamps, forKey: stampKey)
    }
}

struct NewsTabView: View {
    private let categories = NewsCategories.articles
    @State private var category = "Top"
    @State private var headlines: [NewsHeadline] = NewsFeedCache.stored("Top")
    @State private var loading = NewsFeedCache.stored("Top").isEmpty
    @State private var refreshing = false
    @State private var failed = false
    @State private var openStory: FeedPost?
    @State private var query = ""
    @State private var loadToken = 0
    @State private var paintedCategory = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                categoryBar
            }
            .background(SyncTheme.paper)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if headlines.isEmpty && loading {
                        SparkleThinking(
                            label: "Finding stories",
                            iconSize: 32,
                            inverted: colorScheme == .dark,
                            brandIcon: true
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                    } else if failed && headlines.isEmpty {
                        Text(query.isEmpty
                             ? "Live articles are temporarily unavailable. Pull down to retry."
                             : "No stories matched that search. Try a different name or topic.")
                            .font(.system(size: 14))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 40)
                    } else {
                        ForEach(Array(headlines.enumerated()), id: \.element.identity) { index, story in
                            Button {
                                openStory = FeedStudio.post(from: story, topic: category)
                            } label: {
                                NewsStoryBlock(story: story, compact: index > 0)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, headlines.isEmpty && loading ? 4 : 22)
                .padding(.bottom, 110)
            }
            .id(category)
            .syncPullToRefresh { await reload() }
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            TasteEngine.ingest(Array(saves))
            Task { await showCategory(category) }
        }
        .onChange(of: category) { _, next in
            Task { await showCategory(next) }
        }
        .navigationDestination(item: $openStory) { post in
            StoryDetailView(post: post)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            if refreshing {
                SparkleThinking(label: "", iconSize: 32, inverted: colorScheme == .dark, brandIcon: true)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Loading")
            } else {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload")
            }

            HStack(spacing: 10) {
                Button {
                    Task { await runSearch() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
                TextField("Ask for stories", text: $query)
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch() } }
                if !query.isEmpty {
                    Button {
                        query = ""
                        Task { await load(force: true) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SyncTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(SyncTheme.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SyncTheme.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(categories, id: \.self) { item in
                    Button {
                        guard category != item else { return }
                        category = item
                    } label: {
                        Text(item)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(category == item ? SyncTheme.ink : SyncTheme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SyncTheme.line)
                .frame(height: 1)
        }
    }

    private func reload() async {
        refreshing = true
        defer { refreshing = false }
        // #region agent log
        AgentDebug.log("A", "NewsTabView.reload", "pull", ["headlineCount": headlines.count, "loading": loading, "queryLen": query.count])
        // #endregion
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.count >= 2 {
            await runSearch()
            return
        }
        let name = category
        let current = headlines
        let t0 = CFAbsoluteTimeGetCurrent()
        let items = await NewsFeedCache.fetch(name, force: true, skipAPI: true)
        // #region agent log
        AgentDebug.log("A", "NewsTabView.reload", "done", [
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "n": items.count,
            "name": name
        ])
        // #endregion
        guard category == name else { return }
        applyHeadlines(items, fallback: current, name: name)
    }

    private func applyHeadlines(_ items: [NewsHeadline], fallback: [NewsHeadline], name: String) {
        let have = Set(fallback.map(\.identity))
        let fresh = items.filter { !have.contains($0.identity) }
        let next = fresh + (fallback.isEmpty ? items : fallback)
        if next.map(\.identity) == fallback.map(\.identity) {
            prefetchPictures(fallback)
            prefetchBriefings(Array(fallback.prefix(3)), topic: name)
            return
        }
        headlines = next
        paintedCategory = name
        failed = next.isEmpty
        loading = false
        prefetchPictures(next)
        prefetchBriefings(Array(next.prefix(3)), topic: name)
    }

    private func showCategory(_ name: String) async {
        if paintedCategory == name, !headlines.isEmpty {
            prefetchPictures(headlines)
            prefetchBriefings(Array(headlines.prefix(3)), topic: name)
            Task { await quietRefresh(name) }
            return
        }
        let stored = NewsFeedCache.stored(name)
        let fresh = NewsFeedCache.snapshot(name)
        // #region agent log
        AgentDebug.log("B", "NewsTabView.showCategory", "paint", ["stored": stored.count, "fresh": fresh.count, "name": name])
        // #endregion
        if !stored.isEmpty {
            headlines = stored
            paintedCategory = name
            failed = false
            loading = false
            prefetchPictures(stored)
            prefetchBriefings(Array(stored.prefix(3)), topic: name)
            Task { await quietRefresh(name) }
            return
        }
        await load(force: false)
    }

    private func quietRefresh(_ name: String) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = await NewsFeedCache.fetch(name, force: true, skipAPI: true)
        // #region agent log
        AgentDebug.log("A", "NewsTabView.quietRefresh", "done", [
            "name": name,
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        ])
        // #endregion
    }

    private func bumpToken() -> Int {
        loadToken += 1
        return loadToken
    }

    private func load(force: Bool = false) async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.count >= 2 {
            await runSearch()
            return
        }
        refreshing = true
        defer { refreshing = false }
        let requested = category
        let token = bumpToken()
        let stored = NewsFeedCache.stored(requested)
        let cached = NewsFeedCache.snapshot(requested)
        // #region agent log
        AgentDebug.log("D", "NewsTabView.load", "enter", ["force": force, "stored": stored.count, "fresh": cached.count, "headlineCount": headlines.count])
        // #endregion
        if !stored.isEmpty {
            headlines = stored
            paintedCategory = requested
            failed = false
            loading = false
        }
        if !force, !cached.isEmpty {
            prefetchPictures(cached)
            prefetchBriefings(Array(cached.prefix(3)), topic: requested)
            await quietRefresh(requested)
            return
        }
        if headlines.isEmpty { loading = true }
        failed = false
        let items = await NewsFeedCache.fetch(requested, force: force || headlines.isEmpty, skipAPI: true)
        guard token == loadToken, category == requested else { return }
        if items.isEmpty {
            if headlines.isEmpty { failed = true }
            loading = false
            return
        }
        headlines = items
        paintedCategory = requested
        loading = false
        prefetchPictures(items)
        prefetchBriefings(Array(items.prefix(3)), topic: requested)
    }

    private func runSearch() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchFocused = false
        guard needle.count >= 2 else {
            await load(force: true)
            return
        }
        loading = headlines.isEmpty
        refreshing = true
        defer { refreshing = false }
        failed = false
        let items = await FeedStudio.headlineSearch(needle, limit: 12)
        headlines = items
        paintedCategory = category
        failed = items.isEmpty
        loading = false
        prefetchPictures(items)
        prefetchBriefings(items, topic: category)
    }

    private func prefetchBriefings(_ items: [NewsHeadline], topic: String) {
        Task(priority: .utility) { @MainActor in
            let posts = items.prefix(3).map { FeedStudio.post(from: $0, topic: topic) }
            await FeedStudio.ensureBriefings(Array(posts))
        }
    }

    private func prefetchPictures(_ items: [NewsHeadline]) {
        Task(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for story in items {
                    group.addTask { await NewsStoryBlock.warmImage(for: story) }
                }
            }
        }
    }

    static func query(for category: String) -> String {
        switch category {
        case "For You", "Top": "top stories"
        case "U.S.": "United States news"
        case "World": "world news"
        case "History": "history archaeology"
        case "Business": "business markets"
        case "Technology": "technology"
        case "Science": "science"
        case "Entertainment": "entertainment"
        case "Lifestyle": "lifestyle"
        case "Food": "food cooking"
        case "Sports": "sports"
        default: category
        }
    }
}

struct NewsStoryBlock: View, Equatable {
    let story: NewsHeadline
    var compact: Bool
    @State private var picture: UIImage?
    @ObservedObject private var photos = FeedPhotoBox.shared

    static func == (lhs: NewsStoryBlock, rhs: NewsStoryBlock) -> Bool {
        lhs.story.identity == rhs.story.identity && lhs.compact == rhs.compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(SyncTheme.paperRaised)
                .frame(height: compact ? 190 : 255)
                .overlay {
                    if let picture {
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SparkleThinking(label: "", iconSize: 28, inverted: true, brandIcon: true)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text((story.source.isEmpty ? "News" : story.source).uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(SyncTheme.inkMuted)
                .padding(.top, 16)
            Text(story.title)
                .font(.system(size: 25, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(SyncTheme.ink)
                .padding(.top, 7)
            Text(story.snippet.isEmpty ? "Open the original report for the complete story." : story.snippet)
                .font(.system(size: 16))
                .foregroundStyle(SyncTheme.ink.opacity(0.72))
                .padding(.top, 8)
            Text((story.publishedAt.map(FeedNews.dateLine) ?? "Recently") + (story.source.isEmpty ? "" : "  ·  \(story.source)"))
                .font(.system(size: 12))
                .foregroundStyle(SyncTheme.inkTertiary)
                .padding(.top, 12)
            Text("Understand this  →")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SyncTheme.ink)
                .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SyncTheme.line)
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
        .onAppear {
            pullCached()
        }
        .onChange(of: photos.generation) { _, _ in
            pullCached()
        }
        .task(id: story.url + story.title) {
            await loadPicture()
        }
    }

    static func warmImage(for story: NewsHeadline) async {
        let id = FeedNews.photoID(for: story)
        if FeedImageCache.image(for: id) != nil { return }
        _ = await FeedNews.loadFastImage(for: story)
    }

    private func pullCached() {
        let id = FeedNews.photoID(for: story)
        if let cached = FeedImageCache.image(for: id) {
            picture = cached
        }
    }

    private func loadPicture() async {
        pullCached()
        if let image = await FeedNews.loadFastImage(for: story) {
            picture = image
        }
    }
}
