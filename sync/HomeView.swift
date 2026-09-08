import SwiftUI
import SwiftData
import UIKit
import ObjectiveC

enum AppTab: Hashable {
    case home, videos, learn, news, you
}

private struct SelectedAppTabKey: EnvironmentKey {
    static let defaultValue: Binding<AppTab> = .constant(.home)
}

extension EnvironmentValues {
    var selectedAppTab: Binding<AppTab> {
        get { self[SelectedAppTabKey.self] }
        set { self[SelectedAppTabKey.self] = newValue }
    }
}

struct HomeView: View {
    @State private var tab: AppTab = .home
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]

    init() {
        Self.applyTabBar(dark: true)
    }

    private static var lastTabBarDark: Bool?

    private static func applyTabBar(dark: Bool) {
        if lastTabBarDark == dark { return }
        lastTabBarDark = dark
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = dark ? .black : UIColor(red: 0.957, green: 0.945, blue: 0.922, alpha: 1)
        appearance.shadowColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.10)
        let ink = dark ? UIColor.white : UIColor.black
        let item = UITabBarItemAppearance()
        item.normal.iconColor = ink
        item.selected.iconColor = ink
        item.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
        item.selected.titleTextAttributes = [.foregroundColor: UIColor.clear]
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().tintColor = ink
        UITabBar.appearance().unselectedItemTintColor = ink
        for scene in UIApplication.shared.connectedScenes {
            guard let window = (scene as? UIWindowScene)?.windows.first else { continue }
            apply(appearance, ink: ink, on: window.rootViewController)
        }
    }

    private static func apply(_ appearance: UITabBarAppearance, ink: UIColor, on vc: UIViewController?) {
        guard let vc else { return }
        if let tab = vc as? UITabBarController {
            tab.tabBar.standardAppearance = appearance
            tab.tabBar.scrollEdgeAppearance = appearance
            tab.tabBar.tintColor = ink
            tab.tabBar.unselectedItemTintColor = ink
        }
        vc.children.forEach { apply(appearance, ink: ink, on: $0) }
        apply(appearance, ink: ink, on: vc.presentedViewController)
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        tabHost
            .tint(tabIconColor)
            .toolbarBackground(tabBarColor, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .environment(\.selectedAppTab, $tab)
            .preferredColorScheme(appearance.colorScheme)
            .onAppear(perform: appeared)
            .onChange(of: appearanceRaw) { _, _ in
                Self.applyTabBar(dark: useDarkTabs)
            }
            .onChange(of: tab) { _, next in
                FYPStatusBar.wantsLightContent = (next == .videos)
                Self.applyTabBar(dark: next == .videos || appearanceIsDark)
            }
    }

    private var appearanceIsDark: Bool {
        switch appearance {
        case .dark: true
        case .light: false
        case .system: UITraitCollection.current.userInterfaceStyle == .dark
        }
    }

    private var useDarkTabs: Bool {
        tab == .videos || appearanceIsDark
    }

    private var tabIconColor: Color {
        useDarkTabs ? .white : .black
    }

    private var tabBarColor: Color {
        useDarkTabs ? .black : SyncTheme.paper
    }

    private func appeared() {
        Self.applyTabBar(dark: useDarkTabs)
        FYPStatusBar.install()
        FYPStatusBar.wantsLightContent = (tab == .videos)
        AppWarmup.start(saves: Array(saves))
    }

    private var tabHost: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ExploreHomeView()
            }
            .tint(SyncTheme.ink)
            .tabItem { Image(systemName: tab == .home ? "house.fill" : "house") }
            .tag(AppTab.home)

            NavigationStack {
                ForYouView()
            }
            .toolbar(.hidden, for: .navigationBar)
            .tint(SyncTheme.ink)
            .ignoresSafeArea(.keyboard)
            .tabItem { Image(systemName: tab == .videos ? "play.fill" : "play") }
            .tag(AppTab.videos)

            NavigationStack {
                LearnView()
            }
            .tint(SyncTheme.ink)
            .tabItem { Image(systemName: tab == .learn ? "book.fill" : "book") }
            .tag(AppTab.learn)

            NavigationStack {
                NewsTabView()
            }
            .tint(SyncTheme.ink)
            .tabItem { Image(systemName: tab == .news ? "newspaper.fill" : "newspaper") }
            .tag(AppTab.news)

            NavigationStack {
                YouTabView()
            }
            .tint(SyncTheme.ink)
            .tabItem { Image(systemName: tab == .you ? "person.fill" : "person") }
            .tag(AppTab.you)
        }
        .ignoresSafeArea(.keyboard)
    }
}

enum AppWarmup {
    @MainActor private static var started = false
    private static var feedReady: Task<Void, Never>?
    @MainActor private static var queued: [SaveItem] = []

    @MainActor
    static func start(saves: [SaveItem]) {
        guard !started else { return }
        started = true
        queued = saves
        feedReady = Task { @MainActor in
            let copy = queued
            // #region agent log
            AgentDebug.log("I", "HomeView.swift:warmup", "warmup_start", ["saves": copy.count])
            // #endregion
            TasteEngine.ingest(copy)
            await warmFeed(copy)
        }
    }

    static func waitForFeed() async {
        await feedReady?.value
    }

    @MainActor
    private static func warmFeed(_ saves: [SaveItem]) async {
        if FeedStore.load().count < 8 {
            _ = await FeedStudio.fill(from: saves, count: 8, replace: false)
        }
        let posts = FeedStore.load()
        ForYouView.categoryCache["For You"] = posts
        FeedImageCache.prefetch(Array(posts.prefix(3)))
    }
}

enum FYPStatusBar {
    static var wantsLightContent = false {
        didSet {
            guard wantsLightContent != oldValue else { return }
            refresh()
        }
    }

    private static var installed = false
    private static var styleOriginal = [ObjectIdentifier: IMP]()
    private static var childOriginal = [ObjectIdentifier: IMP]()

    static func install() {
        if installed {
            refresh()
            return
        }
        installed = true
        patch(UIViewController.self)
        patch(UINavigationController.self)
        patch(UITabBarController.self)
        refresh()
    }

    static func refresh() {
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let window = (scene as? UIWindowScene)?.windows.first(where: \.isKeyWindow)
                        ?? (scene as? UIWindowScene)?.windows.first else { continue }
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    private static func patchTree(_ vc: UIViewController?) {
        guard let vc else { return }
        patch(object_getClass(vc))
        vc.children.forEach { patchTree($0) }
        patchTree(vc.presentedViewController)
        if let nav = vc as? UINavigationController {
            nav.viewControllers.forEach { patchTree($0) }
        }
        if let tabs = vc as? UITabBarController {
            tabs.viewControllers?.forEach { patchTree($0) }
        }
    }

    private static func patch(_ cls: AnyClass?) {
        guard let cls else { return }
        patchStyle(cls)
        patchChild(cls)
        if let superCls = class_getSuperclass(cls), superCls != UIViewController.self, superCls != NSObject.self {
            patch(superCls)
        }
    }

    private static func patchStyle(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard styleOriginal[id] == nil else { return }
        let sel = #selector(getter: UIViewController.preferredStatusBarStyle)
        guard let method = class_getInstanceMethod(cls, sel),
              let encoding = method_getTypeEncoding(method) else { return }

        let original = method_getImplementation(method)
        styleOriginal[id] = original

        let block: @convention(block) (AnyObject) -> Int = { target in
            if FYPStatusBar.wantsLightContent { return UIStatusBarStyle.lightContent.rawValue }
            let typed = unsafeBitCast(original, to: (@convention(c) (Any, Selector) -> Int).self)
            return typed(target, sel)
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, sel, imp, encoding) {
            method_setImplementation(method, imp)
        }
    }

    private static func patchChild(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard childOriginal[id] == nil else { return }
        let sel = #selector(getter: UIViewController.childForStatusBarStyle)
        guard let method = class_getInstanceMethod(cls, sel),
              let encoding = method_getTypeEncoding(method) else { return }

        let original = method_getImplementation(method)
        childOriginal[id] = original

        let block: @convention(block) (AnyObject) -> UIViewController? = { target in
            if FYPStatusBar.wantsLightContent { return nil }
            let typed = unsafeBitCast(original, to: (@convention(c) (Any, Selector) -> UIViewController?).self)
            return typed(target, sel)
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, sel, imp, encoding) {
            method_setImplementation(method, imp)
        }
    }
}

enum Route: Hashable {
    case search
    case save(UUID)
    case collection(UUID)
    case library
    case collections
    case entity(String)
    case recap
    case forYou
    case story(UUID)
    case settings
    case profile
    case course(String)
    case path(String)
    case lesson(String, Int)
    case books
    case courses
    case news
}

struct TasteProfile: Sendable {
    var weights: [String: Double]
    var categories: [String: Double]
    var fingerprint: String

    static let empty = TasteProfile(weights: [:], categories: [:], fingerprint: "")
}

enum TasteEngine {
    private static let lock = NSLock()
    private static var stored = TasteProfile.empty

    private static let stop: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about",
        "from", "that", "this", "your", "you", "how", "why", "what", "when", "news",
        "latest", "update", "video", "watch", "official", "new", "best", "top"
    ]

    private static let categoryHints: [(String, [String])] = [
        ("Business", ["business", "company", "market", "ceo", "startup", "deal", "earnings"]),
        ("Technology", ["tech", "software", "app", "chip", "ai", "apple", "google", "microsoft"]),
        ("Science", ["science", "research", "study", "climate", "space", "biology", "physics"]),
        ("Sports", ["sport", "game", "league", "coach", "player", "nba", "nfl", "soccer"]),
        ("Entertainment", ["film", "movie", "music", "tv", "actor", "album", "netflix"]),
        ("World", ["war", "diplomacy", "election", "president", "ukraine", "china", "europe"]),
        ("U.S.", ["congress", "white house", "senate", "california", "washington"]),
        ("Finance", ["stock", "bank", "fed", "inflation", "invest", "bond", "crypto"]),
        ("Health", ["health", "hospital", "drug", "vaccine", "mental", "fitness"]),
        ("Food", ["food", "restaurant", "recipe", "chef", "cooking"])
    ]

    static var profile: TasteProfile {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @MainActor private static var ingestKey = ""
    @MainActor
    static func ingest(_ saves: [SaveItem]) {
        let key = "\(saves.count)-\(saves.first?.saveID.uuidString ?? "")"
        if key == ingestKey { return }
        ingestKey = key
        // #region agent log
        let t0 = CFAbsoluteTimeGetCurrent()
        // #endregion
        var weights: [String: Double] = [:]
        var categories: [String: Double] = [:]
        let ranked = saves.sorted { $0.savedAt > $1.savedAt }
        for (index, save) in ranked.prefix(80).enumerated() {
            let recency = max(0.35, 1.2 - Double(index) * 0.015)
            add(save.topics, into: &weights, amount: 2.4 * recency)
            add(save.entities, into: &weights, amount: 2.0 * recency)
            add(tokens(save.title), into: &weights, amount: 1.1 * recency)
            add(tokens(save.summary), into: &weights, amount: 0.5 * recency)
            add(tokens(save.creatorName), into: &weights, amount: 1.6 * recency)
            for (name, hints) in categoryHints {
                let blob = save.searchableBlob
                if hints.contains(where: { blob.contains($0) }) {
                    categories[name, default: 0] += recency
                }
            }
        }
        for path in LearningCatalog.officialPaths {
            let done = LearningProgress.fraction(for: path)
            guard done > 0 else { continue }
            add(tokens(path.title), into: &weights, amount: 1.8 + done)
            categories[path.title, default: 0] += done
        }
        for post in FeedStore.load().prefix(20) {
            add(tokens(post.interest), into: &weights, amount: 0.7)
            add(tokens(post.title), into: &weights, amount: 0.25)
        }
        let top = weights.sorted { $0.value > $1.value }.prefix(24)
        let next = TasteProfile(
            weights: Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) }),
            categories: categories,
            fingerprint: top.map(\.key).joined(separator: "|")
        )
        lock.lock()
        stored = next
        lock.unlock()
        // #region agent log
        AgentDebug.log("G", "HomeView.swift:ingest", "ingest_done", ["ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000), "saves": saves.count])
        // #endregion
    }

    static func rankNews(_ items: [NewsHeadline], category: String, limit: Int) -> [NewsHeadline] {
        let scored = items.map { ($0, score(story: $0, category: category)) }
            .sorted { $0.1 > $1.1 }
        var picked: [NewsHeadline] = []
        var recentSources: [String] = []
        for (story, _) in scored {
            let source = story.source.lowercased()
            if recentSources.suffix(2).filter({ $0 == source }).count == 2, picked.count + 3 < scored.count {
                continue
            }
            picked.append(story)
            recentSources.append(source)
            if picked.count >= limit { break }
        }
        if picked.count < min(limit, items.count) {
            for (story, _) in scored where !picked.contains(where: { $0.identity == story.identity }) {
                picked.append(story)
                if picked.count >= limit { break }
            }
        }
        return picked
    }

    static func rankCourses(_ items: [CourseCard]) -> [CourseCard] {
        items.sorted { score(course: $0) > score(course: $1) }
    }

    static func score(story: NewsHeadline, category: String) -> Double {
        let taste = profile
        var value = 0.0
        let blob = "\(story.title) \(story.snippet) \(story.source) \(category)".lowercased()
        for (term, weight) in taste.weights where blob.contains(term) {
            value += weight * (term.count > 5 ? 3.2 : 2.2)
        }
        if story.imageURL != nil { value += 1.15 }
        if let date = story.publishedAt {
            let hours = Date().timeIntervalSince(date) / 3600
            value += max(0, 2.4 - hours / 16)
        }
        if FeedStore.hasSeen(title: story.title, url: story.url) { value -= 5 }
        if let boost = taste.categories[category] { value += min(2.2, boost) }
        if category == "Top" || category == "For You" {
            value += taste.categories.values.max().map { min(1.5, $0 * 0.2) } ?? 0
        }
        return value
    }

    static func score(course item: CourseCard) -> Double {
        let taste = profile
        var value = 0.0
        let blob = "\(item.title) \(item.subtitle) \(item.pathID)".lowercased()
        for (term, weight) in taste.weights where blob.contains(term) {
            value += weight * 2.8
        }
        if let progress = item.progress, progress > 0, progress < 1 { value += 3.5 }
        if item.pathID.hasPrefix("gen-") { value += 1.4 }
        if let path = LearningCatalog.path(id: item.pathID) {
            for lesson in path.lessons.prefix(4) {
                for (term, weight) in taste.weights where lesson.title.lowercased().contains(term) {
                    value += weight * 0.6
                }
            }
        }
        return value
    }

    static func seedQueries(limit: Int = 8) -> [String] {
        let taste = profile
        let fromWeights = taste.weights.sorted { $0.value > $1.value }.map(\.key)
        let fromCategories = taste.categories.sorted { $0.value > $1.value }.map(\.key)
        var out: [String] = []
        for term in fromWeights + fromCategories {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 3, !out.contains(where: { $0.lowercased() == clean.lowercased() }) else { continue }
            out.append(clean)
            if out.count >= limit { break }
        }
        return out
    }

    private static func add(_ terms: [String], into weights: inout [String: Double], amount: Double) {
        for term in terms {
            let key = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count >= 3, !stop.contains(key) else { continue }
            weights[key, default: 0] += amount
        }
    }

    private static func tokens(_ raw: String) -> [String] {
        raw.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }
}

enum CourseStudio {
    private static let key = "generated.courses.v1"
    private static let stampKey = "generated.courses.taste"
    nonisolated(unsafe) private static var memory: [LearningPath] = load()
    @MainActor private static var inflight: Task<Void, Never>?

    static var generated: [LearningPath] {
        memory
    }

    @MainActor
    static func refresh(from saves: [SaveItem], force: Bool = false) async {
        TasteEngine.ingest(saves)
        let stamp = TasteEngine.profile.fingerprint
        if !force, stamp == UserDefaults.standard.string(forKey: stampKey), !generated.isEmpty { return }
        if let inflight {
            if !force { await inflight.value }
            return
        }
        let task = Task { @MainActor in await generate(stamp: stamp) }
        inflight = task
        await task.value
        inflight = nil
    }

    @MainActor
    private static func generate(stamp: String) async {
        guard IntelligenceKey.isConfigured else { return }
        let seeds = TasteEngine.seedQueries(limit: 6)
        guard !seeds.isEmpty else { return }
        let official = LearningCatalog.officialPaths.map(\.title).joined(separator: ", ")
        let existing = generated.map(\.title).joined(separator: ", ")
        let user = """
        Reader interests, strongest first: \(seeds.joined(separator: ", "))
        Official courses already in the app (do not copy titles or duplicate the same syllabus): \(official)
        Courses you already generated: \(existing.isEmpty ? "none" : existing)

        Invent 2 or 3 original mini-courses tailored to those interests. JSON only:
        {
          "courses": [
            {
              "id": "gen-short-slug",
              "title": "Course title",
              "description": "One sentence on what the reader will understand.",
              "symbol": "sf.symbol.name",
              "lessons": [
                {
                  "title": "Lesson title",
                  "core": "What the idea is.",
                  "mechanism": "How it works.",
                  "application": "A concrete example."
                }
              ]
            }
          ]
        }
        Each course needs 5 lessons. id must start with gen- and use lowercase letters and dashes. Teach a specific angle, not a generic encyclopedia clone of the official list.
        """
        guard let raw = await AnthropicLibrary.reply(
            system: "You design original mobile courses. Output valid JSON only.",
            user: user,
            maxTokens: 2200
        ) else { return }
        let parsed = parse(raw)
        guard !parsed.isEmpty else { return }
        let kept = memory.filter { $0.id.hasPrefix("gen-ask-") }
        var seen = Set(kept.map(\.id))
        var next = kept
        for path in parsed.prefix(3) where seen.insert(path.id).inserted {
            next.append(path)
        }
        memory = next
        persist()
        UserDefaults.standard.set(stamp, forKey: stampKey)
    }

    @MainActor
    static func design(from request: String) async -> LearningPath? {
        let brief = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard brief.count >= 8 else { return nil }
        guard IntelligenceKey.isConfigured else { return nil }
        let official = LearningCatalog.officialPaths.map(\.title).joined(separator: ", ")
        let existing = generated.map(\.title).joined(separator: ", ")
        let user = """
        The learner said, in their own words: \(brief)

        Official courses already in the app (do not clone them): \(official)
        Courses already generated: \(existing.isEmpty ? "none" : existing)

        Design ONE original course that teaches exactly what they asked for. JSON only:
        {
          "courses": [
            {
              "id": "gen-ask-short-slug",
              "title": "Course title",
              "description": "One sentence on what they will understand.",
              "symbol": "sf.symbol.name",
              "lessons": [
                {
                  "title": "Lesson title",
                  "core": "What the idea is.",
                  "mechanism": "How it works.",
                  "application": "A concrete example."
                }
              ]
            }
          ]
        }
        6 lessons, beginner-friendly then deeper. id must start with gen-ask- and use lowercase letters and dashes. Teach a specific syllabus, not a table of contents.
        """
        guard let raw = await AnthropicLibrary.reply(
            system: "You design original mobile courses from a learner's request. Output valid JSON only.",
            user: user,
            maxTokens: 2200
        ) else { return nil }
        guard var path = parse(raw).first else { return nil }
        if !path.id.hasPrefix("gen-ask-") {
            path.id = "gen-ask-" + path.id.replacingOccurrences(of: "gen-", with: "")
        }
        if memory.contains(where: { $0.id == path.id }) {
            path.id = String((path.id + "-" + UUID().uuidString.prefix(6).lowercased()).prefix(40))
        }
        memory.insert(path, at: 0)
        if memory.count > 16 { memory = Array(memory.prefix(16)) }
        persist()
        return path
    }

    private static func parse(_ raw: String) -> [LearningPath] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["courses"] as? [[String: Any]] else { return [] }
        let official = Set(LearningCatalog.officialPaths.map(\.id))
        return rows.compactMap { row -> LearningPath? in
            var id = (row["id"] as? String ?? "").lowercased()
            id = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !id.hasPrefix("gen-") { id = "gen-\(id)" }
            guard id.count > 5, !official.contains(id) else { return nil }
            let title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (row["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 3, description.count > 12 else { return nil }
            let lessons = (row["lessons"] as? [[String: Any]] ?? []).compactMap { item -> LearningLesson? in
                let lessonTitle = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let core = (item["core"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !lessonTitle.isEmpty, core.count > 20 else { return nil }
                return LearningLesson(
                    title: lessonTitle,
                    core: core,
                    mechanism: item["mechanism"] as? String ?? "",
                    application: item["application"] as? String ?? ""
                )
            }
            guard lessons.count >= 4 else { return nil }
            return LearningPath(
                id: String(id.prefix(40)),
                title: title,
                description: description,
                symbol: (row["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "book.closed",
                lessons: Array(lessons.prefix(6))
            )
        }
    }

    private static func load() -> [LearningPath] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LearningPath].self, from: data)) ?? []
    }

    @MainActor
    private static func persist() {
        let snapshot = memory
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
