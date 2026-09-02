import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case tiktok, instagram, youtube, x, reddit, github, spotify, web, screenshot, note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .x: "X"
        case .reddit: "Reddit"
        case .github: "GitHub"
        case .spotify: "Spotify"
        case .web: "Web"
        case .screenshot: "Screenshot"
        case .note: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .tiktok: "play.rectangle.fill"
        case .instagram: "camera.fill"
        case .youtube: "play.tv.fill"
        case .x: "text.bubble.fill"
        case .reddit: "bubble.left.and.bubble.right.fill"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .spotify: "music.note"
        case .web: "globe"
        case .screenshot: "text.viewfinder"
        case .note: "note.text"
        }
    }
}

enum ContentKind: String, Codable {
    case video, post, article, repository, image, text, product, place, music
}

enum SourceDetect {
    static func kind(url: URL?, text: String?, hasImage: Bool) -> (SourceKind, ContentKind) {
        if hasImage { return (.screenshot, .image) }
        if let url {
            if SpotifyLink.matches(url) {
                return (.spotify, .music)
            }
            let host = (url.host ?? "").lowercased()
            if host.contains("tiktok.com") || host.contains("vm.tiktok.com") {
                if TikTokLink.isPhoto(url) { return (.tiktok, .image) }
                return (.tiktok, .video)
            }
            if host.contains("instagram.com") { return (.instagram, .post) }
            if host.contains("youtube.com") || host.contains("youtu.be") { return (.youtube, .video) }
            if host.contains("twitter.com") || host.contains("x.com") { return (.x, .post) }
            if host.contains("reddit.com") { return (.reddit, .post) }
            if host.contains("github.com") { return (.github, .repository) }
            return (.web, .article)
        }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.note, .text)
        }
        return (.web, .article)
    }
}

enum TikTokLink {
    static func isPhoto(_ url: URL) -> Bool {
        url.path.lowercased().contains("/photo/")
    }

    static func isVideo(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("/photo/") { return false }
        if path.contains("/video/") { return true }
        let host = (url.host ?? "").lowercased()
        return host.contains("tiktok.com")
    }
}

enum SpotifyLink {
    static let types = ["track", "album", "artist", "playlist", "episode", "show"]

    static func matches(_ url: URL) -> Bool {
        if (url.scheme ?? "").lowercased() == "spotify" { return true }
        let host = (url.host ?? "").lowercased()
        return host.contains("spotify.com") || host.contains("spotify.link")
    }

    static func resource(from url: URL) -> (type: String, id: String)? {
        if (url.scheme ?? "").lowercased() == "spotify" {
            return resourceFromURI(url.absoluteString)
        }
        var parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.first?.lowercased().hasPrefix("intl-") == true { parts.removeFirst() }
        if parts.first?.lowercased() == "embed" { parts.removeFirst() }
        if parts.count >= 4, parts[0].lowercased() == "user", parts[2].lowercased() == "playlist" {
            return ("playlist", stripQuery(parts[3]))
        }
        guard parts.count >= 2 else { return nil }
        let type = parts[0].lowercased()
        guard types.contains(type) else { return nil }
        return (type, stripQuery(parts[1]))
    }

    static func canonicalOpenURL(_ url: URL) -> URL? {
        guard let resource = resource(from: url) else { return nil }
        return URL(string: "https://open.spotify.com/\(resource.type)/\(resource.id)")
    }

    static func embedURL(from url: URL) -> URL? {
        guard let resource = resource(from: url) else { return nil }
        return URL(string: "https://open.spotify.com/embed/\(resource.type)/\(resource.id)?utm_source=generator")
    }

    static func compactEmbed(_ url: URL) -> Bool {
        guard let type = resource(from: url)?.type else { return true }
        return type == "track" || type == "episode"
    }

    static func displayKind(_ url: URL) -> String {
        switch resource(from: url)?.type {
        case "artist": "artist"
        case "playlist": "playlist"
        case "album": "album"
        case "episode": "episode"
        case "show": "show"
        default: "track"
        }
    }

    private static func resourceFromURI(_ raw: String) -> (type: String, id: String)? {
        let bits = raw.split(separator: ":").map(String.init)
        guard bits.count >= 3, bits[0].lowercased() == "spotify" else { return nil }
        if bits.count >= 5, bits[1].lowercased() == "user", bits[3].lowercased() == "playlist" {
            return ("playlist", bits[4])
        }
        let type = bits[1].lowercased()
        guard types.contains(type) else { return nil }
        return (type, bits[2])
    }

    private static func stripQuery(_ value: String) -> String {
        String(value.split(separator: "?").first ?? Substring(value))
    }
}

enum ProcessingStatus: String, Codable {
    case saved, processing, ready, failed
}
