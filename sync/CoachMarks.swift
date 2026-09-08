import SwiftUI

enum CoachSpot: String, Hashable {
    case settings, howTo, collections, ask, forYou, save, searchBar, stories
    case books, library, hero
    case fypSearch, fypVoice, fypMute, fypRefresh
}

struct CoachStep: Identifiable {
    var id: CoachSpot { spot }
    var spot: CoachSpot
    var title: String
    var body: String
}

enum CoachTour {
    static let completedKey = "hasCompletedCoachTour"
    static let restartKey = "restartCoachTour"
    static let fypCompletedKey = "hasCompletedFYPCoachTour"
    static let fypRestartKey = "restartFYPCoachTour"

    static let home: [CoachStep] = [
        CoachStep(spot: .howTo, title: "How to use", body: "Open the full guide any time. Replay this tour from Settings too."),
        CoachStep(spot: .searchBar, title: "Search", body: "Find a save or ask across everything you’ve kept."),
        CoachStep(spot: .save, title: "Save", body: "Paste a link or write a note without leaving Home."),
        CoachStep(spot: .hero, title: "Featured course", body: "Tap the hero to jump into a path. Lessons swipe like cards and pick up where you left off."),
        CoachStep(spot: .collections, title: "Continue learning", body: "Your course catalog. See all opens every path."),
        CoachStep(spot: .books, title: "Book courses", body: "Book-length courses with summaries and lessons, not just a reading list."),
        CoachStep(spot: .library, title: "Your library", body: "Recent saves from share sheet, paste, and notes. See all opens the full library."),
        CoachStep(spot: .stories, title: "Today’s news", body: "A few headlines on Home. The News tab has Top, U.S., World, and the rest."),
        CoachStep(spot: .forYou, title: "Tabs", body: "Home, For you, Learn, News, and You. For you is the full-screen story feed."),
    ]

    static let fyp: [CoachStep] = [
        CoachStep(spot: .fypSearch, title: "Search topics", body: "Pull live headlines on a person, place, or beat."),
        CoachStep(spot: .fypVoice, title: "Voice", body: "Pick who reads the briefing. You’ll hear a sample first."),
        CoachStep(spot: .fypMute, title: "Mute", body: "Silence the card. Tap the photo to mute or unmute too."),
        CoachStep(spot: .fypRefresh, title: "Refresh", body: "Clear seen stories and mix a new feed from your saves."),
    ]
}

struct CoachAnchorKey: PreferenceKey {
    static var defaultValue: [CoachSpot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CoachSpot: Anchor<CGRect>], nextValue: () -> [CoachSpot: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct CollectCoachKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var collectCoachAnchors: Bool {
        get { self[CollectCoachKey.self] }
        set { self[CollectCoachKey.self] = newValue }
    }
}

private struct CoachSpotModifier: ViewModifier {
    let spot: CoachSpot
    @Environment(\.collectCoachAnchors) private var collect

    func body(content: Content) -> some View {
        if collect {
            content.anchorPreference(key: CoachAnchorKey.self, value: .bounds) { [spot: $0] }
        } else {
            content
        }
    }
}

extension View {
    func coachSpot(_ spot: CoachSpot) -> some View {
        modifier(CoachSpotModifier(spot: spot))
    }

    func coachTour(
        _ steps: [CoachStep],
        isPresented: Binding<Bool>,
        blocksTouches: Bool = true,
        onStepChange: @escaping (CoachSpot) -> Void = { _ in },
        onFinished: @escaping () -> Void = {}
    ) -> some View {
        modifier(CoachMarksOverlay(
            steps: steps,
            isPresented: isPresented,
            blocksTouches: blocksTouches,
            onStepChange: onStepChange,
            onFinished: onFinished
        ))
    }
}

struct CoachMarksOverlay: ViewModifier {
    let steps: [CoachStep]
    @Binding var isPresented: Bool
    var blocksTouches = true
    var onStepChange: (CoachSpot) -> Void = { _ in }
    var onFinished: () -> Void = {}
    @State private var index = 0

    func body(content: Content) -> some View {
        content
            .environment(\.collectCoachAnchors, isPresented)
            .overlayPreferenceValue(CoachAnchorKey.self) { anchors in
                if isPresented, !steps.isEmpty {
                    GeometryReader { geo in
                        let step = steps[min(index, steps.count - 1)]
                        let hole = anchors[step.spot].map { geo[$0].insetBy(dx: -6, dy: -6) }
                        ZStack(alignment: .topLeading) {
                            Canvas { ctx, size in
                                var path = Path(CGRect(origin: .zero, size: size))
                                if let hole {
                                    path.addRoundedRect(
                                        in: hole,
                                        cornerSize: CGSize(width: 16, height: 16)
                                    )
                                }
                                ctx.fill(path, with: .color(.black.opacity(0.52)), style: FillStyle(eoFill: true))
                            }
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { advance() }

                            if let hole {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SyncTheme.paper, lineWidth: 2)
                                    .frame(width: hole.width, height: hole.height)
                                    .offset(x: hole.minX, y: hole.minY)
                                    .allowsHitTesting(false)
                            }

                            bubble(for: step, hole: hole, in: geo.size)
                        }
                    }
                }
            }
            .onChange(of: isPresented) { _, on in
                if on {
                    index = 0
                    announceStep()
                }
            }
            .onChange(of: index) { _, _ in
                announceStep()
            }
    }

    private func announceStep() {
        guard isPresented, !steps.isEmpty else { return }
        onStepChange(steps[min(index, steps.count - 1)].spot)
    }

    private func bubble(for step: CoachStep, hole: CGRect?, in size: CGSize) -> some View {
        let placeBelow: Bool = {
            guard let hole else { return true }
            return hole.midY < size.height * 0.45
        }()
        return VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SyncTheme.ink)
            Text(step.body)
                .font(.system(size: 15))
                .foregroundStyle(SyncTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip") { finish() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SyncTheme.inkMuted)
                Spacer()
                Text("\(index + 1) of \(steps.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SyncTheme.inkMuted)
                Button(index == steps.count - 1 ? "Done" : "Next") { advance() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SyncTheme.paper)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(SyncTheme.ink)
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .frame(width: min(300, size.width - 32))
        .background(SyncTheme.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SyncTheme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.leading, bubbleOffset(hole: hole, placeBelow: placeBelow, in: size).width)
        .padding(.top, bubbleOffset(hole: hole, placeBelow: placeBelow, in: size).height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(2)
    }

    private func bubbleOffset(hole: CGRect?, placeBelow: Bool, in size: CGSize) -> CGSize {
        let width = min(300, size.width - 32)
        guard let hole else {
            return CGSize(width: 16, height: size.height - 220)
        }
        var x = hole.midX - width / 2
        x = min(max(16, x), size.width - width - 16)
        let y = placeBelow ? hole.maxY + 12 : hole.minY - 148
        return CGSize(width: x, height: max(12, y))
    }

    private func advance() {
        if index >= steps.count - 1 {
            finish()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { index += 1 }
        }
    }

    private func finish() {
        isPresented = false
        onFinished()
    }
}
