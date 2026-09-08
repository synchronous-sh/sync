import SwiftUI
import SwiftData

struct YouTabView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AccountSession.nameKey) private var displayName = ""
    @AppStorage(AccountSession.usernameKey) private var username = ""
    @AppStorage(AccountSession.bioKey) private var bio = ""
    @State private var tab: ProfileTab = .saved

    private enum ProfileTab: String, CaseIterable {
        case saved = "Library"
        case courses = "Courses"
        case collections = "Collections"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(SyncTheme.ink)
                        Text(initial)
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(SyncTheme.paper)
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName.isEmpty ? "You" : displayName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(SyncTheme.ink)
                        if !username.isEmpty {
                            Text("@\(username)")
                                .font(.system(size: 13))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                        Text(bio.isEmpty ? "Share from TikTok, YouTube, and the rest of the internet." : bio)
                            .font(.system(size: 13))
                            .foregroundStyle(SyncTheme.inkMuted)
                    }
                    Spacer()
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(SyncTheme.ink)
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.top, 8)

                HStack {
                    stat("\(saves.count)", "Saves")
                    stat("\(LearningCatalog.paths.filter { LearningProgress.fraction(for: $0) > 0 }.count)", "Paths")
                    stat("\(LearningProgress.completed().count)", "Lessons")
                }
                .padding(.top, 20)

                HStack {
                    ForEach(ProfileTab.allCases, id: \.self) { item in
                        Button {
                            tab = item
                        } label: {
                            VStack(spacing: 10) {
                                Text(item.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(tab == item ? SyncTheme.ink : SyncTheme.inkMuted)
                                Rectangle()
                                    .fill(tab == item ? SyncTheme.ink : .clear)
                                    .frame(width: 28, height: 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 26)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SyncTheme.line).frame(height: 1)
                }

                Group {
                    switch tab {
                    case .saved:
                        if saves.isEmpty {
                            empty("bookmark", "Share a TikTok, Reel, video, or article to fill your library.")
                        } else {
                            ForEach(saves) { save in
                                NavigationLink(value: Route.save(save.saveID)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: save.source.symbol)
                                            .font(.system(size: 16))
                                            .foregroundStyle(SyncTheme.ink)
                                            .frame(width: 52, height: 52)
                                            .background(SyncTheme.paperRaised)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(save.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(SyncTheme.ink)
                                                .lineLimit(2)
                                            Text(save.source.label)
                                                .font(.system(size: 12))
                                                .foregroundStyle(SyncTheme.inkMuted)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(SyncTheme.inkTertiary)
                                    }
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    case .courses:
                        ForEach(LearningCatalog.paths) { path in
                            NavigationLink(value: Route.course(path.id)) {
                                HStack(spacing: 12) {
                                    CourseArtwork(pathID: path.id, title: path.title)
                                        .frame(width: 64, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(path.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(SyncTheme.ink)
                                        Text("\(Int(LearningProgress.fraction(for: path) * Double(path.lessons.count))) of \(path.lessons.count) lessons")
                                            .font(.system(size: 12))
                                            .foregroundStyle(SyncTheme.inkMuted)
                                        ProgressBar(value: LearningProgress.fraction(for: path))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(SyncTheme.inkTertiary)
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    case .collections:
                        NavigationLink(value: Route.collections) {
                            HStack {
                                Text("All collections")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(SyncTheme.ink)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(SyncTheme.inkTertiary)
                            }
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.plain)
                        NavigationLink(value: Route.library) {
                            HStack {
                                Text("Full library")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(SyncTheme.ink)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(SyncTheme.inkTertiary)
                            }
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .syncPullToRefresh {
            LibraryBrain.pull(context: modelContext)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Route.self) { DestinationRouter(route: $0) }
    }

    private var initial: String {
        String(displayName.prefix(1)).uppercased().isEmpty ? "S" : String(displayName.prefix(1)).uppercased()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(SyncTheme.ink)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(SyncTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func empty(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(SyncTheme.inkTertiary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(SyncTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
