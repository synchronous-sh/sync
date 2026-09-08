import SwiftUI
import UIKit
import SafariServices

// #region agent log
enum AgentDebug {
    static func log(_ hyp: String, _ loc: String, _ msg: String, _ data: [String: Any] = [:]) {
        DispatchQueue.global(qos: .utility).async {
            let payload: [String: Any] = [
                "sessionId": "ca08bb",
                "hypothesisId": hyp,
                "location": loc,
                "message": msg,
                "timestamp": Date().timeIntervalSince1970 * 1000,
                "data": data
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let path = "/Users/aadikatyal/Dev/synchronous/sync/.cursor/debug-ca08bb.log"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(json)
                handle.write(Data([0x0A]))
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: json + Data([0x0A]))
            }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:7565/ingest/d21a2c93-da16-4e0a-b4e2-7d3385321591")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("ca08bb", forHTTPHeaderField: "X-Debug-Session-Id")
            request.httpBody = json
            request.timeoutInterval = 1
            URLSession.shared.dataTask(with: request).resume()
        }
    }
}
// #endregion

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

    func syncPullToRefresh(caption: String = "Fetching stories", _ action: @escaping () async -> Void) -> some View {
        modifier(BrandRefreshModifier(caption: caption, action: action))
    }

    func syncSwipeBack() -> some View {
        modifier(SwipeBackModifier())
    }
}

private struct SwipeBackInstalledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var swipeBackInstalled: Bool {
        get { self[SwipeBackInstalledKey.self] }
        set { self[SwipeBackInstalledKey.self] = newValue }
    }
}

private struct SwipeBackModifier: ViewModifier {
    @Environment(\.swipeBackInstalled) private var alreadyInstalled

    func body(content: Content) -> some View {
        if alreadyInstalled {
            content
        } else {
            content
                .background(SwipeBackEnabler())
                .environment(\.swipeBackInstalled, true)
        }
    }
}

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.arm()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            arm()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            arm()
        }

        func arm() {
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            guard let nav = navigationController ?? parent?.navigationController else { return }
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct BrandRefreshModifier: ViewModifier {
    var caption: String
    var action: () async -> Void
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.always, axes: .vertical)
            .background(ScrollBounceFix())
            .background(BrandRefreshHook(inverted: colorScheme == .dark, caption: caption, action: action))
    }
}

struct SyncRefreshMark: View {
    var inverted: Bool
    var caption = "Fetching stories"

    var body: some View {
        HStack(spacing: 10) {
            SparkleThinking(label: "", iconSize: 32, inverted: inverted, brandIcon: true)
                .frame(width: 32, height: 32)
            Text(caption)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle((inverted ? Color.white : SyncTheme.ink).opacity(0.82))
        }
    }
}

private struct BrandRefreshHook: UIViewRepresentable {
    var inverted: Bool
    var caption: String
    var action: () async -> Void

    func makeCoordinator() -> Watcher { Watcher() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.inverted = inverted
        context.coordinator.caption = caption
        context.coordinator.action = action
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { context.coordinator.attach(from: uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { context.coordinator.attach(from: uiView) }
    }

    final class Watcher: NSObject {
        var inverted = true
        var caption = "Fetching stories"
        var action: () async -> Void = {}
        private weak var scroll: UIScrollView?
        private var refreshing = false
        private var host: UIHostingController<SyncRefreshMark>?
        private var offsetWatch: NSKeyValueObservation?

        func attach(from view: UIView) {
            if let found = nearestVerticalScroll(from: view) {
                hook(found)
            }
        }

        private func isVerticalList(_ scroll: UIScrollView) -> Bool {
            guard scroll.bounds.height > 90 else { return false }
            return scroll.contentSize.width <= scroll.bounds.width + 40
        }

        private func firstVertical(in view: UIView) -> UIScrollView? {
            var found: [UIScrollView] = []
            collectScrolls(in: view, into: &found)
            return found.filter(isVerticalList).max { $0.bounds.height < $1.bounds.height }
        }

        private func nearestVerticalScroll(from view: UIView) -> UIScrollView? {
            var node: UIView? = view
            while let current = node {
                if let scroll = current as? UIScrollView, isVerticalList(scroll) {
                    return scroll
                }
                if let parent = current.superview, let found = firstVertical(in: parent) {
                    return found
                }
                node = current.superview
            }
            return nil
        }

        private func collectScrolls(in view: UIView, into result: inout [UIScrollView]) {
            if let scroll = view as? UIScrollView {
                result.append(scroll)
            }
            for child in view.subviews {
                collectScrolls(in: child, into: &result)
            }
        }

        private func hook(_ scroll: UIScrollView) {
            if self.scroll !== scroll {
                self.scroll?.refreshControl = nil
                offsetWatch = nil
                self.scroll = scroll
                offsetWatch = scroll.observe(\.contentOffset, options: .new) { [weak self] scroll, _ in
                    self?.updateMarkVisibility(on: scroll)
                }
            }
            scroll.alwaysBounceVertical = true
            scroll.bounces = true
            installRefresh(on: scroll)
            updateMarkVisibility(on: scroll)
        }

        private func installRefresh(on scroll: UIScrollView) {
            if host == nil {
                let next = UIHostingController(rootView: SyncRefreshMark(inverted: inverted, caption: caption))
                next.view.backgroundColor = .clear
                next.view.isUserInteractionEnabled = false
                next.view.alpha = 0
                host = next
            } else {
                host?.rootView = SyncRefreshMark(inverted: inverted, caption: caption)
            }
            let refresh = scroll.refreshControl ?? UIRefreshControl()
            refresh.tintColor = .clear
            if scroll.refreshControl == nil {
                refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
                scroll.refreshControl = refresh
            }
            guard let mark = host?.view else { return }
            if mark.superview !== refresh {
                mark.removeFromSuperview()
                refresh.addSubview(mark)
                mark.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    mark.centerXAnchor.constraint(equalTo: refresh.centerXAnchor),
                    mark.bottomAnchor.constraint(equalTo: refresh.bottomAnchor, constant: -6),
                    mark.heightAnchor.constraint(equalToConstant: 52),
                    mark.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
                ])
            }
            hideSpinners(in: refresh)
        }

        private func updateMarkVisibility(on scroll: UIScrollView) {
            let pull = -scroll.contentOffset.y - scroll.adjustedContentInset.top
            host?.view.alpha = (refreshing || pull > 18) ? 1 : min(1, max(0, (pull - 8) / 28))
        }

        private func hideSpinners(in view: UIView) {
            for child in view.subviews {
                if child === host?.view { continue }
                if child is UIActivityIndicatorView || String(describing: type(of: child)).contains("Refresh") {
                    child.alpha = 0
                }
                hideSpinners(in: child)
            }
        }

        @objc private func pulled() {
            guard let scroll, !refreshing else { return }
            refreshing = true
            hideSpinners(in: scroll.refreshControl ?? UIView())
            updateMarkVisibility(on: scroll)
            Task { @MainActor in
                await action()
                scroll.refreshControl?.endRefreshing()
                self.refreshing = false
                if let scroll = self.scroll {
                    self.updateMarkVisibility(on: scroll)
                }
            }
        }
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
