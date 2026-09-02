import SwiftUI
import UIKit
import SafariServices

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var next: AppAppearance {
        switch self {
        case .system, .light: .dark
        case .dark: .light
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

enum SyncTheme {
    static let paper = dynamic(
        light: UIColor(red: 0.957, green: 0.945, blue: 0.922, alpha: 1),
        dark: UIColor.black
    )
    static let paperRaised = dynamic(
        light: UIColor.white,
        dark: UIColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 1)
    )
    static let elevated = dynamic(
        light: UIColor(white: 0.97, alpha: 1),
        dark: UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1)
    )
    static let ink = dynamic(
        light: UIColor(red: 0.165, green: 0.286, blue: 0.220, alpha: 1),
        dark: UIColor.white
    )
    static let inkMuted = dynamic(
        light: UIColor(red: 0.35, green: 0.38, blue: 0.36, alpha: 1),
        dark: UIColor(white: 1, alpha: 0.60)
    )
    static let inkTertiary = dynamic(
        light: UIColor(red: 0.45, green: 0.47, blue: 0.45, alpha: 1),
        dark: UIColor(white: 1, alpha: 0.36)
    )
    static let line = dynamic(
        light: UIColor(red: 0.165, green: 0.286, blue: 0.220, alpha: 0.14),
        dark: UIColor(white: 1, alpha: 0.10)
    )
    static let highlight = dynamic(
        light: UIColor(red: 0.93, green: 0.88, blue: 0.76, alpha: 1),
        dark: UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct SyncScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SyncTheme.paper.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(SyncTheme.ink)
    }
}

extension View {
    func syncScreen() -> some View {
        modifier(SyncScreenModifier())
    }

    func syncPullToRefresh(_ action: @escaping () async -> Void) -> some View {
        scrollBounceBehavior(.always, axes: .vertical)
            .background(ScrollBounceFix())
            .refreshable { await action() }
    }
}

private struct ScrollBounceFix: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { Self.enable(from: uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.enable(from: uiView) }
    }

    private static func enable(from view: UIView) {
        var node: UIView? = view
        while let current = node {
            if let scroll = current as? UIScrollView {
                scroll.alwaysBounceVertical = true
                scroll.bounces = true
                return
            }
            node = current.superview
        }
    }
}

struct NavIconPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(SyncTheme.line, lineWidth: 1))
    }
}

struct NavIconButton<Label: View>: View {
    let accessibility: String
    var tint: Color = SyncTheme.ink
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum SharePrompt {
    @MainActor
    static func show(_ items: [Any]) {
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let host = topViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 8, height: 8)
            popover.permittedArrowDirections = []
        }
        host.present(activity, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

enum OutboundLink {
    static func prefersNativeApp(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let names = [
            "tiktok.com", "instagram.com", "youtube.com", "youtu.be",
            "spotify.com", "twitter.com", "x.com", "reddit.com",
        ]
        return names.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func open(_ url: URL) -> Bool {
        guard prefersNativeApp(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

struct InAppPage: Identifiable {
    let id: URL
    var url: URL { id }
}

struct SafariTab: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = UIColor(SyncTheme.ink)
        safari.preferredBarTintColor = UIColor(SyncTheme.paper)
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct AppearanceToggle: View {
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        Button {
            let current = AppAppearance(rawValue: appearanceRaw) ?? .system
            appearanceRaw = current.next.rawValue
        } label: {
            Image(systemName: (AppAppearance(rawValue: appearanceRaw) ?? .system).symbol)
                .foregroundStyle(SyncTheme.ink)
        }
        .accessibilityLabel("Toggle appearance")
    }
}

struct ShimmerText: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    @State private var shine = -0.6

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(SyncTheme.inkMuted)
            .overlay {
                Text(text)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: SyncTheme.inkMuted, location: 0),
                                .init(color: SyncTheme.ink.opacity(0.35), location: 0.35),
                                .init(color: SyncTheme.paper, location: 0.5),
                                .init(color: SyncTheme.ink.opacity(0.35), location: 0.65),
                                .init(color: SyncTheme.inkMuted, location: 1)
                            ],
                            startPoint: UnitPoint(x: shine, y: 0.5),
                            endPoint: UnitPoint(x: shine + 0.55, y: 0.5)
                        )
                    )
            }
            .onAppear {
                shine = -0.6
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    shine = 1.15
                }
            }
    }
}
