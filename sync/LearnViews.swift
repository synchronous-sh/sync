import SwiftUI

struct LearnView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(LearningCatalog.shelves) { shelf in
                    CourseShelfView(shelf: shelf)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Route.self) { DestinationRouter(route: $0) }
    }
}

struct CourseShelfView: View {
    let shelf: CourseShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(SyncTheme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: Route.course(item.pathID)) {
                            CourseCardView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct CourseCardView: View {
    let item: CourseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CourseArtwork(pathID: item.pathID)
                .frame(width: 168, height: 112)
            if let progress = item.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SyncTheme.line)
                        Capsule()
                            .fill(SyncTheme.ink)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SyncTheme.ink)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(SyncTheme.inkMuted)
                .lineLimit(2)
        }
        .frame(width: 168, alignment: .leading)
    }
}

struct CourseArtwork: View {
    let pathID: String

    private var path: LearningPath? { LearningCatalog.path(id: pathID) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [SyncTheme.elevated, SyncTheme.paperRaised],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: path?.symbol ?? "book")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(SyncTheme.ink)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SyncTheme.line, lineWidth: 1)
        )
    }
}

struct CourseDetailView: View {
    let pathID: String
    @State private var refresh = 0

    private var path: LearningPath? { LearningCatalog.path(id: pathID) }

    var body: some View {
        Group {
            if let path {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        CourseArtwork(pathID: path.id)
                            .frame(height: 180)
                        Text(path.title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SyncTheme.ink)
                        Text(path.description)
                            .font(.system(size: 16))
                            .foregroundStyle(SyncTheme.inkMuted)
                        ProgressBar(value: LearningProgress.fraction(for: path))
                            .id(refresh)
                        ForEach(Array(path.lessons.enumerated()), id: \.element.id) { index, lesson in
                            NavigationLink(value: Route.lesson(path.id, index)) {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(SyncTheme.inkTertiary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(lesson.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(SyncTheme.ink)
                                        Text(lesson.core)
                                            .font(.system(size: 13))
                                            .foregroundStyle(SyncTheme.inkMuted)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    if LearningProgress.isComplete(pathID: path.id, lesson: lesson.title) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(SyncTheme.ink)
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            if index < path.lessons.count - 1 {
                                Divider().overlay(SyncTheme.line)
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 80)
                }
            } else {
                Text("This path is gone.")
                    .foregroundStyle(SyncTheme.inkMuted)
            }
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh += 1 }
    }
}

struct LessonDetailView: View {
    let pathID: String
    let index: Int
    @State private var complete = false

    private var path: LearningPath? { LearningCatalog.path(id: pathID) }
    private var lesson: LearningLesson? {
        guard let path, path.lessons.indices.contains(index) else { return nil }
        return path.lessons[index]
    }

    var body: some View {
        Group {
            if let path, let lesson {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(path.title.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(SyncTheme.inkMuted)
                        Text(lesson.title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SyncTheme.ink)
                        block("The idea", lesson.core)
                        block("How it works", lesson.mechanism)
                        block("In practice", lesson.application)
                        Button {
                            LearningProgress.toggle(pathID: path.id, lesson: lesson.title)
                            complete = LearningProgress.isComplete(pathID: path.id, lesson: lesson.title)
                        } label: {
                            Text(complete ? "Mark as unread" : "Mark complete")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(SyncTheme.ink)
                                .foregroundStyle(SyncTheme.paper)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                }
            } else {
                Text("This lesson is gone.")
                    .foregroundStyle(SyncTheme.inkMuted)
            }
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let path, let lesson {
                complete = LearningProgress.isComplete(pathID: path.id, lesson: lesson.title)
            }
        }
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SyncTheme.inkMuted)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(body)
                .font(.system(size: 17))
                .foregroundStyle(SyncTheme.ink)
                .lineSpacing(4)
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SyncTheme.line)
                Capsule()
                    .fill(SyncTheme.ink)
                    .frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 4)
    }
}
