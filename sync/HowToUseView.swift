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
            body: "Share TikToks, YouTube, Instagram, Spotify, Safari links, screenshots, and notes into sync. It reads them quietly. Later you search, ask, learn, or catch up on For you and News.",
            rows: [
                ("square.and.arrow.up", "Share", "From another app, share and pick sync. The item lands in your library."),
                ("plus", "Paste", "On Home, tap + if you already copied a link or want a note."),
                ("info.circle", "This guide", "Info on Home, or You → Settings → How to use."),
            ]
        ),
        WalkPage(
            title: "The five tabs",
            body: "Everything lives on the bar at the bottom.",
            rows: [
                ("house", "Home", "Courses, book courses, your library, and a few headlines."),
                ("play.fill", "For you", "Full-screen photo briefings. Swipe like a story stack. Voice can read them."),
                ("book.fill", "Learn", "XP, course shelves, and lessons you swipe through like cards."),
                ("newspaper.fill", "News", "Top, U.S., World, History, Business, and the rest. Search stories."),
                ("person.fill", "You", "Profile, library, courses you’ve started, collections, and Settings."),
            ]
        ),
        WalkPage(
            title: "Home",
            body: "Greeting up top. Tools on the right. Scroll for learning, books, saves, and news.",
            rows: [
                ("info.circle", "How to use", "This walkthrough. Replay the spotlight tour from Settings."),
                ("magnifyingglass", "Search", "Find a save or ask across the library."),
                ("plus", "Save", "Paste a URL or write a note."),
                ("sparkles", "Featured course", "Hero card jumps into a path. Progress is kept."),
                ("arrow.down.to.line", "Pull to refresh", "Re-read new saves and refresh Home news."),
            ]
        ),
        WalkPage(
            title: "Courses",
            body: "Continue learning on Home, or open the Learn tab for the full catalog and your XP.",
            rows: [
                ("rectangle.stack", "See all", "Opens every course path."),
                ("book", "Learn tab", "Level, XP, and shelves by topic."),
                ("rectangle.on.rectangle", "Lessons", "Swipe sideways like flashcards. Continue picks up the page you were on."),
                ("checkmark.circle", "Quiz", "Some lessons end in a quiz. Completing marks the lesson done."),
            ]
        ),
        WalkPage(
            title: "Book courses",
            body: "These are full courses built from books — summaries plus lessons — not a bookshelf of covers only.",
            rows: [
                ("book.closed", "On Home", "The Book courses row. See all opens the complete list."),
                ("text.book.closed", "Inside a book", "Same lesson player as courses: swipe pages, resume, quiz."),
                ("person.crop.rectangle", "On You", "Courses you’ve started, including book courses, show under Courses."),
            ]
        ),
        WalkPage(
            title: "Your library",
            body: "Saves from share, paste, and notes. Tap a card for the summary, topics, and original.",
            rows: [
                ("square.and.arrow.up", "Share sheet", "TikTok, Instagram, Safari, Spotify, Photos → sync."),
                ("sparkles", "Ask this save", "Chat about the transcript, frames, or notes. The thread stays on that save."),
                ("folder", "Collections", "Folders that fill from topics in your saves. On You → Collections."),
                ("magnifyingglass", "Search", "Titles, people, topics, and the words inside saves."),
            ]
        ),
        WalkPage(
            title: "News",
            body: "Home shows a few headlines. The News tab is the full list, loaded in the background while you use the app.",
            rows: [
                ("newspaper", "Categories", "Top, U.S., World, History, Business, Technology, Science, and more."),
                ("magnifyingglass", "Search stories", "Look up a person, company, or beat."),
                ("photo", "Photos", "Stories with pictures show them on the card."),
                ("arrow.up.right", "Understand this", "Opens the briefing page: source, date, save, ask, share."),
            ]
        ),
        WalkPage(
            title: "For you: the feed",
            body: "Stories are full-screen photos with a briefing. Swipe up and down. It keeps loading as you go.",
            rows: [
                ("hand.tap", "Mute on the photo", "A small tap in the center mutes or unmutes. Save and Ask do not pause the audio."),
                ("arrow.up.arrow.down", "Swipe vertically", "Next or previous briefing."),
                ("arrow.left", "Swipe left", "Full summary: source, date, save, ask."),
                ("arrow.down", "Pull down on the first card", "Rebuild the feed."),
            ]
        ),
        WalkPage(
            title: "For you: top icons",
            body: "Dark bar at the top of the feed. Categories sit under it: For You, Business, Technology, and the rest.",
            rows: [
                ("magnifyingglass", "Search", "Live headlines on a person, place, or beat. It does not fill from the category chips."),
                ("waveform", "Voice", "ElevenLabs voices. You’ll hear a sample, then the card re-speaks. Default is Laura."),
                ("speaker.wave.2.fill", "Mute", "Silence the briefing. Slash means it’s muted."),
                ("arrow.clockwise", "Refresh", "Clear seen stories and mix a new feed."),
            ]
        ),
        WalkPage(
            title: "For you: on the card",
            body: "Actions along the briefing.",
            rows: [
                ("safari", "Read source", "Original article in-app."),
                ("bookmark", "Save", "Keep this briefing in your library."),
                ("square.and.arrow.up", "Share", "A link on synchronous.sh with your briefing."),
                ("sparkles", "Ask", "Chat about this story. Replies type out word by word."),
                ("text.alignleft", "Why this", "If it came from a save, jumps to that item."),
            ]
        ),
        WalkPage(
            title: "Ask",
            body: "Sparkles opens Ask. While it thinks you’ll see sparkles. Then the answer streams in.",
            rows: [
                ("sparkles", "On a save", "What they said, what’s on screen, or what to remember."),
                ("sparkles", "On For you or News", "The briefing, the numbers, or why it matters."),
                ("sparkles", "From Home search", "Ask across everything you’ve saved."),
                ("bubble.left.and.bubble.right", "Threads", "Stay on that save or story. Clear for a fresh start."),
            ]
        ),
        WalkPage(
            title: "You and Settings",
            body: "Profile, library, courses, collections. Gear opens Settings.",
            rows: [
                ("gearshape", "Settings", "Appearance, voice, export, account, API keys if you need them."),
                ("map", "Walk through Home", "Replay the spotlight tour. Home scrolls to each row."),
                ("play.square.stack", "Walk through For you", "Replay the feed tour."),
                ("square.and.arrow.up", "Export", "Download your saves as JSON. Sign out does not delete the library on device until you wipe it."),
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
