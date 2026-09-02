import SwiftUI
import UIKit

struct NewsTabView: View {
    private let categories = ["For You", "U.S.", "World", "History", "Business", "Technology", "Science", "Entertainment", "Lifestyle", "Food", "Sports"]
    @State private var category = "For You"
    @State private var headlines: [NewsHeadline] = []
    @State private var loading = true
    @State private var failed = false
    @State private var openURL: InAppPage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(categories, id: \.self) { item in
                            Button {
                                category = item
                            } label: {
                                Text(item)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(category == item ? SyncTheme.ink : SyncTheme.inkTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                }

                if loading {
                    ProgressView()
                        .tint(SyncTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if failed && headlines.isEmpty {
                    Text("Live articles are temporarily unavailable. Pull down to retry.")
                        .font(.system(size: 14))
                        .foregroundStyle(SyncTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 40)
                } else {
                    ForEach(Array(headlines.enumerated()), id: \.element.url) { index, story in
                        Button {
                            if let url = URL(string: story.url) {
                                if !OutboundLink.open(url) {
                                    openURL = InAppPage(id: url)
                                }
                            }
                        } label: {
                            NewsStoryBlock(story: story, compact: index > 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .syncPullToRefresh { await load(force: true) }
        .task(id: category) { await load() }
        .sheet(item: $openURL) { page in
            SafariTab(url: page.url)
                .ignoresSafeArea()
        }
    }

    private func load(force: Bool = false) async {
        if !force { loading = true }
        failed = false
        let query = NewsTabView.query(for: category)
        let items = await FeedNews.stories(for: query, limit: 16, skipSeen: false)
        headlines = items
        failed = items.isEmpty
        loading = false
    }

    static func query(for category: String) -> String {
        switch category {
        case "For You": "top stories"
        case "U.S.": "United States news"
        case "World": "world news"
        case "History": "history archaeology"
        case "Business": "business markets"
        case "Technology": "technology"
        case "Science": "science"
        case "Entertainment": "entertainment"
        case "Lifestyle": "lifestyle"
        case "Food": "food cooking"
        case "Sports": "sports"
        default: category
        }
    }
}

struct NewsStoryBlock: View {
    let story: NewsHeadline
    var compact: Bool
    @State private var picture: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                SyncTheme.paperRaised
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(height: compact ? 190 : 255)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text((story.source.isEmpty ? "News" : story.source).uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(SyncTheme.inkMuted)
                .padding(.top, 16)
            Text(story.title)
                .font(.system(size: 25, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(SyncTheme.ink)
                .padding(.top, 7)
            Text(story.snippet.isEmpty ? "Open the original report for the complete story." : story.snippet)
                .font(.system(size: 16))
                .foregroundStyle(SyncTheme.ink.opacity(0.72))
                .padding(.top, 8)
            Text((story.publishedAt.map(FeedNews.dateLine) ?? "Recently") + (story.source.isEmpty ? "" : "  ·  \(story.source)"))
                .font(.system(size: 12))
                .foregroundStyle(SyncTheme.inkTertiary)
                .padding(.top, 12)
            Text("Understand this  →")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SyncTheme.ink)
                .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SyncTheme.line)
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
        .task { await loadPicture() }
    }

    private func loadPicture() async {
        guard let url = story.imageURL else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        picture = image
    }
}
