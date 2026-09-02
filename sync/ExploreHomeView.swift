import SwiftUI
import SwiftData
import UIKit

struct ExploreHomeView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @State private var news: [FeedPost] = Array(FeedStore.load().suffix(12).reversed())
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var searchQuery = ""
    @State private var searchLiveStories: [FeedPost] = []
    @AppStorage(AccountSession.nameKey) private var displayName = ""
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(greeting)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(SyncTheme.ink)
                    .padding(.top, 8)

                hero

                sectionHeader("Continue learning", action: "See all")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(LearningCatalog.shelves.first?.items ?? []) { item in
                            NavigationLink(value: Route.course(item.pathID)) {
                                CourseCardView(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !saves.isEmpty {
                    sectionHeader("Your library", action: "See all")
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

                sectionHeader("Today’s news", action: "More")
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
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Button { showingSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
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
        .navigationDestination(for: Route.self) { DestinationRouter(route: $0) }
        .task {
            if news.count < 6 { await loadNews() }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let hello = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = displayName.split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? hello : "\(hello), \(name)."
    }

    private var hero: some View {
        NavigationLink(value: Route.course("ai")) {
            ZStack(alignment: .bottomLeading) {
                CourseArtwork(pathID: "ai")
                    .frame(height: 220)
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ARTIFICIAL INTELLIGENCE · COURSE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.8))
                    Text("AI Foundations")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Understand how modern AI systems learn, reason, and use information.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, action: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(SyncTheme.ink)
            Spacer()
            Text(action + " ›")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SyncTheme.inkMuted)
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
