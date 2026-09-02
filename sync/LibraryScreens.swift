import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DestinationRouter: View {
    let route: Route

    var body: some View {
        Group {
            switch route {
            case .search:
                OwnedSearchView()
            case .save(let id):
                SaveDetailLoader(id: id)
            case .collection(let id):
                CollectionLoader(id: id)
            case .library:
                LibraryView()
            case .collections:
                CollectionsListView()
            case .entity(let name):
                EntityDetailView(name: name)
            case .recap:
                RecapView()
            case .forYou:
                ForYouView()
            case .story(let id):
                if let post = FeedStore.load().first(where: { $0.id == id }) {
                    StoryDetailView(post: post)
                } else {
                    Text("This story is gone.")
                        .foregroundStyle(SyncTheme.inkMuted)
                }
            case .settings:
                SettingsView()
            }
        }
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct SaveDetailLoader: View {
    let id: UUID
    @Query private var saves: [SaveItem]

    init(id: UUID) {
        self.id = id
        let target = id
        _saves = Query(filter: #Predicate<SaveItem> { $0.saveID == target })
    }

    var body: some View {
        if let save = saves.first {
            SaveDetailView(save: save)
        } else {
            Text("This save is gone.")
                .foregroundStyle(SyncTheme.inkMuted)
        }
    }
}

private struct CollectionLoader: View {
    let id: UUID
    @Query private var collections: [CollectionItem]

    init(id: UUID) {
        self.id = id
        let target = id
        _collections = Query(filter: #Predicate<CollectionItem> { $0.collectionID == target })
    }

    var body: some View {
        if let collection = collections.first {
            CollectionDetailView(collection: collection)
        } else {
            Text("This collection is gone.")
                .foregroundStyle(SyncTheme.inkMuted)
        }
    }
}

struct CollectionsListView: View {
    @Query(sort: \CollectionItem.name) private var collections: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @State private var showingNew = false
    @State private var newName = ""

    private var listed: [CollectionItem] {
        collections.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.saves.count != $1.saves.count { return $0.saves.count > $1.saves.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            ForEach(listed) { collection in
                NavigationLink(value: Route.collection(collection.collectionID)) {
                    HStack {
                        Text(collection.name)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(SyncTheme.ink)
                        Spacer()
                        Text("\(collection.saves.count)")
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(SyncTheme.inkMuted)
                    }
                }
                .listRowBackground(SyncTheme.paperRaised)
            }
        }
        .overlay {
            if listed.isEmpty {
                Text("No collections yet.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .syncScreen()
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New") { showingNew = true }
            }
        }
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
        }
        .alert("New collection", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, CollectionHousekeeping.match(name, in: collections) == nil {
                    modelContext.insert(CollectionItem(name: name))
                    try? modelContext.save()
                }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

struct LibraryView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Environment(\.modelContext) private var modelContext
    @State private var source: SourceKind?

    private var filtered: [SaveItem] {
        guard let source else { return saves }
        return saves.filter { $0.source == source }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip("All", selected: source == nil) { source = nil }
                        ForEach(SourceKind.allCases) { kind in
                            filterChip(kind.label, selected: source == kind) { source = kind }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(SyncTheme.paper)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }

            ForEach(filtered) { save in
                NavigationLink(value: Route.save(save.saveID)) {
                    SaveRow(save: save)
                }
                .listRowBackground(SyncTheme.paper)
            }
        }
        .overlay {
            if filtered.isEmpty {
                Text("Nothing in your library yet.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .syncScreen()
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? SyncTheme.ink : SyncTheme.paperRaised)
                .foregroundStyle(selected ? SyncTheme.paper : SyncTheme.ink)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EntityDetailView: View {
    let name: String
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAsk = false

    private var mentions: [SaveItem] {
        saves.filter { $0.entities.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }
    }

    var body: some View {
        List {
            Section {
                Text("Mentioned in \(mentions.count) save\(mentions.count == 1 ? "" : "s")")
                    .font(.system(size: 15))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .listRowBackground(SyncTheme.paper)
                Button {
                    showingAsk = true
                } label: {
                    AskLaunchRow(
                        title: "Ask about \(name)",
                        subtitle: SaveChatStore.load(key: "entity-\(name)").isEmpty
                            ? "Chat about these saves"
                            : "Continue the thread"
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(SyncTheme.paper)
            }
            ForEach(mentions) { save in
                NavigationLink(value: Route.save(save.saveID)) {
                    SaveRow(save: save)
                }
                .listRowBackground(SyncTheme.paper)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .syncScreen()
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
        }
        .navigationTitle(name)
        .sheet(isPresented: $showingAsk) {
            LibraryAskSheet(
                threadKey: "entity-\(name)",
                placeholder: "Ask about \(name)",
                emptyHint: "Ask anything about saves that mention \(name).",
                saves: mentions,
                focus: name
            )
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
    }
}

struct RecapView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAsk = false

    private var snapshot: Recap.Snapshot { Recap.week(saves) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your week")
                        .font(.system(size: 32, weight: .semibold, design: .serif))
                        .foregroundStyle(SyncTheme.ink)

                    if snapshot.savedAllTime == 0 {
                        Text("Nothing in your library yet. Share something to sync and it will show up here.")
                            .font(.system(size: 17))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if snapshot.isQuietWeek {
                        Text("Quiet week — \(snapshot.savedAllTime) saved in your library.")
                            .font(.system(size: 17))
                            .foregroundStyle(SyncTheme.inkMuted)
                    } else {
                        Text("\(snapshot.savedThisWeek) things saved this week")
                            .font(.system(size: 17))
                            .foregroundStyle(SyncTheme.inkMuted)
                    }
                }

                Button {
                    showingAsk = true
                } label: {
                    AskLaunchRow(
                        title: "Ask about this week",
                        subtitle: SaveChatStore.load(key: "week-recap").isEmpty
                            ? "Chat about what you saved"
                            : "Continue the thread"
                    )
                }
                .buttonStyle(.plain)

                if !snapshot.interests.isEmpty {
                    recapBlock(
                        title: snapshot.isQuietWeek ? "You’re usually into" : "You were into",
                        lines: snapshot.interests
                    )
                }

                if !snapshot.repeating.isEmpty {
                    recapBlock(title: "Kept coming up", lines: snapshot.repeating)
                }

                if !snapshot.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where it came from")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        ForEach(snapshot.sources, id: \.name) { row in
                            HStack {
                                Text(row.name)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(SyncTheme.ink)
                                Spacer()
                                Text("\(row.count)")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(SyncTheme.inkMuted)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let item = snapshot.revisiting {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Worth revisiting")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        NavigationLink(value: Route.save(item.saveID)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 18, weight: .semibold, design: .serif))
                                    .foregroundStyle(SyncTheme.ink)
                                Text(item.source.label)
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

                if !snapshot.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(snapshot.isQuietWeek ? "In your library" : "This week")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        ForEach(snapshot.recent) { save in
                            NavigationLink(value: Route.save(save.saveID)) {
                                SaveRow(save: save)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .padding(.bottom, 40)
        }
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
        }
        .syncScreen()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAsk) {
            LibraryAskSheet(
                threadKey: "week-recap",
                placeholder: "Ask about this week",
                emptyHint: "Ask anything about what you saved this week.",
                saves: Array(saves.prefix(20)),
                focus: "this week's library recap"
            )
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
    }

    private func recapBlock(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SyncTheme.inkMuted)
                .textCase(.uppercase)
                .tracking(0.6)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
            }
        }
    }
}

struct LibraryIntelligenceSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var apiKey = ""
    @State private var saved = false
    @AppStorage("lastLLMError") private var lastError = ""

    var body: some View {
        Section("Understanding") {
            Text("New saves get a real summary, specific topics, names, and a collection, quietly, after they land.")
                .font(.system(size: 14))
                .foregroundStyle(SyncTheme.inkMuted)
                .listRowBackground(SyncTheme.paperRaised)

            LabeledContent("Engine", value: "Anthropic (Claude Haiku)")
                .listRowBackground(SyncTheme.paperRaised)

            if BundledAPIKeys.anthropic.isEmpty {
                SecureField("Anthropic API key", text: $apiKey)
                    .textContentType(.password)
                    .listRowBackground(SyncTheme.paperRaised)
                Button(saved ? "Key saved" : "Save key") {
                    IntelligenceKey.save(apiKey)
                    saved = IntelligenceKey.isConfigured
                }
                .foregroundStyle(SyncTheme.ink)
                .listRowBackground(SyncTheme.paperRaised)
            }

            Button("Understand existing saves") {
                LibraryBrain.queueUnread(in: modelContext)
                CaptureService.enrichUnprocessed(in: modelContext)
            }
            .foregroundStyle(SyncTheme.ink)
            .listRowBackground(SyncTheme.paperRaised)

            if !lastError.isEmpty {
                Text(lastError)
                    .font(.system(size: 13))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .listRowBackground(SyncTheme.paperRaised)
            }
        }
        .onAppear {
            apiKey = IntelligenceKey.load()
            saved = IntelligenceKey.isConfigured
        }
    }
}

struct ForYouSettingsSection: View {
    @State private var eleven = ""
    @State private var news = ""
    @State private var elevenSaved = false
    @State private var newsSaved = false

    var body: some View {
        Section("For you") {
            Text("Headlines and briefings come from your library. Pick a voice for For you.")
                .font(.system(size: 14))
                .foregroundStyle(SyncTheme.inkMuted)
                .listRowBackground(SyncTheme.paperRaised)

            NavigationLink {
                FeedVoicePicker()
            } label: {
                HStack {
                    Text("Voice")
                    Spacer()
                    Text(FeedVoice.displayName)
                        .foregroundStyle(SyncTheme.inkMuted)
                }
            }
            .foregroundStyle(SyncTheme.ink)
            .listRowBackground(SyncTheme.paperRaised)

            if BundledAPIKeys.newsAPI.isEmpty {
                SecureField("NewsAPI.ai key", text: $news)
                    .textContentType(.password)
                    .listRowBackground(SyncTheme.paperRaised)
                Button(newsSaved ? "NewsAPI.ai key saved" : "Save NewsAPI.ai key") {
                    NewsAPIKey.save(news)
                    newsSaved = NewsAPIKey.isConfigured
                }
                .foregroundStyle(SyncTheme.ink)
                .listRowBackground(SyncTheme.paperRaised)
            }

            if BundledAPIKeys.elevenLabs.isEmpty {
                SecureField("ElevenLabs API key", text: $eleven)
                    .textContentType(.password)
                    .listRowBackground(SyncTheme.paperRaised)
                Button(elevenSaved ? "ElevenLabs key saved" : "Save ElevenLabs key") {
                    ElevenLabsKey.save(eleven)
                    elevenSaved = ElevenLabsKey.isConfigured
                }
                .foregroundStyle(SyncTheme.ink)
                .listRowBackground(SyncTheme.paperRaised)
            }
        }
        .onAppear {
            eleven = ElevenLabsKey.load()
            news = NewsAPIKey.load()
            elevenSaved = ElevenLabsKey.isConfigured
            newsSaved = NewsAPIKey.isConfigured
        }
    }
}

struct SettingsView: View {
    @Query private var saves: [SaveItem]
    @Query private var collections: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.light.rawValue
    @AppStorage(WeeklyRecapNotify.enabledKey) private var weeklyRecap = false
    @AppStorage(CoachTour.restartKey) private var restartCoach = false
    @State private var exportURL: URL?
    @State private var confirmingWipe = false
    @State private var confirmingSignOut = false
    @AppStorage(AccountSession.userIDKey) private var userID = ""
    @AppStorage(AccountSession.nameKey) private var displayName = ""

    var body: some View {
        List {
            LibraryIntelligenceSection()

            ForYouSettingsSection()

            AccountSettingsSection()

            Section("Saving") {
                Button {
                    restartCoach = true
                    dismiss()
                } label: {
                    Text("Walk through Home")
                }
                .foregroundStyle(SyncTheme.ink)
                .listRowBackground(SyncTheme.paperRaised)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(SyncTheme.paperRaised)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section {
                Text("Your library belongs to you.\nYour saves are private by default.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.ink)
                    .listRowBackground(SyncTheme.paperRaised)
            }

            Section("Library") {
                LabeledContent("Saves", value: "\(saves.count)")
                    .listRowBackground(SyncTheme.paperRaised)
                LabeledContent("Collections", value: "\(collections.count)")
                    .listRowBackground(SyncTheme.paperRaised)
            }

            Section("Weekly recap") {
                Toggle("Sunday recap", isOn: $weeklyRecap)
                    .tint(SyncTheme.ink)
                    .listRowBackground(SyncTheme.paperRaised)
                    .onChange(of: weeklyRecap) { _, on in
                        WeeklyRecapNotify.apply(enabled: on, saveCount: saves.count)
                    }
                Button("Send a sample notification") {
                    WeeklyRecapNotify.sendPreview(saveCount: saves.count)
                }
                .foregroundStyle(SyncTheme.ink)
                .listRowBackground(SyncTheme.paperRaised)
            }

            Section("Data") {
                Button("Export my data") { export() }
                    .foregroundStyle(SyncTheme.ink)
                    .listRowBackground(SyncTheme.paperRaised)
                if let exportURL {
                    ShareLink("Share export", item: exportURL)
                        .foregroundStyle(SyncTheme.ink)
                        .listRowBackground(SyncTheme.paperRaised)
                }
                Button("Delete all saves", role: .destructive) {
                    confirmingWipe = true
                }
                .confirmationDialog("Delete all saves?", isPresented: $confirmingWipe, titleVisibility: .visible) {
                    Button("Delete all", role: .destructive) {
                        for save in saves { modelContext.delete(save) }
                        try? modelContext.save()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This can’t be undone.")
                }
                .listRowBackground(SyncTheme.paperRaised)
            }

            Section {
                Text("sync does not train on your private library.")
                    .font(.system(size: 13))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .listRowBackground(SyncTheme.paperRaised)
            }

            Section {
                Button("Sign out", role: .destructive) {
                    confirmingSignOut = true
                }
                .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) {
                        displayName = ""
                        userID = ""
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Are you sure?")
                }
                .listRowBackground(SyncTheme.paperRaised)
            }
        }
        .scrollContentBackground(.hidden)
        .syncScreen()
        .navigationTitle("Settings")
    }

    private func export() {
        struct Payload: Codable {
            var title: String
            var url: String
            var source: String
            var summary: String
            var topics: [String]
            var entities: [String]
            var savedAt: Date
        }
        let payload = saves.map {
            Payload(
                title: $0.title,
                url: $0.sourceURL,
                source: $0.sourceRaw,
                summary: $0.summary,
                topics: $0.topics,
                entities: $0.entities,
                savedAt: $0.savedAt
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synchronous-export.json")
        try? data.write(to: url)
        exportURL = url
    }
}
