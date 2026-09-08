import SwiftUI
import SwiftData
import Combine
import UIKit

struct ExploreHomeView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @State private var news: [FeedPost] = Array(FeedStore.load().suffix(12).reversed())
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var showingHowTo = false
    @State private var showingCoach = false
    @State private var coachTarget: CoachSpot?
    @State private var featuredIndex = 0
    @State private var searchQuery = ""
    @State private var searchLiveStories: [FeedPost] = []
    @AppStorage(AccountSession.nameKey) private var displayName = ""
    @AppStorage(CoachTour.completedKey) private var completedCoach = false
    @AppStorage(CoachTour.restartKey) private var restartCoach = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(greeting)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(SyncTheme.ink)
                    .padding(.top, 8)
                    .id("homeTop")

                hero
                    .coachSpot(.hero)
                    .id(CoachSpot.hero)

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Continue learning", action: "See all", route: .courses)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(LearningCatalog.shelves.first?.items ?? []) { item in
                                NavigationLink(value: Route.course(item.pathID)) {
                                    CourseCardView(item: item, onDark: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .coachSpot(.collections)
                .id(CoachSpot.collections)

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Book courses", action: "See all", route: .books)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(LearningCatalog.bookSummaries) { item in
                                NavigationLink(value: Route.course(item.pathID)) {
                                    BookCoverCard(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .coachSpot(.books)
                .id(CoachSpot.books)

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Your library", action: "See all", route: .library)
                    if saves.isEmpty {
                        Text("Share from TikTok, Safari, or Spotify, or tap + to paste a link. Saves show up here.")
                            .font(.system(size: 14))
                            .foregroundStyle(SyncTheme.inkMuted)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(saves.prefix(8))) { save in
                                    NavigationLink(value: Route.save(save.saveID)) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Image(systemName: save.source.symbol)
                                                .font(.system(size: 16))
                                                .foregroundStyle(SyncTheme.ink)
                                            Text(save.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(SyncTheme.ink)
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            Text(save.source.label)
                                                .font(.system(size: 11))
                                                .foregroundStyle(SyncTheme.inkMuted)
                                        }
                                        .padding(12)
                                        .frame(width: 132, height: 148, alignment: .topLeading)
                                        .background(SyncTheme.paperRaised)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(SyncTheme.line, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .coachSpot(.library)
                .id(CoachSpot.library)

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Today’s news", action: "More", route: .news)
                    VStack(spacing: 16) {
                        ForEach(news.prefix(3)) { post in
                            NavigationLink(value: Route.story(post.id)) {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((post.interest.isEmpty ? "News" : post.interest).uppercased())
                                            .font(.system(size: 11, weight: .bold))
                                            .tracking(0.8)
                                            .foregroundStyle(SyncTheme.inkMuted)
                                        Text(post.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(SyncTheme.ink)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text((post.sourceName.isEmpty ? "Story" : post.sourceName) + " · " + FeedNews.dateLine(post.publishedAt))
                                            .font(.system(size: 12))
                                            .foregroundStyle(SyncTheme.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    HomeNewsTileThumb(post: post)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .coachSpot(.stories)
                .id(CoachSpot.stories)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: coachTarget) { _, spot in
            guard let spot else { return }
            let topBar: Set<CoachSpot> = [.howTo, .searchBar, .save, .forYou]
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                withAnimation(.easeInOut(duration: 0.28)) {
                    if topBar.contains(spot) {
                        proxy.scrollTo("homeTop", anchor: .top)
                    } else {
                        proxy.scrollTo(spot, anchor: .center)
                    }
                }
            }
        }
        }
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
            await loadNews(force: true)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                Spacer()
                Button { showingHowTo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                .coachSpot(.howTo)
                .accessibilityLabel("How to use")
                Button { showingSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                .coachSpot(.searchBar)
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                .coachSpot(.save)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(SyncTheme.paper)
        }
        .sheet(isPresented: $showingAdd) {
            AddSaveSheet()
                .presentationBackground(SyncTheme.paper)
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack {
                SearchView(
                    embedInSheet: true,
                    query: $searchQuery,
                    liveStories: $searchLiveStories
                )
                .navigationDestination(for: Route.self) { DestinationRouter(route: $0) }
            }
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
        .sheet(isPresented: $showingHowTo) {
            HowToUseView()
                .presentationBackground(SyncTheme.paper)
        }
        .navigationDestination(for: Route.self) { DestinationRouter(route: $0) }
        .coachTour(CoachTour.home, isPresented: $showingCoach, onStepChange: { spot in
            coachTarget = spot
        }) {
            completedCoach = true
            restartCoach = false
        }
        .onAppear {
            startHomeCoachIfNeeded()
        }
        .onChange(of: restartCoach) { _, on in
            if on { startHomeCoachIfNeeded() }
        }
        .task {
            if news.count < 6 { await loadNews() }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            advanceFeatured()
        }
        .onChange(of: featuredIndex) { _, idx in
            let id = featuredCourses.indices.contains(idx) ? featuredCourses[idx].id : "?"
            // #region agent log
            AgentDebug.log("B", "ExploreHomeView.onChange", "featuredIndex", ["i": idx, "id": id])
            // #endregion
        }
    }

    private func startHomeCoachIfNeeded() {
        guard restartCoach || (!completedCoach && !showingCoach) else { return }
        let replay = restartCoach
        restartCoach = false
        Task { @MainActor in
            if replay { try? await Task.sleep(for: .milliseconds(250)) }
            showingCoach = true
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let hello = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = displayName.split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? hello : "\(hello), \(name)."
    }

    private var featuredCourses: [LearningPath] {
        Array(LearningCatalog.officialPaths.prefix(8))
    }

    private var featuredPath: LearningPath {
        let items = featuredCourses
        let index = items.isEmpty ? 0 : featuredIndex % items.count
        return items[index]
    }

    private var hero: some View {
        NavigationLink(value: Route.course(featuredPath.id)) {
            featuredCard(featuredPath)
        }
        .buttonStyle(.plain)
        .frame(height: 268)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 5) {
                ForEach(featuredCourses.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index == featuredIndex ? 0.95 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
    }

    private func featuredCard(_ path: LearningPath) -> some View {
        ZStack(alignment: .bottomLeading) {
            CourseArtwork(pathID: path.id, title: path.title)
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(path.title.uppercased()) · COURSE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.8))
                Text(path.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(path.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .padding(.top, 6)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func advanceFeatured() {
        stepFeatured(1)
    }

    private func stepFeatured(_ delta: Int) {
        let count = featuredCourses.count
        guard count > 1 else { return }
        let next = (featuredIndex + delta + count) % count
        // #region agent log
        AgentDebug.log("D", "ExploreHomeView.step", "tick", [
            "from": featuredIndex,
            "to": next,
            "id": featuredCourses[next].id
        ])
        // #endregion
        withAnimation(.easeInOut(duration: 0.45)) {
            featuredIndex = next
        }
    }

    private func sectionHeader(_ title: String, action: String, route: Route? = nil, actionHandler: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(SyncTheme.ink)
            Spacer()
            if let route {
                NavigationLink(value: route) {
                    Text(action + " ›")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .buttonStyle(.plain)
            } else if let actionHandler {
                Button(action: actionHandler) {
                    Text(action + " ›")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .buttonStyle(.plain)
            } else {
                Text(action + " ›")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SyncTheme.inkMuted)
            }
        }
    }

    private func loadNews(force: Bool = false) async {
        if !force {
            news = await FeedStudio.withPhotos(Array(FeedStore.load().suffix(12).reversed()))
            guard news.count < 6 else { return }
        }
        _ = await FeedStudio.fill(from: saves, count: force ? 12 : 6, replace: force)
        news = await FeedStudio.withPhotos(Array(FeedStore.load().suffix(12).reversed()))
    }
}

private struct HomeNewsTileThumb: View {
    let post: FeedPost
    @State private var picture: UIImage?

    var body: some View {
        ZStack {
            SyncTheme.paperRaised
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 88, height: 72)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task {
            if let cached = FeedImageCache.image(for: post.id) {
                picture = cached
            } else {
                picture = await FeedNews.loadFastImage(for: post)
            }
        }
    }
}

struct HomeNewsListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var posts: [FeedPost] = FeedStore.load().reversed()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(posts) { post in
                    NavigationLink(value: Route.story(post.id)) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text((post.interest.isEmpty ? "News" : post.interest).uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(SyncTheme.inkMuted)
                                Text(post.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(SyncTheme.ink)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                Text((post.sourceName.isEmpty ? "Story" : post.sourceName) + " · " + FeedNews.dateLine(post.publishedAt))
                                    .font(.system(size: 12))
                                    .foregroundStyle(SyncTheme.inkTertiary)
                            }
                            Spacer(minLength: 0)
                            HomeNewsTileThumb(post: post)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("News")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SyncTheme.ink)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(SyncTheme.paper)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            posts = await FeedStudio.withPhotos(Array(FeedStore.load().reversed()))
        }
    }
}
