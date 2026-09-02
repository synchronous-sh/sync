import SwiftUI
import SwiftData

struct CollectionDetailView: View {
    @Bindable var collection: CollectionItem
    @Environment(\.modelContext) private var modelContext
    @State private var renaming = false
    @State private var showingAsk = false
    @State private var draftName = ""

    private var saves: [SaveItem] {
        collection.saves.sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingAsk = true
                } label: {
                    AskLaunchRow(
                        title: "Ask this collection",
                        subtitle: SaveChatStore.load(key: collection.collectionID.uuidString).isEmpty
                            ? "Chat about what’s in here"
                            : "Continue the thread"
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(SyncTheme.paper)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            ForEach(saves) { save in
                NavigationLink(value: Route.save(save.saveID)) {
                    SaveRow(save: save)
                }
                .listRowBackground(SyncTheme.paper)
            }
        }
        .overlay {
            if saves.isEmpty {
                Text("Nothing in this collection yet.")
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
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showingAsk) {
            LibraryAskSheet(
                threadKey: collection.collectionID.uuidString,
                placeholder: "Ask this collection",
                emptyHint: "Ask anything about the saves in \(collection.name).",
                saves: saves,
                focus: collection.name
            )
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 2) {
                    NavIconButton(accessibility: "Ask this collection") {
                        showingAsk = true
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .medium))
                    }
                    Menu {
                        Button(collection.isPinned ? "Unpin" : "Pin") {
                            collection.isPinned.toggle()
                        }
                        Button("Rename") {
                            draftName = collection.name
                            renaming = true
                        }
                        ShareLink(item: shareText) {
                            Label("Share collection", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename collection", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { collection.name = name }
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var shareText: String {
        var lines = ["\(collection.name) — from sync", ""]
        for save in saves {
            lines.append("• \(save.title)")
            if !save.sourceURL.isEmpty {
                lines.append("  \(save.sourceURL)")
            }
        }
        if saves.isEmpty {
            lines.append("This collection is empty.")
        }
        lines.append("")
        lines.append("A snapshot of a private library. Not a live public page.")
        return lines.joined(separator: "\n")
    }
}
