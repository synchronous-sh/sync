import SwiftUI
import AVKit
import WebKit
import UIKit

enum MediaEmbed {
    static func localVideo(for save: SaveItem) -> URL? {
        MediaStore.playableURL(for: save)
    }

    static func webPlayer(for save: SaveItem) -> URL? {
        guard let url = URL(string: save.sourceURL) else { return nil }
        return webPlayer(for: url)
    }

    static func webPlayer(for url: URL) -> URL? {
        if let spotify = SpotifyLink.embedURL(from: url) {
            return spotify
        }
        if let id = tiktokID(from: url) {
            return tiktokPlayerURL(id: id)
        }
        if let instagram = instagramPlayer(from: url) {
            return instagram
        }
        if let id = youtubeID(from: url) {
            return URL(string: "https://www.youtube.com/embed/\(id)?playsinline=1&rel=0")
        }
        return nil
    }

    static func instagramPlayer(from url: URL) -> URL? {
        let host = (url.host ?? "").lowercased()
        guard host.contains("instagram.com") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if let share = parts.firstIndex(of: "share"), parts.indices.contains(share + 2) {
            let kind = parts[share + 1].lowercased() == "p" ? "p" : "reel"
            let code = parts[share + 2].split(separator: "?").first.map(String.init) ?? parts[share + 2]
            guard !code.isEmpty else { return nil }
            return URL(string: "https://www.instagram.com/\(kind)/\(code)/embed/")
        }
        guard let idx = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0.lowercased()) }),
              parts.indices.contains(idx + 1) else { return nil }
        let kind = parts[idx].lowercased() == "reels" ? "reel" : parts[idx].lowercased()
        let code = parts[idx + 1].split(separator: "?").first.map(String.init) ?? parts[idx + 1]
        guard !code.isEmpty else { return nil }
        return URL(string: "https://www.instagram.com/\(kind)/\(code)/embed/")
    }

    static func playerHeight(for save: SaveItem) -> CGFloat? {
        if localVideo(for: save) != nil { return 420 }
        guard let url = URL(string: save.sourceURL), webPlayer(for: save) != nil else { return nil }
        if SpotifyLink.matches(url) {
            return SpotifyLink.compactEmbed(url) ? 168 : 360
        }
        return 420
    }

    static func tiktokPlayerURL(id: String) -> URL? {
        URL(string: "https://www.tiktok.com/player/v1/\(id)?autoplay=0&loop=0&progress_bar=1&play_button=1&volume_control=1&fullscreen_button=1&timestamp=1&music_info=1&description=1&rel=0&native_context_menu=1")
    }

    static func tiktokID(from url: URL) -> String? {
        if TikTokLink.isPhoto(url) { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        for key in ["video", "v"] {
            if let idx = parts.firstIndex(of: key), parts.indices.contains(idx + 1) {
                let id = parts[idx + 1].split(separator: "?").first.map(String.init) ?? parts[idx + 1]
                if id.allSatisfy(\.isNumber), id.count >= 8 { return id }
            }
        }
        if let last = parts.last?.split(separator: "?").first.map(String.init),
           last.allSatisfy(\.isNumber), last.count >= 8 {
            return last
        }
        return nil
    }

    static func youtubeID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        if host.contains("youtu.be") {
            return url.path.split(separator: "/").first.map(String.init)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if let id = items?.first(where: { $0.name == "v" })?.value, !id.isEmpty {
            return id
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let idx = parts.firstIndex(of: "shorts") ?? parts.firstIndex(of: "embed"),
           parts.indices.contains(idx + 1) {
            return parts[idx + 1]
        }
        return nil
    }
}

struct SaveMediaPlayer: View {
    let save: SaveItem
    @State private var playing = false
    @State private var mediaTick = 0

    var body: some View {
        let _ = mediaTick
        Group {
            if let local = MediaEmbed.localVideo(for: save) {
                LocalVideoView(url: local)
            } else if let embed = MediaEmbed.webPlayer(for: save) {
                if save.source == .spotify {
                    EmbedWebView(url: embed)
                        .background(Color.black.opacity(0.08))
                } else {
                    ZStack {
                        if playing {
                            EmbedWebView(url: embed)
                        } else {
                            thumbnail
                            Button {
                                playing = true
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .padding(18)
                                    .background(Circle().fill(.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play")
                        }
                    }
                    .background(Color.black.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(SyncTheme.line, lineWidth: 1)
                    )
                }
            }
        }
        .frame(height: MediaEmbed.playerHeight(for: save))
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .compositingGroup()
        .task(id: save.mediaFileName) {
            let had = MediaEmbed.localVideo(for: save) != nil
            await MediaCloud.ensure([save.mediaFileName, save.imageFileName] + save.slides)
            if !had, MediaEmbed.localVideo(for: save) != nil {
                mediaTick += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaCloudReady)) { _ in
            mediaTick += 1
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if MediaStore.isVisualImage(save.imageFileName),
           let url = MediaStore.fileURL(save.imageFileName),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            SyncTheme.paperRaised
        }
    }
}

private struct LocalVideoView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if player == nil { player = AVPlayer(url: url) }
            }
            .onDisappear { player?.pause() }
    }
}

private struct EmbedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.scrollView.isScrollEnabled = false
        view.backgroundColor = .black
        view.isOpaque = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct SaveSlideshow: View {
    let names: [String]
    @State private var page = 0

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $page) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    Group {
                        if MediaStore.isVisualImage(name),
                           let url = MediaStore.fileURL(name),
                           let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            SyncTheme.paperRaised
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(SyncTheme.line, lineWidth: 1)
            )

            HStack(spacing: 6) {
                ForEach(0..<names.count, id: \.self) { index in
                    Circle()
                        .fill(index == page ? SyncTheme.ink : SyncTheme.inkMuted.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            Text("\(page + 1) of \(names.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SyncTheme.inkMuted)
        }
    }
}
