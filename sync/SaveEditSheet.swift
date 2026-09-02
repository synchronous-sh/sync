import SwiftUI
import SwiftData

struct SaveEditSheet: View {
    @Bindable var save: SaveItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var request = ""
    @State private var loading = false

    private var currentNote: String {
        SaveNote.text(in: save.rawText) ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Now")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Text(save.title)
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(SyncTheme.ink)
                        if currentNote.isEmpty {
                            Text("No notes yet")
                                .font(.system(size: 15))
                                .foregroundStyle(SyncTheme.inkMuted)
                        } else {
                            Text(currentNote)
                                .font(.system(size: 15))
                                .foregroundStyle(SyncTheme.inkMuted)
                                .lineSpacing(3)
                        }
                    }

                    TextField("Add their contact, a reminder…", text: $request, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.ink)
                        .lineLimit(2...8)
                        .padding(14)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )

                    Button {
                        Task { await apply() }
                    } label: {
                        HStack(spacing: 8) {
                            if loading {
                                ProgressView()
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            Text(loading ? "Adding…" : "Add")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundStyle(SyncTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(loading || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .navigationTitle("Add to this save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SyncTheme.inkMuted)
                }
            }
        }
    }

    private func apply() async {
        let instruction = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        loading = true
        let existingNote = currentNote
        if let result = await LibraryBrain.refineTitleAndNote(
            for: save,
            request: instruction,
            title: save.title,
            notes: existingNote
        ) {
            if !result.title.isEmpty, result.title != save.title {
                save.title = String(result.title.prefix(120))
                TitleLock.mark(save.saveID)
            }
            if !result.notes.isEmpty {
                save.rawText = SaveNote.replacing(result.notes, in: save.rawText)
            }
        } else {
            let next = existingNote.isEmpty ? instruction : existingNote + "\n" + instruction
            save.rawText = SaveNote.replacing(next, in: save.rawText)
        }
        try? modelContext.save()
        loading = false
        dismiss()
    }
}
