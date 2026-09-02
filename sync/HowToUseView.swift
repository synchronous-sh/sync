import SwiftUI

struct HowToUseView: View {
    var isFirstRun = false
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pages: [WalkPage] = WalkPage.all

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        WalkPageView(page: item)
                            .tag(index)
                            .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? SyncTheme.ink : SyncTheme.line)
                            .frame(width: index == page ? 22 : 8, height: 8)
                    }
                    Spacer()
                    Button(primaryLabel) {
                        if page == pages.count - 1 {
                            finish()
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SyncTheme.paper)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(SyncTheme.ink)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .navigationTitle("How to use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFirstRun ? "Skip" : "Close") { finish() }
                        .foregroundStyle(SyncTheme.inkMuted)
                }
            }
        }
    }

    private var primaryLabel: String {
        if page < pages.count - 1 { return "Next" }
        return isFirstRun ? "Open library" : "Done"
    }

    private func finish() {
        if let onFinished {
            onFinished()
        } else {
            dismiss()
        }
    }
}

private struct WalkPage {
    var title: String
    var body: String
    var rows: [(symbol: String, name: String, meaning: String)]

    static let all: [WalkPage] = [
        WalkPage(
            title: "Your library for the internet",
            body: "Share TikToks, Spotify, links, screenshots, and notes into sync. It reads them quietly. Later you search, ask, or catch up on For you.",
            rows: [
                ("square.and.arrow.up", "Share", "From TikTok, Instagram, Safari, Spotify, Photos. Share and pick sync."),
                ("plus", "Paste", "On Home, tap + if you already copied a link or want a note."),
                ("info.circle", "This guide", "Always on Home, top left, if you want a recap."),
            ]
        ),
        WalkPage(
            title: "Home",
            body: "The top bar is how you move. Logo in the middle. Tools on the sides.",
            rows: [
                ("gearshape", "Settings", "Appearance, voice, export, account."),
                ("info.circle", "How to use", "This walkthrough."),
                ("square.stack", "Collections", "Folders that fill from topics in your saves."),
                ("sparkles", "Search / Ask", "Find a save or ask across the library."),
                ("play.square.stack", "For you", "Full-screen news from what you save."),
                ("plus", "Save", "Paste a URL or write a note."),
            ]
        ),
        WalkPage(
            title: "Saves",
            body: "Tap a card on Home or Recent. You get a summary, topics, and the original.",
            rows: [
                ("sparkles", "Ask this save", "Chat about the transcript, frames, or notes. The thread stays on that save."),
                ("magnifyingglass", "Search", "Titles, people, topics, and the words inside saves."),
                ("arrow.down.to.line", "Pull to refresh", "On Home, pull down to re-read new saves."),
            ]
        ),
        WalkPage(
            title: "For you: the feed",
            body: "Stories are full-screen photos with a briefing. Swipe up and down like a story stack. It keeps loading as you go.",
            rows: [
                ("hand.tap", "Tap the card", "Mute or unmute. Same as the speaker icon at the top. Unmute continues from where it stopped."),
                ("arrow.up.arrow.down", "Swipe vertically", "Next or previous briefing."),
                ("arrow.left", "Swipe left", "Open the full summary page for this story: source, date, save, ask."),
                ("arrow.down", "Pull down on the first card", "Rebuild the feed from your library."),
            ]
        ),
        WalkPage(
            title: "For you: top icons",
            body: "Dark bar at the top of the feed.",
            rows: [
                ("chevron.left", "Back", "Return to Home."),
                ("waveform", "Voice", "Pick an ElevenLabs voice. You’ll hear a sample, then the card re-speaks."),
                ("speaker.wave.2.fill", "Mute", "Silence the briefing. Slash means it’s muted."),
                ("arrow.clockwise", "Refresh", "Clear seen stories and pull a new mix from your saves."),
            ]
        ),
        WalkPage(
            title: "For you: on the card",
            body: "Bottom of each briefing.",
            rows: [
                ("safari", "Read source", "Opens the original article in a tab in the app."),
                ("bookmark", "Save", "On the summary page, keep this briefing in your library."),
                ("square.and.arrow.up", "Share", "Sends a link to synchronous.sh/article/… with your briefing."),
                ("sparkles", "Ask", "Chat about this story. Replies type out word by word."),
                ("text.alignleft", "Why this", "If it came from a save, jumps to that item in your library."),
            ]
        ),
        WalkPage(
            title: "Talk to the AI",
            body: "Sparkles opens Ask. Type a question. While it thinks you’ll see sparkles with a light sweeping across. Then the answer streams in. Lists use real bullets.",
            rows: [
                ("sparkles", "On a save", "Ask what they said, what’s on screen, or what to remember."),
                ("sparkles", "On For you", "Ask about the briefing, numbers, or why it matters."),
                ("sparkles", "From Home search", "Ask across everything you’ve saved."),
                ("bubble.left.and.bubble.right", "Threads", "Conversations stay on that save or story. Clear if you want a fresh start."),
            ]
        ),
        WalkPage(
            title: "Voice",
            body: "For you can speak the briefing. Pick a voice in Settings or from the waveform on the feed.",
            rows: [
                ("waveform", "Voice", "ElevenLabs voices. You’ll hear a sample, then the card re-speaks."),
                ("speaker.wave.2.fill", "Mute", "Silence the briefing from the top of For you."),
            ]
        ),
    ]
}

private struct WalkPageView: View {
    let page: WalkPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(page.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
                    .padding(.top, 8)
                Text(page.body)
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .lineSpacing(4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(page.rows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SyncTheme.ink)
                                .frame(width: 36, height: 36)
                                .background(SyncTheme.paper)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(SyncTheme.ink)
                                Text(row.meaning)
                                    .font(.system(size: 15))
                                    .foregroundStyle(SyncTheme.inkMuted)
                                    .lineSpacing(3)
                            }
                        }
                        .padding(.vertical, 12)
                        if index < page.rows.count - 1 {
                            Divider().overlay(SyncTheme.line)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SyncTheme.line, lineWidth: 1)
                )
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}
