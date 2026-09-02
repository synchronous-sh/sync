import SwiftUI
import SwiftData

@main
struct SyncApp: App {
    init() {
        _ = InboxPingListener.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(LibraryContainer.shared)
    }
}

struct RootView: View {
    @AppStorage(AccountSession.userIDKey) private var userID = ""
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.light.rawValue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        ZStack {
            if showSplash {
                SplashView()
                    .transition(.opacity)
            } else if userID.isEmpty {
                SignInView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: showSplash)
        .animation(.easeInOut(duration: 0.45), value: userID)
        .tint(SyncTheme.ink)
        .preferredColorScheme(appearance.colorScheme)
        .task {
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeOut(duration: 0.35)) {
                showSplash = false
            }
        }
        .onOpenURL { url in
            ingestDeepLink(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                CaptureService.importInbox(into: modelContext)
                CaptureService.enrichUnprocessed(in: modelContext)
            }
            if phase == .inactive || phase == .background {
                try? modelContext.save()
            }
        }
        .onAppear {
            DemoLibraryPurge.run(in: modelContext)
            drainPending(into: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .synchronousInbox)) { _ in
            CaptureService.importInbox(into: modelContext)
            CaptureService.enrichUnprocessed(in: modelContext)
        }
    }

    private func ingestDeepLink(_ url: URL) {
        guard let parsed = CaptureDeepLink.parse(url) else { return }
        if parsed.id == nil {
            _ = CaptureService.ingest(
                urlString: parsed.url,
                text: parsed.text,
                imageData: nil,
                context: modelContext
            )
            try? modelContext.save()
        }
        AppGroup.defaults?.removeObject(forKey: "pendingDeepLink")
        CaptureService.enrichUnprocessed(in: modelContext)
    }

    private func drainPending(into context: ModelContext) {
        if let raw = AppGroup.defaults?.string(forKey: "pendingDeepLink"),
           let url = URL(string: raw) {
            AppGroup.defaults?.removeObject(forKey: "pendingDeepLink")
            ingestDeepLink(url)
        }
        CaptureService.importInbox(into: context)
        CaptureService.enrichUnprocessed(in: context)
    }
}

extension Notification.Name {
    static let synchronousInbox = Notification.Name("synchronousInbox")
}

final class InboxPingListener {
    static let shared = InboxPingListener()

    private init() {
        let name = CFNotificationName(AppGroup.pingName)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .synchronousInbox, object: nil)
                }
            },
            AppGroup.pingName,
            nil,
            .deliverImmediately
        )
        _ = name
    }
}
