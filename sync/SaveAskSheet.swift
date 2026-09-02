import SwiftUI
import SwiftData

struct SaveAskSheet: View {
    @Bindable var save: SaveItem
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [SaveChatLine] = []
    @State private var draft = ""
    @State private var loading = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if lines.isEmpty, !loading {
                            Text("Ask anything about this save. The thread stays here.")
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.inkMuted)
                                .padding(.top, 12)
                        }
                        ForEach(lines) { line in
                            if !line.text.isEmpty {
                                bubble(line)
                            }
                        }
                        if loading {
                            SparkleThinking(label: "Reading transcript and frames…")
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
                    TextField("Ask about this save", text: $draft, axis: .vertical)
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
                            SaveChatStore.clear(saveID: save.saveID)
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
            lines = SaveChatStore.load(saveID: save.saveID)
        }
    }

    private func displayText(_ line: SaveChatLine) -> String {
        guard line.role != "user" else { return line.text }
        return LibraryAsk.strippedHeading(line.text)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loading
    }

    private func bubble(_ line: SaveChatLine) -> some View {
        let mine = line.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            ChatMarkdown.Rich(raw: displayText(line), color: mine ? SyncTheme.paper : SyncTheme.ink)
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
        let userLine = SaveChatLine.user(q)
        lines.append(userLine)
        SaveChatStore.write(saveID: save.saveID, lines: lines)
        lines.append(SaveChatLine.assistant(""))
        SaveChatStore.write(saveID: save.saveID, lines: lines)
        loading = true
        let history = lines.dropLast(2).suffix(12).map { ($0.role, $0.text) }
        let result = await LibraryAsk.answer(
            question: q,
            from: [save],
            focus: save.title,
            primary: save,
            history: Array(history)
        ) { text in
            loading = false
            if let i = lines.indices.last {
                lines[i].text = text
            }
        }
        if let i = lines.indices.last {
            lines[i].text = result.answer
        }
        SaveChatStore.write(saveID: save.saveID, lines: lines)
        loading = false
    }
}

struct LibraryAskSheet: View {
    let threadKey: String
    let placeholder: String
    let emptyHint: String
    let saves: [SaveItem]
    var focus: String? = nil
    var seed: String? = nil
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [SaveChatLine] = []
    @State private var citations: [SaveItem] = []
    @State private var draft = ""
    @State private var loading = false
    @State private var seeded = false

    var body: some View {
        Group {
            if embedded {
                thread
            } else {
                NavigationStack { thread }
            }
        }
    }

    private var thread: some View {
        VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if lines.isEmpty, !loading {
                            Text(emptyHint)
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.inkMuted)
                                .padding(.top, 12)
                        }
                        ForEach(lines) { line in
                            if !line.text.isEmpty {
                                bubble(line)
                            }
                        }
                        if let last = lines.last, last.role != "user", !citations.isEmpty {
                            ForEach(citations.prefix(5)) { save in
                                NavigationLink {
                                    SaveDetailView(save: save)
                                } label: {
                                    Text(save.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(SyncTheme.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if loading {
                            SparkleThinking(label: "Looking through what you’ve saved…")
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
                    TextField(placeholder, text: $draft, axis: .vertical)
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
                            citations = []
                            SaveChatStore.clear(key: threadKey)
                        }
                        .foregroundStyle(SyncTheme.inkMuted)
                    }
                }
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .foregroundStyle(SyncTheme.ink)
                    }
                }
            }
        .task {
            if lines.isEmpty {
                lines = SaveChatStore.load(key: threadKey)
            }
            guard !seeded, let seed, !seed.isEmpty else { return }
            if lines.contains(where: { $0.role == "user" && $0.text == seed }) {
                seeded = true
                return
            }
            seeded = true
            draft = seed
            await send()
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loading
    }

    private func bubble(_ line: SaveChatLine) -> some View {
        let mine = line.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            ChatMarkdown.Rich(
                raw: mine ? line.text : LibraryAsk.strippedHeading(line.text),
                color: mine ? SyncTheme.paper : SyncTheme.ink
            )
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
        SaveChatStore.write(key: threadKey, lines: lines)
        lines.append(SaveChatLine.assistant(""))
        loading = true
        citations = []
        let history = lines.dropLast(2).suffix(12).map { ($0.role, $0.text) }
        let pool = LibrarySearch.results(query: q, in: saves)
        let result = await LibraryAsk.answer(
            question: q,
            from: pool.isEmpty ? saves : pool,
            focus: focus,
            primary: nil,
            history: Array(history)
        ) { text in
            loading = false
            if let i = lines.indices.last {
                lines[i].text = text
            }
        }
        if let i = lines.indices.last {
            lines[i].text = result.answer
        }
        citations = result.citations
        SaveChatStore.write(key: threadKey, lines: lines)
        loading = false
    }
}
