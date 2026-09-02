import SwiftUI
import SwiftData
import UIKit

struct HomeView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Query(sort: \CollectionItem.name) private var collections: [CollectionItem]
    @State private var news: [FeedPost] = Array(FeedStore.load().suffix(12).reversed())
    @State private var path = NavigationPath()
    @State private var showingCoach = false
    @AppStorage(CoachTour.completedKey) private var completedCoach = false
    @AppStorage(CoachTour.restartKey) private var restartCoach = false
    @State private var showingAdd = false
    @State private var showingNewCollection = false
    @State private var showingSearch = false
    @State private var searchQuery = ""
    @State private var searchLiveStories: [FeedPost] = []
    @State private var newCollectionName = ""
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greeting

                    Button {
                        showingSearch = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                            Text("Search or ask anything you’ve saved")
                            Spacer()
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.inkMuted)
                        .padding(16)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search or ask anything you’ve saved")
                    .coachSpot(.searchBar)

                    if !saves.isEmpty {
                        recentSection
                    } else {
                        Text("Share something to sync. It will show up here.")
                            .font(.system(size: 16))
                            .foregroundStyle(SyncTheme.inkMuted)
                    }

                    if !listedCollections.isEmpty {
                        collectionsSection
                    }

                    newsSection

                    entitySection

                    if let resurfaced {
                        revisitingSection(resurfaced)
                    }

                    recapEntry
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(showingCoach)
            .syncPullToRefresh {
                LibraryBrain.pull(context: modelContext)
                CollectionHousekeeping.collapse(in: modelContext)
                await loadNews(force: true)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .syncScreen()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                homeBar
            }
            .coachTour(CoachTour.home, isPresented: $showingCoach) {
                    completedCoach = true
                    restartCoach = false
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
                    .navigationDestination(for: Route.self) { route in
                        DestinationRouter(route: route)
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
                .presentationBackground(SyncTheme.paper)
            }
            .navigationDestination(for: Route.self) { route in
                DestinationRouter(route: route)
            }
            .onAppear {
                news = Array(FeedStore.load().suffix(12).reversed())
                if !completedCoach || restartCoach {
                    showingCoach = true
                }
            }
            .onChange(of: restartCoach) { _, restart in
                if restart {
                    path = NavigationPath()
                    showingCoach = true
                }
            }
            .task {
                if news.count < 6 {
                    await loadNews()
                }
            }
            .alert("New collection", isPresented: $showingNewCollection) {
                TextField("Name", text: $newCollectionName)
                Button("Create") {
                    let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty,
                       CollectionHousekeeping.match(name, in: collections) == nil {
                        modelContext.insert(CollectionItem(name: name))
                        try? modelContext.save()
                    }
                    newCollectionName = ""
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            }
        }
    }

    private var homeBar: some View {
        ZStack {
            HStack(spacing: 0) {
                NavIconPill {
                    NavIconButton(accessibility: "Settings") {
                        path.append(Route.settings)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .coachSpot(.settings)
                    NavIconButton(accessibility: "How to use") {
                        showingCoach = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .coachSpot(.howTo)
                    NavIconButton(accessibility: "Collections") {
                        path.append(Route.collections)
                    } label: {
                        Image(systemName: "square.stack")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .coachSpot(.collections)
                }
                Spacer(minLength: 0)
                NavIconPill {
                    NavIconButton(accessibility: "Search or ask") {
                        showingSearch = true
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .coachSpot(.ask)
                    NavIconButton(accessibility: "For you") {
                        path.append(Route.forYou)
                    } label: {
                        Image(systemName: "play.square.stack")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .coachSpot(.forYou)
                    NavIconButton(accessibility: "Save") {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .coachSpot(.save)
                }
            }
            Image("BrandLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 46, height: 46)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(SyncTheme.paper)
    }

    private var greeting: some View {
        Text(greetingText)
            .font(.system(size: 28, weight: .semibold, design: .serif))
            .foregroundStyle(SyncTheme.ink)
            .padding(.top, 8)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Button("See all") { path.append(Route.library) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SyncTheme.ink)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(saves.prefix(8))) { save in
                        Button {
                            path.append(Route.save(save.saveID))
                        } label: {
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

    private var listedCollections: [CollectionItem] {
        let pinned = collections.filter(\.isPinned)
        let rest = collections
            .filter { !$0.isPinned }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return pinned + Array(rest.prefix(8))
    }

    private var previewCollections: [CollectionItem] {
        Array(listedCollections.prefix(3))
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your collections")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Button("New") { showingNewCollection = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SyncTheme.ink)
            }

            VStack(spacing: 0) {
                ForEach(previewCollections) { collection in
                    NavigationLink(value: Route.collection(collection.collectionID)) {
                        collectionRow(collection)
                    }
                    .buttonStyle(.plain)

                    if collection.collectionID != previewCollections.last?.collectionID {
                        Divider().overlay(SyncTheme.line)
                    }
                }
            }

            NavigationLink(value: Route.collections) {
                HStack {
                    Text("All collections")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                    Spacer()
                    Text("\(listedCollections.count)")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(SyncTheme.inkMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func collectionRow(_ collection: CollectionItem) -> some View {
        HStack {
            Text(collection.name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SyncTheme.ink)
            Spacer()
            Text("\(collection.saves.count)")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(SyncTheme.inkMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SyncTheme.inkMuted)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stories")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Button("For you") { path.append(Route.forYou) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SyncTheme.ink)
            }
            .coachSpot(.stories)

            if news.isEmpty {
                Text("Fresh headlines will show up here.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(news) { post in
                            Button {
                                path.append(Route.story(post.id))
                            } label: {
                                HomeNewsTile(post: post)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func loadNews(force: Bool = false) async {
        if !force {
            news = await FeedStudio.withPhotos(Array(FeedStore.load().suffix(12).reversed()))
            guard news.count < 6 else { return }
        }
        _ = await FeedStudio.fill(
            from: saves,
            count: force ? 12 : 6,
            replace: force
        )
        news = await FeedStudio.withPhotos(Array(FeedStore.load().suffix(12).reversed()))
        Task { await FeedStudio.ensureBriefings(news) }
    }

    private var entitySection: some View {
        let items = Array(LibrarySearch.entities(in: saves).prefix(6))
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("People & tools")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    ForEach(items, id: \.name) { item in
                        NavigationLink(value: Route.entity(item.name)) {
                            HStack {
                                Text(item.name)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(SyncTheme.ink)
                                Spacer()
                                Text("\(item.count)")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(SyncTheme.inkMuted)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SyncTheme.inkMuted)
                            }
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if item.name != items.last?.name {
                            Divider().overlay(SyncTheme.line)
                        }
                    }
                }
            }
        }
    }

    private var recapEntry: some View {
        Button {
            path.append(Route.recap)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your week")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                    Text("A quiet recap of what you saved")
                        .font(.system(size: 13))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SyncTheme.inkMuted)
            }
            .padding(16)
            .background(SyncTheme.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(SyncTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var resurfaced: SaveItem? {
        saves
            .filter {
                Calendar.current.dateComponents([.day], from: $0.savedAt, to: .now).day ?? 0 >= 30
            }
            .first
    }

    private func revisitingSection(_ save: SaveItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worth revisiting")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SyncTheme.inkMuted)
                .textCase(.uppercase)
                .tracking(0.6)

            Button {
                path.append(Route.save(save.saveID))
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You’ve been saving \(save.topics.first ?? "this") content again.")
                        .font(.system(size: 15))
                        .foregroundStyle(SyncTheme.inkMuted)
                    Text(save.title)
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundStyle(SyncTheme.ink)
                    Text("You saved this \(relative(save.savedAt)).")
                        .font(.system(size: 13))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(SyncTheme.highlight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: .now)
    }
}

private struct HomeNewsTile: View {
    let post: FeedPost
    @State private var picture: UIImage?

    init(post: FeedPost) {
        self.post = post
        _picture = State(initialValue: FeedImageCache.image(for: post.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                SyncTheme.paperRaised
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 168, height: 112)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(post.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SyncTheme.ink)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text((post.sourceName.isEmpty ? post.interest : post.sourceName) + "  ·  " + FeedNews.dateLine(post.publishedAt))
                .font(.system(size: 11))
                .foregroundStyle(SyncTheme.inkMuted)
                .lineLimit(1)
        }
        .padding(8)
        .padding(.bottom, 4)
        .frame(width: 184, height: 220, alignment: .topLeading)
        .background(SyncTheme.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SyncTheme.line, lineWidth: 1)
        )
        .task { await loadPicture() }
    }

    private func loadPicture() async {
        if let image = await FeedNews.loadFastImage(for: post) {
            picture = image
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
}

