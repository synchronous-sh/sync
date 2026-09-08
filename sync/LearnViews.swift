import SwiftUI
import SwiftData
import AVFoundation
import UIKit

private let learnBlack = SyncTheme.paper
private let learnWhite = SyncTheme.ink
private let learnSecondary = SyncTheme.inkMuted
private let learnTertiary = SyncTheme.inkTertiary
private let learnBorder = SyncTheme.line
private let learnCard = SyncTheme.paperRaised

struct LearnView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @State private var shelves: [CourseShelf] = LearningCatalog.shelves
    @State private var completedLessons = 0
    @State private var showDesigner = false
    @State private var openDesigned = false
    @State private var designedPathID = ""

    private var xp: Int { completedLessons * 180 }
    private let levelTarget = 2000
    private var levelProgress: Double {
        min(1, Double(xp) / Double(levelTarget))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                hero
                metrics
                catalogHeader
                VStack(spacing: 0) {
                    ForEach(shelves) { shelf in
                        CourseShelfView(shelf: shelf)
                    }
                }
            }
            .padding(.bottom, 105)
        }
        .syncPullToRefresh(caption: "Fetching courses") {
            TasteEngine.ingest(Array(saves))
            refreshShelves()
            let snapshot = Array(saves)
            Task {
                await CourseStudio.refresh(from: snapshot, force: true)
                refreshShelves()
            }
        }
        .background(learnBlack.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Route.self) { route in
            DestinationRouter(route: route)
                .onDisappear { refreshShelves() }
        }
        .navigationDestination(isPresented: $openDesigned) {
            CourseOverviewView(pathID: designedPathID)
        }
        .sheet(isPresented: $showDesigner, onDismiss: {
            if !designedPathID.isEmpty { openDesigned = true }
        }) {
            DesignCourseSheet { path in
                designedPathID = path.id
                refreshShelves()
                showDesigner = false
            }
        }
        .onAppear { refreshShelves() }
        .task {
            if CourseStudio.generated.isEmpty {
                await CourseStudio.refresh(from: Array(saves))
            }
            refreshShelves()
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Image("BrainLevel1")
                .resizable()
                .scaledToFit()
                .frame(width: 235, height: 225)
            Text("LEVEL 1")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(learnSecondary)
                .padding(.top, -7)
            Text("CURIOUS")
                .font(.system(size: 21, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(learnWhite)
                .padding(.top, 5)
            Text("\(xp.formatted()) / \(levelTarget.formatted()) XP")
                .font(.system(size: 10))
                .foregroundStyle(learnSecondary)
                .padding(.top, 5)
            ProgressBar(value: levelProgress)
                .frame(width: 184)
                .padding(.top, 9)
            HStack(spacing: 2) {
                Text("View progress")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(learnSecondary)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(symbol: "flame", value: "\(max(completedLessons, 0)) days", label: "streak")
            Rectangle().fill(learnBorder).frame(width: 1, height: 42)
            metric(symbol: "clock", value: learningTime, label: "learning time")
            Rectangle().fill(learnBorder).frame(width: 1, height: 42)
            metric(symbol: "book", value: "\(completedLessons)", label: "lessons")
        }
        .frame(height: 82)
        .overlay(alignment: .top) { Rectangle().fill(learnBorder).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(learnBorder).frame(height: 1) }
        .padding(.horizontal, 20)
    }

    private var learningTime: String {
        let minutes = max(completedLessons, 1) * 18
        let hours = minutes / 60
        let mins = minutes % 60
        if completedLessons == 0 { return "0m" }
        if hours == 0 { return "\(mins)m" }
        return "\(hours)h \(mins)m"
    }

    private func metric(symbol: String, value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(learnWhite)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(learnWhite)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(learnSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var catalogHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Courses")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(learnWhite)
                Spacer()
                Button {
                    showDesigner = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(learnWhite)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Design a course")
            }
            Text("Pick up where you left off or explore something new.")
                .font(.system(size: 13))
                .foregroundStyle(learnSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 27)
        .padding(.bottom, 5)
    }

    private func refreshShelves() {
        shelves = LearningCatalog.liveShelves(saves: Array(saves))
        completedLessons = LearningCatalog.paths.reduce(0) { sum, path in
            sum + path.lessons.filter { LearningProgress.isComplete(pathID: path.id, lesson: $0.title) }.count
        }
    }
}

struct DesignCourseSheet: View {
    var onDesigned: (LearningPath) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var brief = ""
    @State private var working = false
    @State private var error = ""
    @FocusState private var focused: Bool

    private var canDesign: Bool {
        brief.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 && !working
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Say what you want to learn. We’ll turn it into a course with lessons and a path.")
                    .font(.system(size: 15))
                    .foregroundStyle(learnSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("I want to learn how interest rates affect housing, from scratch", text: $brief, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(learnWhite)
                    .lineLimit(4...8)
                    .focused($focused)
                    .padding(14)
                    .background(learnCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(learnBorder, lineWidth: 1)
                    )

                if working {
                    SparkleThinking(label: "Designing course", iconSize: 28, inverted: true, brandIcon: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                } else if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(learnSecondary)
                }

                Spacer()

                Button {
                    Task { await design() }
                } label: {
                    Text("Design course")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SyncTheme.paper)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(canDesign ? SyncTheme.ink : SyncTheme.ink.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canDesign)
            }
            .padding(20)
            .background(learnBlack.ignoresSafeArea())
            .navigationTitle("New course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(learnWhite)
                }
            }
            .toolbarBackground(learnBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func design() async {
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return }
        if !IntelligenceKey.isConfigured {
            error = "Add an intelligence key in Settings to design courses."
            return
        }
        working = true
        error = ""
        if let path = await CourseStudio.design(from: text) {
            working = false
            onDesigned(path)
            return
        }
        working = false
        error = "Couldn’t design that course. Try a clearer topic."
    }
}

struct CourseShelfView: View {
    let shelf: CourseShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(shelf.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(learnWhite)
                Spacer()
                NavigationLink(value: seeAllRoute) {
                    Text("See all ›")
                        .font(.system(size: 12))
                        .foregroundStyle(learnSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 11) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: Route.course(item.pathID)) {
                            if item.pathID.hasPrefix("book-") {
                                BookCoverCard(item: item, ink: learnWhite, muted: learnSecondary)
                            } else {
                                CourseCardView(item: item, onDark: true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 24)
    }

    private var seeAllRoute: Route {
        let books = shelf.title.localizedCaseInsensitiveContains("book")
            || (!shelf.items.isEmpty && shelf.items.allSatisfy { $0.pathID.hasPrefix("book-") })
        return books ? .books : .courses
    }
}

struct CourseCardView: View {
    let item: CourseCard
    var onDark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CourseArtwork(pathID: item.pathID, title: item.title)
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(8)
            }
            .frame(width: 166, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            if let progress = item.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        SyncTheme.line
                        SyncTheme.ink
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
                .offset(y: -3)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 8,
                        bottomTrailingRadius: 8
                    )
                )
            }
        }
        .frame(width: 166, alignment: .leading)
    }
}

struct BookCoverCard: View {
    let item: CourseCard
    var ink: Color = SyncTheme.ink
    var muted: Color = SyncTheme.inkMuted

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 118, height: 176)
                .overlay {
                    CourseArtwork(pathID: item.pathID, title: item.title)
                }
            if needsPrintedTitle {
                Text(item.title)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(8)
            }
        }
        .frame(width: 118, height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    private var needsPrintedTitle: Bool {
        ["book-habits", "book-money", "book-lean"].contains(item.pathID)
    }
}

struct BookSummariesListView: View {
    @Environment(\.dismiss) private var dismiss
    private let books = LearningCatalog.bookSummaries
    private let columns = [
        GridItem(.adaptive(minimum: 118, maximum: 140), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(books) { item in
                    NavigationLink(value: Route.course(item.pathID)) {
                        BookCoverCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("Book courses")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SyncTheme.ink)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(SyncTheme.paper)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct CourseCatalogListView: View {
    @Environment(\.dismiss) private var dismiss
    private let courses = LearningCatalog.courseCards
    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(courses) { item in
                    NavigationLink(value: Route.course(item.pathID)) {
                        CourseCardView(item: item, onDark: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SyncTheme.ink)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("Courses")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SyncTheme.ink)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(SyncTheme.paper)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct LessonHero: View {
    let pathID: String
    let course: String
    let lesson: String
    let slide: String
    let page: Int
    @State private var photo: UIImage?
    @State private var waiting = true

    var body: some View {
        ZStack {
            learnCard
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if waiting {
                SparkleThinking(label: "", iconSize: 28, inverted: true, brandIcon: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { logHero(geo: geo.size) }
                    .onChange(of: photo != nil) { _, _ in logHero(geo: geo.size) }
            }
        )
        .task(id: "\(pathID).\(page).\(slide)") {
            photo = nil
            waiting = true
            // #region agent log
            AgentDebug.log("G", "LessonHero.task", "start", [
                "page": page,
                "gen": pathID.hasPrefix("gen-")
            ])
            // #endregion
            if let generated = await LessonArt.load(
                course: course,
                pathID: pathID,
                lesson: lesson,
                slide: slide,
                page: page
            ) {
                photo = generated
            }
            waiting = false
            logHero(geo: nil)
        }
    }

    private func logHero(geo: CGSize?) {
        let img = photo
        let screen = UIScreen.main.bounds.size
        let fillZoom: Double
        if let img, let geo, geo.width > 1, geo.height > 1 {
            let sx = geo.width / img.size.width
            let sy = geo.height / img.size.height
            fillZoom = Double(max(sx, sy))
        } else {
            fillZoom = 0
        }
        // #region agent log
        AgentDebug.log("A", "LessonHero.layout", "sizes", [
            "page": page,
            "boxW": geo?.width ?? -1,
            "boxH": geo?.height ?? -1,
            "imgW": img?.size.width ?? 0,
            "imgH": img?.size.height ?? 0,
            "screenW": screen.width,
            "fillZoom": fillZoom,
            "mode": "fit",
            "runId": "post-fix",
            "waiting": waiting
        ])
        // #endregion
    }
}

struct CourseArtwork: View {
    var pathID: String
    var title: String = ""

    var body: some View {
        Group {
            if pathID.hasPrefix("gen-") {
                LessonHero(pathID: pathID, course: title, lesson: title, slide: title, page: 0)
            } else if let name = CourseCovers.assetName(title: title, pathID: pathID) {
                Image(name)
                    .resizable()
                    .scaledToFill()
            } else {
                learnCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(learnCard)
        .onAppear {
            let name = CourseCovers.assetName(title: title, pathID: pathID)
            // #region agent log
            AgentDebug.log("G", "CourseArtwork", "paint", [
                "pathID": pathID,
                "name": name ?? "",
                "found": name.flatMap { UIImage(named: $0) } != nil,
                "gen": pathID.hasPrefix("gen-")
            ])
            // #endregion
        }
    }
}

enum CourseCovers {
    private static let catalog: [String] = [
        "cover-ai-foundations", "cover-applied-ai", "cover-artificial-intelligence",
        "cover-astronomy", "cover-atomic-habits", "cover-behavioral-science",
        "cover-business-economics", "cover-business-strategy", "cover-computing-software",
        "cover-cooking-science", "cover-core-science", "cover-deep-work", "cover-design",
        "cover-digital-product-design", "cover-economic-history", "cover-economics",
        "cover-finance", "cover-finance-essentials", "cover-food-business", "cover-food-chemistry",
        "cover-history-of-design", "cover-human-biology", "cover-human-intelligence",
        "cover-influence", "cover-management", "cover-market-economics", "cover-markets-investing",
        "cover-mental-health-foundations", "cover-movement-recovery", "cover-performance-psychology",
        "cover-physics-of-sport", "cover-political-economy", "cover-political-history",
        "cover-psychology", "cover-public-opinion", "cover-range", "cover-sapiens",
        "cover-science", "cover-space", "cover-sports-science", "cover-technology",
        "cover-technology-for-ai", "cover-the-design-of-everyday-things",
        "cover-the-intelligent-investor", "cover-the-lean-startup",
        "cover-the-psychology-of-money", "cover-thinking-fast-and-slow", "cover-world-history"
    ]

    private static let pathFallback: [String: String] = [
        "ai": "cover-artificial-intelligence",
        "finance": "cover-finance-essentials",
        "history": "cover-world-history",
        "science": "cover-core-science",
        "business": "cover-business-strategy",
        "technology": "cover-computing-software",
        "psychology": "cover-psychology",
        "space": "cover-astronomy",
        "cooking": "cover-cooking-science",
        "sports": "cover-sports-science",
        "economics": "cover-economics",
        "design": "cover-digital-product-design",
        "book-habits": "cover-atomic-habits",
        "book-thinking": "cover-thinking-fast-and-slow",
        "book-money": "cover-the-psychology-of-money",
        "book-lean": "cover-the-lean-startup",
        "book-design": "cover-the-design-of-everyday-things",
        "book-sapiens": "cover-sapiens",
        "book-range": "cover-range",
        "book-deep-work": "cover-deep-work",
        "book-investor": "cover-the-intelligent-investor",
        "book-influence": "cover-influence"
    ]

    private static let families: [(tokens: Set<String>, covers: [String])] = [
        (["ai", "agent", "llm", "gpt", "neural", "transformer", "prompt"],
         ["cover-applied-ai", "cover-ai-foundations", "cover-artificial-intelligence", "cover-technology-for-ai"]),
        (["software", "code", "programming", "computer", "network", "robot", "chip"],
         ["cover-computing-software", "cover-technology"]),
        (["invest", "stock", "bond", "portfolio", "valuation", "finance", "money", "bank"],
         ["cover-markets-investing", "cover-finance-essentials", "cover-the-intelligent-investor", "cover-the-psychology-of-money"]),
        (["startup", "founder", "venture", "lean", "company", "strategy", "manage", "leader"],
         ["cover-the-lean-startup", "cover-business-strategy", "cover-management"]),
        (["economics", "economy", "economic", "trade", "markets", "incentive", "policy"],
         ["cover-economics", "cover-market-economics", "cover-business-economics", "cover-political-economy"]),
        (["history", "empire", "ancient", "civilization", "political", "politics"],
         ["cover-world-history", "cover-political-history", "cover-economic-history", "cover-sapiens"]),
        (["psychology", "mind", "behavior", "habit", "emotion", "cognition", "brain"],
         ["cover-psychology", "cover-behavioral-science", "cover-human-intelligence", "cover-thinking-fast-and-slow"]),
        (["sport", "athletic", "fitness", "training", "recovery", "muscle"],
         ["cover-sports-science", "cover-movement-recovery", "cover-physics-of-sport", "cover-performance-psychology"]),
        (["cook", "kitchen", "recipe", "chef", "food", "flavor"],
         ["cover-cooking-science", "cover-food-chemistry", "cover-food-business"]),
        (["space", "planet", "star", "galaxy", "nasa", "orbit", "astro", "cosmos"],
         ["cover-space", "cover-astronomy"]),
        (["biology", "body", "gene", "health", "therapy"],
         ["cover-human-biology", "cover-mental-health-foundations", "cover-science"]),
        (["design", "ux", "interface", "product"],
         ["cover-digital-product-design", "cover-design", "cover-history-of-design", "cover-the-design-of-everyday-things"]),
        (["focus", "attention", "deep"],
         ["cover-deep-work", "cover-range", "cover-atomic-habits"])
    ]

    static func assetName(title: String, pathID: String) -> String? {
        pageAsset(title: title, pathID: pathID, page: 0)
    }

    static func pageAsset(title: String, pathID: String, page: Int) -> String? {
        let slug = slugify(title)
        var pool = pagePool(title: title, pathID: pathID)
        if !slug.isEmpty, catalog.contains("cover-\(slug)") {
            pool.removeAll { $0 == "cover-\(slug)" }
            pool.insert("cover-\(slug)", at: 0)
        } else if let named = pathFallback[pathID], catalog.contains(named) {
            pool.removeAll { $0 == named }
            pool.insert(named, at: 0)
        }
        guard !pool.isEmpty else { return "cover-science" }
        let idx = abs(page) % pool.count
        return pool[idx]
    }

    static func newsStill(interest: String, title: String = "", vertical: Bool = false) -> String {
        let blob = "\(interest) \(title)".lowercased()
        let key: String
        if blob.contains("sport") || blob.contains("nba") || blob.contains("nfl") || blob.contains("soccer") {
            key = "sports"
        } else if blob.contains("ai") || blob.contains("tech") || blob.contains("software") || blob.contains("chip") {
            key = "tech"
        } else if blob.contains("market") || blob.contains("stock") || blob.contains("bank") || blob.contains("econom") || blob.contains("finance") || blob.contains("business") {
            key = "markets"
        } else if blob.contains("science") || blob.contains("health") || blob.contains("climate") || blob.contains("space") {
            key = "science"
        } else if blob.contains("politic") || blob.contains("elect") || blob.contains("senate") || blob.contains("war") {
            key = "politics"
        } else {
            key = "world"
        }
        return vertical ? "still-fyp-\(key)" : "still-news-\(key)"
    }

    private static func slugify(_ title: String) -> String {
        title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }

    private static func tokens(_ raw: String) -> Set<String> {
        Set(
            raw.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )
    }

    private static func pagePool(title: String, pathID: String) -> [String] {
        let blob = tokens("\(title) \(pathID) \(LearningCatalog.path(id: pathID)?.description ?? "")")
        var best: (score: Int, covers: [String])?
        for family in families {
            let hits = family.tokens.intersection(blob)
            let score = hits.reduce(0) { $0 + $1.count }
            if score > 0, best == nil || score > best!.score {
                best = (score, family.covers)
            }
        }
        var pool = best?.covers ?? []
        for name in catalog where !pool.contains(name) {
            pool.append(name)
        }
        return pool.isEmpty ? catalog : pool
    }
}

struct CourseOverviewView: View {
    let pathID: String
    var displayTitle: String? = nil
    var displayDescription: String? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = FeedSpeaker()
    @State private var showVoice = false
    @State private var saved = false
    @State private var downloaded = false
    @State private var showingPath = false

    private var path: LearningPath? { LearningCatalog.path(id: pathID) }
    private var titleText: String { displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? path?.title ?? "" }
    private var descriptionText: String { displayDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? path?.description ?? "" }

    private static let similar: [String: [String]] = [
        "ai": ["technology", "psychology", "science"],
        "finance": ["economics", "business", "history"],
        "history": ["economics", "design", "psychology"],
        "science": ["space", "technology", "psychology"],
        "business": ["finance", "economics", "design"],
        "technology": ["ai", "design", "science"],
        "psychology": ["science", "sports", "design"],
        "space": ["science", "technology", "history"],
        "cooking": ["science", "business", "psychology"],
        "sports": ["psychology", "science", "business"],
        "economics": ["finance", "business", "history"],
        "design": ["technology", "psychology", "business"],
        "book-habits": ["psychology", "sports", "book-deep-work"],
        "book-thinking": ["psychology", "book-influence", "science"],
        "book-money": ["finance", "economics", "book-investor"],
        "book-lean": ["business", "technology", "book-range"],
        "book-design": ["design", "technology", "psychology"],
        "book-sapiens": ["history", "economics", "science"],
        "book-range": ["psychology", "book-thinking", "business"],
        "book-deep-work": ["psychology", "book-habits", "book-range"],
        "book-investor": ["finance", "book-money", "economics"],
        "book-influence": ["psychology", "business", "book-thinking"]
    ]

    var body: some View {
        Group {
            if showingPath {
                CourseDetailView(pathID: pathID, onBack: { showingPath = false })
            } else if let path {
                let similarIDs = Self.similar[path.id] ?? []
                let recommendedIDs = TasteEngine.rankCourses(LearningCatalog.courseCards)
                    .map(\.pathID)
                    .filter { $0 != path.id }
                    .prefix(6)

                GeometryReader { geo in
                    VStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                CourseArtwork(pathID: path.id, title: titleText)
                                    .frame(width: geo.size.width, height: 280)
                                    .clipped()
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.55)],
                                    startPoint: .center,
                                    endPoint: .bottom
                                )
                                Button { dismiss() } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.48))
                                        .clipShape(Circle())
                                }
                                .accessibilityLabel("Back")
                                .padding(.top, 12)
                                .padding(.leading, 14)

                                HStack(spacing: 9) {
                                    Button { showVoice = true } label: {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(width: 38, height: 38)
                                    }
                                    .accessibilityLabel("Voice")
                                    Button {
                                        if speaker.isPlaying { speaker.toggleMute() }
                                        else { speakCourse() }
                                    } label: {
                                        Image(systemName: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(width: 38, height: 38)
                                    }
                                    .accessibilityLabel(speaker.isMuted ? "Unmute" : "Listen")
                                    Button { saved.toggle() } label: {
                                        Image(systemName: saved ? "bookmark.fill" : "bookmark")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(width: 38, height: 38)
                                    }
                                    Button { downloaded.toggle() } label: {
                                        Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(width: 38, height: 38)
                                    }
                                    ShareLink(item: "\(titleText)\n\(descriptionText)") {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(width: 38, height: 38)
                                    }
                                }
                                .padding(.leading, 16)
                                .padding(.bottom, 16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            }
                            .frame(width: geo.size.width, height: 280)
                            .clipped()

                            VStack(alignment: .leading, spacing: 0) {
                                Text(path.title.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1)
                                    .foregroundStyle(learnSecondary)
                                    .padding(.horizontal, 11)
                                    .frame(height: 25)
                                    .overlay(
                                        Capsule().stroke(learnBorder, lineWidth: 1)
                                    )

                                Text(titleText)
                                    .font(.system(size: 31, weight: .bold))
                                    .tracking(-0.7)
                                    .foregroundStyle(learnWhite)
                                    .padding(.top, 13)

                                HStack(spacing: 7) {
                                    Text("\(path.lessons.count) lessons")
                                    Circle().fill(learnTertiary).frame(width: 3, height: 3)
                                    Text("15–20 min each")
                                    Circle().fill(learnTertiary).frame(width: 3, height: 3)
                                    Text("Beginner friendly")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(learnSecondary)
                                .padding(.top, 10)

                                Text("What you’ll learn")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(learnWhite)
                                    .padding(.top, 22)

                                Text("\(descriptionText) Build knowledge cumulatively through guided explanations, worked examples, applications, and required mastery checks.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(learnWhite.opacity(0.72))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 8)

                                courseRow(title: "Similar courses", link: "More courses", ids: similarIDs, width: geo.size.width)
                                courseRow(title: "Recommended courses", link: "For you", ids: Array(recommendedIDs), width: geo.size.width)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 21)
                            .padding(.bottom, 24)
                            .frame(width: geo.size.width, alignment: .leading)
                        }
                        .frame(width: geo.size.width, alignment: .leading)
                    }

                    Button {
                        showingPath = true
                    } label: {
                        Text("Start")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SyncTheme.paper)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(SyncTheme.ink)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .padding(.top, 8)
                    .background(learnBlack)
                    }
                }
            } else {
                Text("This course is gone.")
                    .foregroundStyle(learnSecondary)
            }
        }
        .background(learnBlack.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { LearningProgress.opened(pathID) }
        .onDisappear { speaker.stop() }
        .sheet(isPresented: $showVoice, onDismiss: {
            speaker.applyVoice()
        }) {
            NavigationStack {
                FeedVoicePicker {
                    speaker.applyVoice()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func speakCourse() {
        let spoken = [titleText, descriptionText].filter { !$0.isEmpty }.joined(separator: ". ")
        guard !spoken.isEmpty else { return }
        speaker.isMuted = false
        speaker.speakRaw(spoken, id: LessonStudio.speechID("course.\(pathID)"))
    }

    private func courseRow(title: String, link: String, ids: [String], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(learnWhite)
                Spacer()
                Text(link)
                    .font(.system(size: 13))
                    .foregroundStyle(learnSecondary)
            }
            .padding(.top, 26)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(ids, id: \.self) { id in
                        if let other = LearningCatalog.path(id: id) {
                            NavigationLink(value: Route.course(other.id)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    CourseArtwork(pathID: other.id, title: other.title)
                                        .frame(width: 166, height: 94)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    Text(other.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(learnWhite)
                                        .lineLimit(1)
                                }
                                .frame(width: 166, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: max(0, width - 40), alignment: .leading)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CourseDetailView: View {
    let pathID: String
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var refresh = 0

    private var path: LearningPath? { LearningCatalog.path(id: pathID) }
    private let offsets: [CGFloat] = [0, -74, 0, 74]
    private let unitTitles = ["Foundations", "Build understanding", "Apply the ideas", "Advanced mastery"]

    var body: some View {
        Group {
            if let path {
                let completed = path.lessons.filter { LearningProgress.isComplete(pathID: path.id, lesson: $0.title) }.count
                let progress = path.lessons.isEmpty ? 0 : Double(completed) / Double(path.lessons.count)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(learnWhite)
                                    .frame(width: 48, height: 48)
                                Image(systemName: "graduationcap.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(SyncTheme.paper)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("COURSE")
                                    .font(.system(size: 9, weight: .heavy))
                                    .tracking(1.4)
                                    .foregroundStyle(learnSecondary)
                                Text(path.title)
                                    .font(.system(size: 25, weight: .bold))
                                    .tracking(-0.5)
                                    .foregroundStyle(learnWhite)
                                Text(path.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(learnSecondary)
                                    .lineSpacing(3)
                            }
                        }
                        .padding(18)
                        .background(learnCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(learnBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        HStack {
                            Text("\(completed) of \(path.lessons.count) lessons")
                            Spacer()
                            Text("\(Int(progress * 100))%")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(learnSecondary)
                        .padding(.top, 15)

                        ProgressBar(value: progress)
                            .padding(.top, 7)

                        pathMap(path: path)
                            .id(refresh)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 70)
                }
            } else {
                Text("This path is gone.")
                    .foregroundStyle(learnSecondary)
            }
        }
        .background(learnBlack.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            HStack {
                Button {
                    if let onBack {
                        onBack()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(learnWhite)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("Course path")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(learnSecondary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .background(learnBlack)
        }
        .onAppear { refresh += 1 }
    }

    private func pathMap(path: LearningPath) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(path.lessons.enumerated()), id: \.element.id) { index, lesson in
                let done = LearningProgress.isComplete(pathID: path.id, lesson: lesson.title)
                let unlocked = done || index == 0 || LearningProgress.isComplete(pathID: path.id, lesson: path.lessons[index - 1].title)
                let active = unlocked && !done
                let offset = offsets[index % offsets.count]
                let unitStart = index % 4 == 0

                VStack(spacing: 0) {
                    if unitStart {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("UNIT \(index / 4 + 1)")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(1.4)
                                .foregroundStyle(learnSecondary)
                            Text(unitTitles[min(3, index / 4)])
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(learnWhite)
                            Text("Lessons \(index + 1)–\(min(index + 4, path.lessons.count))")
                                .font(.system(size: 12))
                                .foregroundStyle(learnSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(learnCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(learnBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 11)
                    }

                    Group {
                        if unlocked {
                            NavigationLink(value: Route.lesson(path.id, index)) {
                                lessonNode(index: index, lesson: lesson, done: done, active: active, unlocked: unlocked)
                            }
                            .buttonStyle(.plain)
                        } else {
                            lessonNode(index: index, lesson: lesson, done: done, active: active, unlocked: unlocked)
                        }
                    }
                    .offset(x: offset)
                }
                .padding(.top, index == 0 ? 38 : 18)
            }

            HStack(spacing: 9) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 22))
                Text("Course complete")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(LearningProgress.fraction(for: path) >= 1 ? SyncTheme.ink : learnTertiary)
            .frame(width: 150, height: 54)
            .background(learnCard)
            .overlay(
                Capsule().stroke(learnBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func lessonNode(index: Int, lesson: LearningLesson, done: Bool, active: Bool, unlocked: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(active ? SyncTheme.ink.opacity(0.25) : SyncTheme.line)
                    .frame(width: 76, height: 76)
                    .offset(y: 3)
                Circle()
                    .fill(done || active ? SyncTheme.ink : SyncTheme.elevated)
                    .overlay(
                        Circle().stroke(done || active ? SyncTheme.ink : SyncTheme.line, lineWidth: 2)
                    )
                    .frame(width: 70, height: 70)
                Group {
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 26, weight: .bold))
                    } else if active {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .padding(.leading, 3)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(learnTertiary)
                    }
                }
                .foregroundStyle(done || active ? SyncTheme.paper : learnTertiary)
            }

            VStack(spacing: 2) {
                Text("LESSON \(index + 1)")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(learnTertiary)
                Text(lesson.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(unlocked ? learnWhite : learnTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(done ? "Completed · Review" : active ? "15–20 min · Start" : "Locked")
                    .font(.system(size: 9))
                    .foregroundStyle(learnSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, active ? 7 : 0)
            .frame(minWidth: 150, maxWidth: 190)
            .background(active ? learnCard : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(active ? learnBorder : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(width: 185)
    }
}

struct LessonDetailView: View {
    let pathID: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = FeedSpeaker()
    @State private var showVoice = false
    @State private var step = 0
    @State private var lessonIndex: Int
    @State private var quizAnswers: [Int] = []
    @State private var pendingAnswer: Int? = nil
    @State private var score: Int? = nil
    @State private var complete = false
    @State private var slides: [RahulSlide] = []
    @State private var quizzes: [RahulQuiz] = []
    @State private var asking = false

    init(pathID: String, index: Int) {
        self.pathID = pathID
        _lessonIndex = State(initialValue: index)
        if let path = LearningCatalog.path(id: pathID), path.lessons.indices.contains(index) {
            let lesson = path.lessons[index]
            let cards = RahulSlide.cards(path: path, lesson: lesson)
            let checks = RahulQuiz.mastery(path: path, lesson: lesson)
            _slides = State(initialValue: cards)
            _quizzes = State(initialValue: checks)
            let saved = LearningProgress.resumePage(pathID: pathID, lesson: lesson.title)
            let total = cards.count + checks.count
            _step = State(initialValue: total > 0 ? min(saved, total - 1) : 0)
            var answers = LearningProgress.resumeQuiz(pathID: pathID, lesson: lesson.title)
            if answers.count < checks.count {
                answers.append(contentsOf: Array(repeating: -1, count: checks.count - answers.count))
            }
            _quizAnswers = State(initialValue: answers)
        }
    }

    private var path: LearningPath? { LearningCatalog.path(id: pathID) }
    private var lesson: LearningLesson? {
        guard let path, path.lessons.indices.contains(lessonIndex) else { return nil }
        return path.lessons[lessonIndex]
    }
    private var totalSteps: Int { slides.count + quizzes.count }
    private var quizStep: Bool { step >= slides.count }
    private var quizIndex: Int { max(0, step - slides.count) }
    private var activeQuiz: RahulQuiz? { quizzes.indices.contains(quizIndex) ? quizzes[quizIndex] : nil }

    var body: some View {
        Group {
            if complete {
                completionScreen
            } else if let s = score {
                scoreScreen(s)
            } else if slides.isEmpty {
                loadingScreen
            } else {
                lessonScreen
            }
        }
        .background(learnBlack.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            LearningProgress.opened(pathID)
            loadLesson(reset: false)
        }
        .onChange(of: lessonIndex) { _, _ in loadLesson(reset: false) }
        .onChange(of: step) { _, _ in
            pendingAnswer = quizStep ? pendingChoice(for: quizIndex) : nil
            persistResume()
            speakStep()
        }
        .onDisappear {
            persistResume()
            speaker.stop()
        }
        .sheet(isPresented: $showVoice, onDismiss: {
            speaker.applyVoice()
        }) {
            NavigationStack {
                FeedVoicePicker {
                    speaker.applyVoice()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: Loading
    private var loadingScreen: some View {
        VStack(spacing: 16) {
            SparkleThinking(label: "Building lesson")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(learnBlack)
    }

    // MARK: Main lesson screen
    private var lessonScreen: some View {
        SafeAreaAwareLesson(
            step: step,
            totalSteps: totalSteps,
            estimatedMinutes: 18,
            muted: speaker.isMuted,
            scrollContent: false,
            onClose: {
                speaker.stop()
                // #region agent log
                AgentDebug.log("N", "LessonDetail.onClose", "dismiss", ["lessonIndex": lessonIndex])
                // #endregion
                dismiss()
            },
            onVoice: { showVoice = true },
            onSpeaker: { toggleLessonAudio() },
            onAsk: { asking = true },
            footer: { footerButton },
            content: {
                TabView(selection: $step) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, _ in
                        ScrollView(showsIndicators: false) {
                            slideContent(at: index)
                        }
                        .tag(index)
                    }
                    ForEach(Array(quizzes.enumerated()), id: \.offset) { index, _ in
                        ScrollView(showsIndicators: false) {
                            quizContent(at: index)
                        }
                        .tag(slides.count + index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            // #region agent log
                            AgentDebug.log("B", "LessonTabView", "box", [
                                "w": geo.size.width,
                                "h": geo.size.height,
                                "screenW": UIScreen.main.bounds.width
                            ])
                            // #endregion
                        }
                    }
                )
            }
        )
        .sheet(isPresented: $asking) {
            if let path, let lesson {
                LessonAskSheet(path: path, lesson: lesson)
                    .presentationDetents([.medium, .large])
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(SyncTheme.paper)
            }
        }
    }

    @ViewBuilder
    private func slideContent(at index: Int) -> some View {
        let slide = slides[index]
        VStack(alignment: .leading, spacing: 0) {
            LessonHero(
                pathID: pathID,
                course: path?.title ?? "",
                lesson: lesson?.plainTitle ?? "",
                slide: slide.title,
                page: index
            )
            .id("\(pathID).\(index).\(slide.title)")
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 25)

            Text(slide.eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(learnSecondary)

            Text(slide.title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.7)
                .foregroundStyle(learnWhite)
                .padding(.top, 10)

            Text(slide.body)
                .font(.system(size: 17))
                .foregroundStyle(learnWhite.opacity(0.78))
                .lineSpacing(6)
                .padding(.top, 17)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(learnWhite)
                    .frame(width: 2)
                    .padding(.trailing, 16)
                Text(slide.callout)
                    .font(.system(size: 14))
                    .foregroundStyle(learnSecondary)
                    .lineSpacing(5)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 25)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    // #region agent log
                    AgentDebug.log("B", "slideContent", "box", [
                        "index": index,
                        "w": geo.size.width,
                        "h": geo.size.height,
                        "screenW": UIScreen.main.bounds.width
                    ])
                    // #endregion
                }
            }
        )
    }

    @ViewBuilder
    private func quizContent(at index: Int) -> some View {
        if quizzes.indices.contains(index) {
            let quiz = quizzes[index]
            let chosen = pendingChoice(for: index)
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(learnCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(learnBorder, lineWidth: 1)
                        )
                    Image(systemName: "graduationcap")
                        .font(.system(size: 25))
                        .foregroundStyle(learnWhite)
                }
                .frame(width: 48, height: 48)
                .padding(.bottom, 22)

                Text("Mastery check · \(index + 1) of \(quizzes.count)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(learnSecondary)

                Text(quiz.question)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.7)
                    .foregroundStyle(learnWhite)
                    .padding(.top, 10)

                Text("Choose the best answer. Your score will be shown after all \(quizzes.count) questions.")
                    .font(.system(size: 15))
                    .foregroundStyle(learnSecondary)
                    .lineSpacing(5)
                    .padding(.top, 13)
                    .padding(.bottom, 20)

                ForEach(Array(quiz.options.enumerated()), id: \.offset) { i, option in
                    let selected = chosen == i
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        chooseQuizAnswer(i, at: index)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(selected ? SyncTheme.ink : Color.clear)
                                    .overlay(Circle().stroke(learnBorder, lineWidth: 1))
                                    .frame(width: 28, height: 28)
                                Text(String(UnicodeScalar(65 + i)!))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(selected ? SyncTheme.paper : learnSecondary)
                            }
                            Text(option)
                                .font(.system(size: 14))
                                .foregroundStyle(selected ? SyncTheme.paper : learnWhite)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(13)
                        .frame(minHeight: 72, alignment: .center)
                        .background(selected ? SyncTheme.ink : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(learnBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 11)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 25)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pendingChoice(for index: Int) -> Int? {
        guard quizAnswers.indices.contains(index), quizAnswers[index] >= 0 else { return nil }
        return quizAnswers[index]
    }

    private func chooseQuizAnswer(_ answer: Int, at index: Int) {
        pendingAnswer = answer
        if quizAnswers.count < quizzes.count {
            quizAnswers.append(contentsOf: Array(repeating: -1, count: quizzes.count - quizAnswers.count))
        }
        if quizAnswers.indices.contains(index) {
            quizAnswers[index] = answer
        }
    }

    private var footerButton: some View {
        let label: String = {
            if quizStep {
                return quizIndex == quizzes.count - 1 ? "Check score" : "Check and continue"
            } else {
                return step == slides.count - 1 ? "Begin mastery check" : "Continue"
            }
        }()
        let disabled = quizStep && pendingChoice(for: quizIndex) == nil

        return Button {
            advanceStep()
        } label: {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SyncTheme.paper)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(disabled ? SyncTheme.ink.opacity(0.38) : SyncTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func advanceStep() {
        if !quizStep {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { step = min(step + 1, totalSteps - 1) }
            return
        }
        guard pendingChoice(for: quizIndex) != nil else { return }
        if quizIndex < quizzes.count - 1 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { step += 1 }
        } else {
            let answers = quizzes.indices.map { quizAnswers.indices.contains($0) ? quizAnswers[$0] : -1 }
            quizAnswers = answers
            let result = zip(answers, quizzes).reduce(0) { $0 + ($1.0 == $1.1.correct ? 1 : 0) }
            let perfect = result == quizzes.count
            if perfect { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            else { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            score = result
        }
    }

    // MARK: Score screen
    private func scoreScreen(_ result: Int) -> some View {
        let perfect = result == quizzes.count
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(perfect ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(red: 1, green: 0.62, blue: 0.04), lineWidth: 3)
                        .frame(width: 112, height: 112)
                    Text("\(result)/\(quizzes.count)")
                        .font(.system(size: 31, weight: .heavy))
                        .foregroundStyle(learnWhite)
                }
                .padding(.top, 72)

                Text("MASTERY CHECK")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(learnSecondary)
                    .padding(.top, 24)

                Text(perfect ? "Lesson mastered" : "Review and retry")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(learnWhite)
                    .padding(.top, 8)

                Text(perfect
                    ? "You answered every question correctly. Your understanding is strong enough to unlock the next lesson."
                    : "You scored \(Int((Double(result) / Double(quizzes.count)) * 100))%. A score of 100% is required so the next lesson can safely build on this one.")
                    .font(.system(size: 15))
                    .foregroundStyle(learnSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 10)
                    .padding(.horizontal, 8)

                VStack(spacing: 0) {
                    Rectangle().fill(learnBorder).frame(height: 1)
                    ForEach(Array(quizzes.enumerated()), id: \.offset) { i, quiz in
                        let correct = quizAnswers.indices.contains(i) && quizAnswers[i] == quiz.correct
                        HStack(spacing: 10) {
                            Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 21))
                                .foregroundStyle(correct ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(red: 1, green: 0.27, blue: 0.23))
                            Text("Question \(i + 1): \(correct ? "Correct" : "Review this concept")")
                                .font(.system(size: 13))
                                .foregroundStyle(learnWhite)
                        }
                        .frame(height: 48, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(learnBorder).frame(height: 1)
                    }
                }
                .padding(.top, 25)
                .padding(.horizontal, 28)

                Spacer(minLength: 60)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Button {
                    if perfect {
                        markLessonCompleteIfNeeded()
                        complete = true
                    }
                    else { score = nil; quizAnswers = Array(repeating: -1, count: quizzes.count); pendingAnswer = nil; step = slides.count }
                } label: {
                    Text(perfect ? "Complete lesson" : "Retry mastery check")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SyncTheme.paper)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(SyncTheme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Button {
                    score = nil; quizAnswers = Array(repeating: -1, count: quizzes.count); pendingAnswer = nil
                    step = max(0, slides.count - 3)
                } label: {
                    Text("Review lesson summary")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(learnSecondary)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            .background(learnBlack)
        }
    }

    // MARK: Completion screen
    private var completionScreen: some View {
        let last = (path?.lessons.count ?? 0) - 1 == lessonIndex
        let nextName = path?.lessons.indices.contains(lessonIndex + 1) == true ? path!.lessons[lessonIndex + 1].title : nil
        let wasComplete = lesson.map { LearningProgress.isComplete(pathID: pathID, lesson: $0.title) } ?? false
        return VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(SyncTheme.ink).frame(width: 68, height: 68)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(SyncTheme.paper)
            }
            Text(wasComplete ? "Reviewed" : "+25 XP")
                .font(.system(size: 38, weight: .bold))
                .tracking(-1)
                .foregroundStyle(learnWhite)
                .padding(.top, 24)
            Text("\(lesson?.title ?? "") complete")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(learnWhite)
                .padding(.top, 8)
            Text(last ? "You completed the \(path?.title ?? "") path." : "\(nextName ?? "Next lesson") is now unlocked.")
                .font(.system(size: 15))
                .foregroundStyle(learnSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 9)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Button {
                    if last {
                        dismiss()
                    } else {
                        startNextLesson()
                    }
                } label: {
                    Text(last ? "Return to path" : "Start next lesson")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SyncTheme.paper)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(SyncTheme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Button { dismiss() } label: {
                    Text("View learning path")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(learnSecondary)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            .background(learnBlack)
        }
    }

    private func markLessonCompleteIfNeeded() {
        guard let path, let lesson else { return }
        if !LearningProgress.isComplete(pathID: path.id, lesson: lesson.title) {
            LearningProgress.toggle(pathID: path.id, lesson: lesson.title)
        }
        LearningProgress.clearResume(pathID: path.id, lesson: lesson.title)
    }

    private func persistResume() {
        guard let lesson, !complete, score == nil, totalSteps > 0 else { return }
        LearningProgress.saveResume(
            pathID: pathID,
            lesson: lesson.title,
            step: step,
            quizAnswers: quizAnswers
        )
    }

    private func loadLesson(reset: Bool = false) {
        guard let path, let lesson else { return }
        pendingAnswer = nil
        score = nil
        complete = false
        slides = RahulSlide.cards(path: path, lesson: lesson)
        quizzes = RahulQuiz.mastery(path: path, lesson: lesson)
        if reset {
            step = 0
            quizAnswers = Array(repeating: -1, count: quizzes.count)
            LearningProgress.clearResume(pathID: path.id, lesson: lesson.title)
        } else {
            let saved = LearningProgress.resumePage(pathID: path.id, lesson: lesson.title)
            let last = max(0, totalSteps - 1)
            step = min(max(0, saved), last)
            var answers = LearningProgress.resumeQuiz(pathID: path.id, lesson: lesson.title)
            if answers.count < quizzes.count {
                answers.append(contentsOf: Array(repeating: -1, count: quizzes.count - answers.count))
            } else if answers.count > quizzes.count {
                answers = Array(answers.prefix(quizzes.count))
            }
            quizAnswers = answers
            pendingAnswer = quizStep ? pendingChoice(for: quizIndex) : nil
        }
        speakStep()
        let course = path.title
        let lessonTitle = lesson.plainTitle
        let courseID = path.id
        let shots = slides
        Task {
            for (index, slide) in shots.prefix(3).enumerated() {
                _ = await LessonArt.load(
                    course: course,
                    pathID: courseID,
                    lesson: lessonTitle,
                    slide: slide.title,
                    page: index
                )
            }
        }
    }

    private func toggleLessonAudio() {
        if speaker.playingID != nil {
            speaker.toggleMute()
            return
        }
        speaker.isMuted = false
        speakStep()
    }

    private func speakStep() {
        guard !speaker.isMuted, let lesson else { return }
        let spoken: String
        if quizStep, let quiz = activeQuiz {
            spoken = ([quiz.question] + quiz.options).joined(separator: ". ")
        } else if slides.indices.contains(step) {
            let slide = slides[step]
            spoken = [slide.title, slide.body, slide.callout].joined(separator: ". ")
        } else {
            return
        }
        speaker.speakRaw(
            spoken,
            id: LessonStudio.speechID("\(pathID).\(lesson.title).\(step)")
        )
    }

    private func startNextLesson() {
        guard let path, lessonIndex + 1 < path.lessons.count else {
            dismiss()
            return
        }
        lessonIndex += 1
        loadLesson(reset: false)
    }
}

// MARK: - Slide / Quiz models

private struct RahulSlide {
    var eyebrow: String
    var title: String
    var body: String
    var callout: String

    static func cards(path: LearningPath, lesson: LearningLesson) -> [RahulSlide] {
        let title = lesson.plainTitle
        let pathTitle = path.title
        let lessons = path.lessons
        let idx = lessons.firstIndex(where: { $0.title == lesson.title }) ?? 0
        let prev = idx > 0 ? lessons[idx - 1].plainTitle : "the basic questions studied in \(pathTitle)"
        let next = idx < lessons.count - 1 ? lessons[idx + 1].plainTitle : title
        let misconception = "\(title) is just a term to memorize, not something with an underlying process that produces a result."
        return [
            RahulSlide(eyebrow: "Lesson overview", title: "Understanding \(title)",
                body: "This lesson develops a usable understanding of \(title). You will begin with its purpose, define it precisely, examine its mechanism, work through a concrete application, and learn where the idea can be misapplied.",
                callout: "Take time to explain each card aloud. Active recall is more effective than simply rereading."),
            RahulSlide(eyebrow: "Start with a question", title: "Why study \(title)?",
                body: "\(lesson.application) The example gives us a practical question: what process makes that result possible, and under which conditions should we expect it? \(title) provides a framework for answering that question.",
                callout: "By the end, you should be able to explain the example without using “it just happens” as a shortcut."),
            RahulSlide(eyebrow: "Definition", title: "A precise meaning",
                body: "\(lesson.core) The important part is the relationship expressed by the definition. Memorizing the words is not enough; understanding means being able to recognize the same relationship in a new situation.",
                callout: "In one sentence, restate \(title) without looking back at the first sentence."),
            RahulSlide(eyebrow: "Prior knowledge", title: "What this builds on",
                body: "A clear understanding of \(prev) gives you the background needed here. Recall its central idea, then notice what the current lesson adds: a new process, distinction, or scale of explanation within \(pathTitle).",
                callout: "If \(prev) feels uncertain, review it before continuing; later lessons assume this foundation."),
            RahulSlide(eyebrow: "Parts of the explanation", title: "Four questions to ask",
                body: "When you encounter \(title), identify four things: the starting conditions, the actors or components involved, the process connecting them, and the result. Then ask what limits the result or would make it change.",
                callout: "These questions turn a broad topic into a testable explanation."),
            RahulSlide(eyebrow: "Mechanism", title: "How \(title) works",
                body: "\(lesson.mechanism) This is the causal center of the lesson: it explains how an initial condition becomes an outcome rather than merely stating that the outcome exists.",
                callout: "A mechanism should let you predict what changes when one important input changes."),
            RahulSlide(eyebrow: "Causal walkthrough", title: "Follow the process",
                body: "Begin with the relevant starting condition. The components then interact through this process: \(lesson.mechanism) The resulting change becomes observable, and comparing it with a different condition helps isolate the cause.",
                callout: "Pause and identify where the explanation moves from cause to effect."),
            RahulSlide(eyebrow: "Worked application", title: "Apply the idea",
                body: "\(lesson.application) This is an application of \(title) because the example contains the same defining relationship and mechanism—not merely because it belongs to the same broad subject.",
                callout: "Name the starting condition, mechanism, and outcome in the example."),
            RahulSlide(eyebrow: "Misconception", title: "\(title): a common mistake",
                body: "\(misconception) That approach fails because a label cannot explain evidence or support a prediction. A strong account must connect the definition to the mechanism and then to an observable example.",
                callout: "If an explanation only repeats “\(title),” ask what actually changes and why."),
            RahulSlide(eyebrow: "Limits and evidence", title: "Use the idea carefully",
                body: "The concept is most useful when its assumptions match the situation. Check the quality of the evidence, consider other causes that could produce a similar result, and avoid extending the explanation beyond the conditions it was designed to address.",
                callout: "Knowing a concept includes knowing what evidence could show that your application is wrong."),
            RahulSlide(eyebrow: "Cumulative connection", title: "From \(title) to \(next)",
                body: "\(next) follows this lesson because it uses part of the model you have just built. Keep the definition and mechanism of \(title) available; the next lesson will extend or combine them rather than starting from zero.",
                callout: "Describe one question about \(next) that your new understanding of \(title) helps you ask."),
            RahulSlide(eyebrow: "Review", title: "Your \(title) checklist",
                body: "You are ready for the mastery check if you can: define \(title); explain this mechanism—\(lesson.mechanism); analyze this application—\(lesson.application); identify the common misconception; and name a condition that could limit the explanation.",
                callout: "The assessment has three questions. You need 3/3 to complete the lesson, and you can retry if needed."),
        ]
    }
}

private struct RahulQuiz {
    var question: String
    var options: [String]
    var correct: Int

    static func mastery(path: LearningPath, lesson: LearningLesson) -> [RahulQuiz] {
        let title = lesson.plainTitle
        let idx = path.lessons.firstIndex(where: { $0.title == lesson.title }) ?? 0
        let next = idx < path.lessons.count - 1 ? path.lessons[idx + 1].plainTitle : title
        let misconception = "\(title) is just a term to memorize, not something with an underlying process that produces a result."
        return [
            RahulQuiz(
                question: "Which statement best defines \(title)?",
                options: [
                    lesson.core,
                    misconception,
                    "\(title) is identical to \(next) in every context."
                ],
                correct: 0
            ),
            RahulQuiz(
                question: "Which statement explains how \(title) works?",
                options: [
                    "It occurs automatically and has no identifiable cause.",
                    lesson.mechanism,
                    "It works only because people use the term \(title)."
                ],
                correct: 1
            ),
            RahulQuiz(
                question: "Which is the best application of \(title)?",
                options: [
                    "An example with no connection to \(path.title).",
                    "A claim that cannot be observed or compared.",
                    lesson.application
                ],
                correct: 2
            )
        ]
    }
}

private extension LearningLesson {
    var plainTitle: String {
        title.trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
    }
}

// MARK: - Lesson container

private struct SafeAreaAwareLesson<Content: View, Footer: View>: View {
    let step: Int
    let totalSteps: Int
    let estimatedMinutes: Int
    var muted = false
    var scrollContent = true
    let onClose: () -> Void
    var onVoice: (() -> Void)? = nil
    var onSpeaker: (() -> Void)? = nil
    let onAsk: () -> Void
    @ViewBuilder let footer: Footer
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(learnWhite)
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("Back")
                Spacer()
                Text("\(step + 1) of \(totalSteps) · \(estimatedMinutes) min")
                    .font(.system(size: 13))
                    .foregroundStyle(learnSecondary)
                Spacer()
                if let onVoice {
                    Button(action: onVoice) {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(learnWhite)
                    }
                    .frame(width: 40, height: 44)
                    .accessibilityLabel("Voice")
                }
                if let onSpeaker {
                    Button(action: onSpeaker) {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(learnWhite)
                    }
                    .frame(width: 40, height: 44)
                    .accessibilityLabel(muted ? "Unmute" : "Listen")
                }
                Button(action: onAsk) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(learnWhite)
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("Ask about this lesson")
            }
            .padding(.horizontal, 8)
            .frame(height: 48)

            ProgressBar(
                value: Double(step + 1) / Double(max(1, totalSteps))
            )
            .padding(.horizontal, 20)

            if scrollContent {
                ScrollView(showsIndicators: false) {
                    content
                }
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            footer
        }
        .background(learnBlack.ignoresSafeArea())
    }
}

private struct LessonAskSheet: View {
    let path: LearningPath
    let lesson: LearningLesson
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [SaveChatLine] = []
    @State private var draft = ""
    @State private var loading = false
    @State private var pack: LessonPack?

    private var canSend: Bool {
        !loading && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(lesson.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SyncTheme.ink)
                            .padding(.top, 8)
                        if lines.isEmpty, !loading {
                            Text("Ask anything about this lesson. Analogies, examples, exam-style questions.")
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                        ForEach(lines) { line in
                            if !line.text.isEmpty {
                                HStack {
                                    if line.role == "user" { Spacer(minLength: 36) }
                                    ChatMarkdown.Rich(
                                        raw: line.role == "user" ? line.text : LibraryAsk.strippedHeading(line.text),
                                        color: line.role == "user" ? SyncTheme.paper : SyncTheme.ink
                                    )
                                    .padding(12)
                                    .background(line.role == "user" ? SyncTheme.ink : SyncTheme.paperRaised)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    if line.role != "user" { Spacer(minLength: 36) }
                                }
                            }
                        }
                        if loading {
                            SparkleThinking()
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)

                HStack(alignment: .center, spacing: 8) {
                    TextField("Ask about this lesson", text: $draft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...5)
                        .onSubmit { Task { await send() } }
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? SyncTheme.ink : SyncTheme.inkMuted)
                    }
                    .disabled(!canSend)
                }
                .padding(14)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SyncTheme.line, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Ask")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(SyncTheme.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(SyncTheme.ink)
                }
            }
        }
        .task {
            if let cached = LessonStudio.cached(pathID: path.id, lesson: lesson.title) {
                pack = cached
            } else {
                pack = await LessonStudio.pack(for: path, lesson: lesson)
            }
        }
    }

    private func send() async {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        lines.append(.user(q))
        lines.append(.assistant(""))
        loading = true
        var history: [(String, String)] = []
        for line in lines.dropLast() {
            history.append((line.role, line.text))
        }
        let answer = await LessonStudio.ask(
            question: q,
            path: path,
            lesson: lesson,
            pack: pack,
            history: history
        ) { delta in
            if let i = lines.indices.last {
                lines[i].text = delta
            }
        }
        if let i = lines.indices.last {
            lines[i].text = answer
        }
        loading = false
    }
}

struct ProgressBar: View {
    var value: Double
    var fill: Color = SyncTheme.ink
    var track: Color = SyncTheme.line

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
    }
}
