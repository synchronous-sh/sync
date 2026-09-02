import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct AddSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var draft = ""
    @State private var message: String?
    @State private var photo: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a link, a note, or a screenshot.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)

                TextField("https://…", text: $draft, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(14)
                    .background(SyncTheme.paperRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(SyncTheme.line, lineWidth: 1)
                    )

                Button("Paste from clipboard") {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        draft = clip
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SyncTheme.ink)

                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                    Text("Save a screenshot or video")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SyncTheme.ink)
                }
                .onChange(of: photo) { _, item in
                    Task { await savePhoto(item) }
                }

                if let message {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(SyncTheme.inkMuted)
                }

                Spacer()
            }
            .padding(20)
            .syncScreen()
            .navigationTitle("Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let looksLikeURL = value.contains("://") || value.hasPrefix("www.")
        let url = looksLikeURL
            ? (value.contains("://") ? value : "https://\(value)")
            : nil
        let text = looksLikeURL ? nil : value
        let result = CaptureService.ingest(urlString: url, text: text, imageData: nil, context: modelContext)
        try? modelContext.save()
        if result.wasDuplicate {
            let day = result.save.savedAt.formatted(.dateTime.month(.abbreviated).day())
            message = "Already saved · \(day)"
        } else {
            dismiss()
        }
    }

    private func savePhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let video = try? await item.loadTransferable(type: PickedVideo.self),
           let name = MediaStore.importFile(from: video.url, id: UUID()) {
            _ = CaptureService.ingest(
                urlString: nil,
                text: nil,
                imageData: nil,
                mediaFileName: name,
                context: modelContext
            )
            try? modelContext.save()
            await MainActor.run { dismiss() }
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        _ = CaptureService.ingest(urlString: nil, text: nil, imageData: data, context: modelContext)
        try? modelContext.save()
        await MainActor.run { dismiss() }
    }
}

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}
