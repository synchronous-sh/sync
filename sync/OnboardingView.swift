import SwiftUI

struct OnboardingView: View {
    var onContinue: () -> Void
    @State private var step = 0

    private let pages: [(title: String, body: String)] = [
        ("Everything you want\nto remember.", "One library for TikToks, Spotify, links, screenshots, and notes."),
        ("See it. Share it.\nDone.", "TikTok, Instagram, Spotify, Safari, Photos → share → sync."),
        ("Find it later.", "Search, related saves, and collections fill themselves in."),
    ]

    var body: some View {
        ZStack {
            SyncTheme.paper.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .background(SyncTheme.paperRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(SyncTheme.line, lineWidth: 1)
                    )
                    .padding(.top, 12)

                Spacer()

                Text(pages[step].title)
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(pages[step].body)
                    .font(.system(size: 20))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? SyncTheme.ink : SyncTheme.line)
                            .frame(width: index == step ? 22 : 8, height: 8)
                    }
                    Spacer()
                }
                .padding(.bottom, 20)

                Button {
                    if step < pages.count - 1 {
                        withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
                    } else {
                        onContinue()
                    }
                } label: {
                    Text(step < pages.count - 1 ? "Continue" : "Open library")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SyncTheme.ink)
                        .foregroundStyle(SyncTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
        }
    }
}
