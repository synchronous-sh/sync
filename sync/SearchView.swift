import SwiftUI
import SwiftData

struct SearchView: View {
    var embedInSheet = false
    @Binding var query: String
    @Binding var liveStories: [FeedPost]
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var showingAsk = false
    @State private var askSeed = ""
    @State private var stories: [FeedPost] = FeedStore.load()
    @State private var fetchingNews = false
    @State private var openedStory: FeedPost?

    private var results: [SaveItem] {
        LibrarySearch.results(query: query, in: saves)
    }

    private var storyResults: [FeedPost] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        let local = stories.filter {
            $0.title.lowercased().contains(q)
                || $0.script.lowercased().contains(q)
                || $0.interest.lowercased().contains(q)
                || $0.sourceName.lowercased().contains(q)
                || $0.headline.lowercased().contains(q)
        }
        var seen = Set(liveStories.map(\.id))
        var out = liveStories
        for post in local {
            if seen.contains(post.id) { continue }
            if out.contains(where: { FeedStore.isSameStory($0.headline, post.headline) }) { continue }
            seen.insert(post.id)
            out.append(post)
        }
        return out
    }

    private var canAsk: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SyncTheme.inkMuted)
                    TextField("Search saves and stories", text: $query, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                        .focused($fieldFocused)
                        .onSubmit { openAsk() }
                    Button {
                        openAsk()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canAsk ? SyncTheme.ink : SyncTheme.inkMuted)
                    }
                    .disabled(!canAsk)
                    .accessibilityLabel("Ask")
                }
                .padding(14)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SyncTheme.line, lineWidth: 1)
                )

                if fetchingNews, storyResults.isEmpty, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                    SparkleThinking(label: "Finding articles")
                }

                if results.isEmpty, storyResults.isEmpty, !query.isEmpty, !fetchingNews {
                    Text("Nothing matches that yet.")
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.inkMuted)
                }

                if !storyResults.isEmpty {
                    Text("Stories")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    ForEach(storyResults) { post in
                        Button {
                            openedStory = post
                        } label: {
                            storyRow(post)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(results) { save in
                    NavigationLink(value: Route.save(save.saveID)) {
                        SaveRow(save: save)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .onAppear {
            stories = FeedStore.load()
            if query.isEmpty { fieldFocused = true }
        }
        .task(id: query) {
            await fetchLiveNews()
        }
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
        }
        .syncScreen()
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if embedInSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(SyncTheme.ink)
                }
            }
        }
        .navigationDestination(isPresented: $showingAsk) {
            LibraryAskSheet(
                threadKey: "library-search",
                placeholder: "Ask anything you’ve saved",
                emptyHint: "Ask across your library. Matches stay in this thread.",
                saves: saves,
                focus: askSeed,
                seed: askSeed,
                embedded: true
            )
        }
        .fullScreenCover(item: $openedStory) { post in
            NavigationStack {
                StoryDetailView(post: post)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                openedStory = nil
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(SyncTheme.ink)
                            }
                            .accessibilityLabel("Back")
                        }
                    }
            }
            .presentationBackground(SyncTheme.paper)
        }
    }

    private func fetchLiveNews() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            liveStories = []
            fetchingNews = false
            return
        }
        fetchingNews = true
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        let found = await FeedStudio.lookup(q)
        guard !Task.isCancelled else { return }
        liveStories = found
        stories = FeedStore.load()
        fetchingNews = false
    }

    private func openAsk() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askSeed = q
        showingAsk = true
    }

    private func storyRow(_ post: FeedPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(SyncTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(post.sourceName.isEmpty ? "Story" : post.sourceName)  ·  \(FeedNews.dateLine(post.publishedAt))")
                .font(.system(size: 13))
                .foregroundStyle(SyncTheme.inkMuted)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OwnedSearchView: View {
    @State private var query = ""
    @State private var liveStories: [FeedPost] = []

    var body: some View {
        SearchView(query: $query, liveStories: $liveStories)
    }
}

struct SaveRow: View {
    @Bindable var save: SaveItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: save.source.symbol)
                .font(.system(size: 15))
                .foregroundStyle(SyncTheme.ink)
                .frame(width: 28, height: 28)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(save.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SyncTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(save.source.label)  ·  \(save.savedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13))
                    .foregroundStyle(SyncTheme.inkMuted)
                if save.processingRaw == ProcessingStatus.processing.rawValue
                    || save.processingRaw == ProcessingStatus.saved.rawValue {
                    SparkleThinking(label: "Reading", size: 13, iconSize: 13)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
