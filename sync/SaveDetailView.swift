import SwiftUI
import SwiftData
import UIKit

struct SaveDetailView: View {
    @Bindable var save: SaveItem
    @Query(sort: \CollectionItem.name) private var collections: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showingCollections = false
    @State private var showingAsk = false
    @State private var showingEdit = false
    @State private var showingNewCollection = false
    @State private var confirmingDelete = false
    @State private var newCollectionName = ""
    @State private var page: InAppPage?
    @State private var heroImage: UIImage?
    @State private var related: [SaveItem] = []

    private var isReading: Bool {
        save.processingRaw == ProcessingStatus.processing.rawValue
            || save.processingRaw == ProcessingStatus.saved.rawValue
    }

    private var openOriginalLabel: some View {
        HStack {
            Text("Open original")
            Spacer()
            Image(systemName: "arrow.up.right")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: save.source.symbol)
                    Text(save.source.label)
                    if !save.creatorHandle.isEmpty {
                        Text("·")
                        Text(save.creatorHandle)
                    }
                if isReading {
                    Text("·")
                    SparkleThinking(label: "Reading", size: 13, iconSize: 13)
                }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SyncTheme.inkMuted)

                Button {
                    showingEdit = true
                } label: {
                    Text(save.title)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(SyncTheme.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    showingEdit = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your note")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        if let note = SaveNote.text(in: save.rawText) {
                            Text(note)
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.ink)
                                .lineSpacing(3)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text("Add a note")
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SyncTheme.highlight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                if MediaEmbed.localVideo(for: save) != nil || MediaEmbed.webPlayer(for: save) != nil {
                    SaveMediaPlayer(save: save)
                } else if save.slides.count > 1 {
                    SaveSlideshow(names: save.slides)
                } else if let image = heroImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if isReading {
                    SparkleThinking(label: "Reading this save")
                }

                if !save.summary.isEmpty {
                    SaveSummaryBlock(text: save.summary)
                }

                if !save.topics.isEmpty {
                    FlowTopics(topics: save.topics)
                }

                if !save.entities.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mentioned")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        FlowChips(items: save.entities) { name in
                            NavigationLink(value: Route.entity(name)) {
                                Text(name)
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(SyncTheme.paperRaised)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(SyncTheme.line, lineWidth: 1))
                                    .foregroundStyle(SyncTheme.ink)
                            }
                        }
                    }
                }

                if !save.sourceURL.isEmpty {
                    Group {
                        if let url = URL(string: save.sourceURL) {
                            Button {
                                if !OutboundLink.open(url) {
                                    page = InAppPage(id: url)
                                }
                            } label: {
                                openOriginalLabel
                            }
                            .buttonStyle(.plain)
                        } else {
                            openOriginalLabel
                        }
                    }
                }

                if !related.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Related saves")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)

                        ForEach(related) { other in
                            NavigationLink(value: Route.save(other.saveID)) {
                                SaveRow(save: other)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .padding(.bottom, 8)
        }
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext, reread: save)
        }
        .onAppear {
            if related.isEmpty {
                let all = (try? modelContext.fetch(FetchDescriptor<SaveItem>())) ?? []
                related = LibrarySearch.related(to: save, in: all)
            }
            if heroImage == nil,
               MediaStore.isVisualImage(save.imageFileName),
               let url = MediaStore.fileURL(save.imageFileName) {
                heroImage = UIImage(contentsOfFile: url.path)
            }
        }
        .syncScreen()
        .sheet(item: $page) { page in
            SafariTab(url: page.url)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                showingAsk = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask about this save")
                            .font(.system(size: 16, weight: .medium))
                        if !SaveChatStore.load(saveID: save.saveID).isEmpty {
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
                HStack(spacing: 2) {
                    NavIconButton(accessibility: "Share") {
                        ArticleShare.share(save)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                    }
                    NavIconButton(accessibility: "Ask about this save") {
                        showingAsk = true
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .medium))
                    }
                    Menu {
                        Button("Add to title & notes") { showingEdit = true }
                        Button("Add to collection") { showingCollections = true }
                        Button("Delete", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(SyncTheme.ink)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("More")
                    .confirmationDialog("Delete this save?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            modelContext.delete(save)
                            try? modelContext.save()
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This can’t be undone.")
                    }
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            SaveEditSheet(save: save)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(SyncTheme.paper)
        }
        .sheet(isPresented: $showingAsk) {
            SaveAskSheet(save: save)
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
                .presentationBackground(SyncTheme.paper)
        }
        .sheet(isPresented: $showingCollections) {
            NavigationStack {
                List {
                    ForEach(collections) { collection in
                        Button {
                            toggle(collection)
                        } label: {
                            HStack {
                                Text(collection.name)
                                    .foregroundStyle(SyncTheme.ink)
                                Spacer()
                                if save.collections.contains(where: { $0.collectionID == collection.collectionID }) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(SyncTheme.ink)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .syncScreen()
                .navigationTitle("Collections")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("New") { showingNewCollection = true }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingCollections = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("New collection", isPresented: $showingNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                createCollection()
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        newCollectionName = ""
        guard !name.isEmpty else { return }
        if let existing = CollectionHousekeeping.match(name, in: collections) {
            toggle(existing)
            return
        }
        let collection = CollectionItem(name: name)
        modelContext.insert(collection)
        save.collections.append(collection)
        try? modelContext.save()
    }

    private func toggle(_ collection: CollectionItem) {
        if let index = save.collections.firstIndex(where: { $0.collectionID == collection.collectionID }) {
            save.collections.remove(at: index)
        } else {
            save.collections.append(collection)
        }
        try? modelContext.save()
    }
}

struct SaveSummaryBlock: View {
    let text: String

    private var parts: (paragraph: String, bullets: [String]) {
        let lines = text
            .replacingOccurrences(of: "\\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var bullets: [String] = []
        var para: [String] = []
        for line in lines {
            guard !line.isEmpty else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                let clipped = line.drop { $0 == "-" || $0 == "•" || $0 == "*" || $0 == " " }
                bullets.append(String(clipped))
            } else {
                para.append(line)
            }
        }
        return (para.joined(separator: " "), bullets)
    }

    var body: some View {
        let split = parts
        VStack(alignment: .leading, spacing: 12) {
            if !split.paragraph.isEmpty {
                Text(split.paragraph)
                    .font(.system(size: 17))
                    .foregroundStyle(SyncTheme.ink)
                    .lineSpacing(5)
            }
            if !split.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(split.bullets.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(SyncTheme.ink)
                            Text(item)
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.ink)
                                .lineSpacing(3)
                        }
                    }
                }
            }
        }
    }
}

struct FlowTopics: View {
    let topics: [String]

    var body: some View {
        FlowChips(items: topics) { topic in
            Text(topic)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(SyncTheme.paperRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(SyncTheme.line, lineWidth: 1))
                .foregroundStyle(SyncTheme.ink)
        }
    }
}

struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        ChipFlow(spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        let width = maxWidth.isFinite ? maxWidth : x
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
