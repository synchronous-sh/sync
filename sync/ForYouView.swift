import SwiftUI
import SwiftData
import AVFoundation
import UIKit
import Combine

struct ForYouView: View {
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @State private var posts: [FeedPost] = FeedStore.load()
    @State private var loading = false
    @State private var loadingMore = false
    @State private var message = ""
    @State private var currentID: UUID?
    @State private var feedJump = 0
    @StateObject private var revealBox = FeedRevealBox()
    @StateObject private var speaker = FeedSpeaker()

    @State private var whySave: SaveJump?
    @State private var askPost: FeedPost?
    @State private var openStory: FeedPost?
    @State private var showVoice = false
    @State private var showSearch = false
    @State private var searchDraft = ""
    @State private var searching = false
    @State private var searchError = ""
    @State private var showingCoach = false
    @AppStorage(CoachTour.fypCompletedKey) private var completedFYPCoach = false

    var body: some View {
        Group {
            if posts.isEmpty && !loading {
                empty
                    .background(SyncTheme.paper.ignoresSafeArea())
            } else {
                feed
            }
        }
        .navigationTitle("For you")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 2) {
                    NavIconButton(accessibility: "Search topics") {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .coachSpot(.fypSearch)
                    NavIconButton(accessibility: "Voice") {
                        showVoice = true
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .coachSpot(.fypVoice)
                    NavIconButton(accessibility: speaker.isMuted ? "Unmute" : "Mute") {
                        speaker.toggleMute()
                    } label: {
                        Image(systemName: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .coachSpot(.fypMute)
                    NavIconButton(accessibility: "Refresh") {
                        guard !loading else { return }
                        Task { await refresh() }
                    } label: {
                        if loading {
                            ProgressView()
                                .tint(SyncTheme.ink)
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    .coachSpot(.fypRefresh)
                }
            }
        }
        .coachTour(CoachTour.fyp, isPresented: $showingCoach, blocksTouches: false) {
            completedFYPCoach = true
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
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Type a topic, person, or place. We’ll pull the latest headlines and write briefings.")
                        .font(.system(size: 15))
                        .foregroundStyle(SyncTheme.inkMuted)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(SyncTheme.inkMuted)
                        TextField("Lake Ontario, OpenAI, F1", text: $searchDraft)
                            .textInputAutocapitalization(.words)
                            .onSubmit { Task { await searchTopic() } }
                        Button {
                            Task { await searchTopic() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(canSearch ? SyncTheme.ink : SyncTheme.inkMuted)
                        }
                        .disabled(!canSearch)
                        .accessibilityLabel("Find latest")
                    }
                    .padding(14)
                    .background(SyncTheme.paperRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(SyncTheme.line, lineWidth: 1)
                    )
                    if searching {
                        SparkleThinking(label: "Finding the latest")
                    }
                    if !searchError.isEmpty {
                        Text(searchError)
                            .font(.system(size: 15))
                            .foregroundStyle(SyncTheme.inkMuted)
                    }
                    Spacer()
                }
                .padding(20)
                .background(SyncTheme.paper.ignoresSafeArea())
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSearch = false }
                            .fontWeight(.semibold)
                            .foregroundStyle(SyncTheme.ink)
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
        .sheet(item: $askPost) { post in
            FeedAskSheet(post: post, save: saves.first(where: { $0.saveID == post.saveID }))
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
                .presentationBackground(SyncTheme.paper)
                .onAppear { if !speaker.isPaused { speaker.togglePause() } }
        }
        .navigationDestination(item: $whySave) { jump in
            if let save = saves.first(where: { $0.saveID == jump.id }) {
                SaveDetailView(save: save)
            }
        }
        .navigationDestination(item: $openStory) { post in
            StoryDetailView(post: post)
        }
        .onAppear {
            if openStory != nil || whySave != nil { return }
            if currentID == nil { currentID = posts.first?.id }
            if let id = currentID, let post = posts.first(where: { $0.id == id }) {
                speakCard(post)
                prefetchImages(around: id)
                speaker.prefetch(nearbyPosts(around: id))
            }
        }
        .onDisappear {
            if showVoice || showSearch || askPost != nil || openStory != nil { return }
            speaker.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedVoiceDidChange)) { _ in
            speaker.applyVoice()
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedSpeechSpeedDidChange)) { _ in
            speaker.applySpeed()
        }
        .onChange(of: openStory) { _, story in
            if story == nil, let id = currentID, let post = posts.first(where: { $0.id == id }) {
                speakCard(post)
            }
        }
        .task {
            let all = FeedStore.load()
            posts = all
            if currentID == nil || !(posts.contains { $0.id == currentID }) {
                currentID = posts.first?.id
            }
            if let id = currentID {
                prefetchImages(around: id)
                Task { await expandNearby(around: id) }
            }
            if posts.isEmpty {
                await refresh()
            } else {
                Task { await loadMore() }
            }
        }
    }

    private var empty: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A feed from what you save.")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
                Text(hint)
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)

                Button("Make posts") {
                    Task { await refresh() }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SyncTheme.paper)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(SyncTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(loading)
            }
            .padding(24)
        }
        .syncPullToRefresh { await refresh() }
    }

    private var hint: String {
        if saves.isEmpty { return message.isEmpty ? "A mix of stories to start. Save a few things and this feed will follow you." : message }
        return message.isEmpty ? "We’ll pull live headlines for the people and topics in your library, then write new briefings — not recaps of your saves." : message
    }

    private var feed: some View {
        VerticalFeedPager(
            posts: posts,
            saveFor: { post in saves.first(where: { $0.saveID == post.saveID }) },
            articleSaved: { post in
                let raw = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return false }
                let canon = SourceAdapter.canonicalize(raw)
                return saves.contains {
                    (!canon.isEmpty && $0.canonicalURL == canon) || $0.sourceURL == raw
                }
            },
            currentID: $currentID,
            onWhy: { whySave = SaveJump(id: $0) },
            onAsk: { id in askPost = posts.first(where: { $0.id == id }) },
            onOpen: { id in
                speaker.stop()
                openStory = posts.first(where: { $0.id == id })
            },
            onMute: { speaker.toggleMute() },
            onNeedMore: { Task { await loadMore() } },
            onRefresh: { await refresh() },
            scrollNonce: feedJump,
            reveal: revealBox.post
        )
        .ignoresSafeArea()
        .background(SyncTheme.paper.ignoresSafeArea())
        .overlay {
            if loading && posts.isEmpty {
                SparkleThinking(label: searching ? "Finding the latest" : "Loading stories")
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: currentID) { _, id in
            if openStory != nil { return }
            guard let id, let post = posts.first(where: { $0.id == id }) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard currentID == id, openStory == nil else { return }
                speakCard(post)
                prefetchImages(around: id)
                speaker.prefetch(nearbyPosts(around: id))
            }
        }
        .onChange(of: posts.count) { _, _ in
            if let id = currentID { prefetchImages(around: id) }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        message = ""
        speaker.stop()
        var batch: [FeedPost] = []
        let next = await FeedStudio.fill(from: saves, count: 12, replace: true) { post in
            batch.append(post)
            posts = batch
            loading = false
            if currentID == nil || !batch.contains(where: { $0.id == currentID }) {
                currentID = post.id
                feedJump += 1
                speakCard(post)
                speaker.prefetch([post])
            }
            if let id = currentID {
                prefetchImages(around: id)
            }
        }
        if posts.isEmpty { posts = next }
        if next.isEmpty {
            message = saves.isEmpty
                ? "Couldn’t load stories just now. Try Make posts again."
                : "No fresh headlines for your interests yet. Save more specific artists, names, or topics, then refresh."
        }
        loading = false
        if !posts.isEmpty { Task { await loadMore() } }
    }

    private var canSearch: Bool {
        searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && !searching
    }

    private func searchTopic() async {
        let q = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !searching else { return }
        searching = true
        loading = true
        searchError = ""
        message = ""
        speaker.stop()
        var batch: [FeedPost] = []
        let found = await FeedStudio.search(q, count: 8) { post in
            batch.append(post)
            posts = batch + posts.filter { existing in
                !batch.contains { FeedStore.isSameStory($0.headline, existing.headline) }
            }
            if batch.count == 1 {
                currentID = post.id
                feedJump += 1
                speaker.speak(post)
                showSearch = false
            }
            prefetchImages(around: post.id)
        }
        if !found.isEmpty {
            posts = found + posts.filter { existing in
                !found.contains { FeedStore.isSameStory($0.headline, existing.headline) }
            }
            currentID = found.first?.id
            feedJump += 1
            if let first = found.first {
                speaker.speak(first)
                speaker.prefetch(Array(found.prefix(3)))
            }
            showSearch = false
        } else {
            searchError = "No fresh headlines for that yet. Try a more specific name or topic."
        }
        searching = false
        loading = false
    }

    private func speakCard(_ post: FeedPost) {
        var spoken = post
        if let stored = FeedStore.load().first(where: { $0.id == post.id }),
           !FeedStudio.needsBriefing(stored) {
            spoken = stored
        }
        revealBox.post = spoken
        speaker.speak(spoken)
    }

    private func nearbyPosts(around id: UUID) -> [FeedPost] {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return [] }
        let end = min(posts.count, index + 3)
        return Array(posts[index..<end])
    }

    private func expandNearby(around id: UUID) async {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        let end = min(posts.count, index + 4)
        let slice = Array(posts[index..<end])
        await FeedStudio.ensureBriefings(slice, prefer: id)
        let stored = FeedStore.load()
        for i in index..<end where i < posts.count {
            if speaker.playingThis(posts[i].id) { continue }
            if let next = stored.first(where: { $0.id == posts[i].id }),
               next.script != posts[i].script || next.briefingReady != posts[i].briefingReady {
                posts[i] = next
            }
        }
        if let open = openStory, let next = stored.first(where: { $0.id == open.id }) {
            openStory = next
        }
    }

    private func prefetchImages(around id: UUID) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        let end = min(posts.count, index + 8)
        FeedImageCache.prefetch(Array(posts[index..<end]))
    }

    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        var emptyStreak = 0
        while true {
            let index = currentID.flatMap { id in posts.firstIndex(where: { $0.id == id }) } ?? 0
            if posts.count - index >= 20 { break }
            let beforeIDs = Set(posts.map(\.id))
            _ = await FeedStudio.fill(from: saves, count: 8)
            let added = FeedStore.load().filter { !beforeIDs.contains($0.id) }
            if !added.isEmpty {
                posts.append(contentsOf: added)
            }
            if currentID == nil { currentID = posts.first?.id }
            if added.isEmpty {
                emptyStreak += 1
                if emptyStreak >= 2 { break }
            } else {
                emptyStreak = 0
            }
        }
    }
}

@MainActor
final class FeedSpeaker: ObservableObject {
    @Published var isMuted = false
    @Published var isPaused = false
    @Published var isPlaying = false
    private var player: AVPlayer?
    private let synth = AVSpeechSynthesizer()
    var playingID: UUID?

    private var lastPost: FeedPost?
    private var lastFull = false
    private var job = UUID()
    private var spokenVoice = ""

    func playingThis(_ id: UUID) -> Bool {
        playingID == id
    }

    func speak(_ post: FeedPost, force: Bool = false, full: Bool = false) {
        let voice = ElevenLabsSpeech.voiceID
        if !force, playingID == post.id, spokenVoice == voice, lastFull == full, player != nil || synth.isSpeaking { return }
        stop()
        playingID = post.id
        lastPost = post
        lastFull = full
        spokenVoice = voice
        if isPaused { isPaused = false }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        startAudio(post, voice: voice, skipCache: force, full: full)
    }

    func toggleReadAloud(_ post: FeedPost) {
        if lastPost?.id == post.id, lastFull, player != nil || isPaused || synth.isSpeaking || synth.isPaused {
            togglePause()
            return
        }
        speak(post, full: true)
    }

    func prefetch(_ posts: [FeedPost]) {
        let voice = ElevenLabsSpeech.voiceID
        guard ElevenLabsKey.isConfigured else { return }
        for post in posts.prefix(3) where !post.cardBlurb.isEmpty {
            if ElevenLabsSpeech.cachedURL(id: post.id, voice: voice, text: post.cardBlurb) != nil { continue }
            Task {
                _ = await ElevenLabsSpeech.speak(post.cardBlurb, id: post.id, voice: voice)
            }
        }
    }

    func togglePause() {
        guard let post = lastPost else { return }
        if playingID == nil {
            speak(post)
            return
        }
        if isPaused {
            isPaused = false
            isPlaying = true
            applyMute()
            player?.rate = FeedSpeechSpeed.current
            player?.play()
            synth.continueSpeaking()
        } else {
            player?.pause()
            player?.rate = 0
            if synth.isSpeaking || synth.isPaused {
                synth.pauseSpeaking(at: .immediate)
            }
            isPaused = true
            isPlaying = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        applyMute()
        if isMuted {
            player?.pause()
            if synth.isSpeaking { synth.pauseSpeaking(at: .immediate) }
        } else if !isPaused {
            if player != nil {
                player?.rate = FeedSpeechSpeed.current
                player?.play()
            } else if let post = lastPost {
                startAudio(post, voice: ElevenLabsSpeech.voiceID, full: lastFull)
            }
            synth.continueSpeaking()
        }
    }

    private func applyMute() {
        player?.volume = isMuted ? 0 : 1
    }

    private func startAudio(_ post: FeedPost, voice: String, skipCache: Bool = false, full: Bool = false) {
        let spoken = full ? FeedSpeaker.summarySpeech(post.script) : post.cardBlurb
        guard !isMuted, !spoken.isEmpty else { return }
        let token = UUID()
        job = token
        if ElevenLabsKey.isConfigured {
            if !skipCache, let url = ElevenLabsSpeech.cachedURL(id: post.id, voice: voice, text: spoken) {
                play(url)
                return
            }
            Task { @MainActor in
                let file = await ElevenLabsSpeech.speak(spoken, id: post.id, voice: voice, skipCache: skipCache)
                guard job == token, playingID == post.id, !isMuted else { return }
                if let file, let url = MediaStore.fileURL(file) {
                    play(url)
                }
            }
            return
        }
        speakSystem(spoken)
    }

    private func play(_ url: URL) {
        player?.pause()
        let next = AVPlayer(url: url)
        next.automaticallyWaitsToMinimizeStalling = true
        next.volume = isMuted ? 0 : 1
        player = next
        if !isPlaying { isPlaying = true }
        if !isPaused {
            next.play()
            next.rate = FeedSpeechSpeed.current
        }
    }

    private func speakSystem(_ text: String) {
        let line = AVSpeechUtterance(string: ElevenLabsSpeech.spokenText(text))
        line.voice = FeedVoice.systemCurrent()
        line.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92 * FeedSpeechSpeed.current
        isPlaying = true
        synth.speak(line)
    }

    func applyVoice() {
        guard let post = lastPost else { return }
        speak(post, force: true, full: lastFull)
    }

    func applySpeed() {
        guard !isPaused, player != nil else { return }
        player?.rate = FeedSpeechSpeed.current
    }

    func stop() {
        job = UUID()
        player?.pause()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        playingID = nil
        spokenVoice = ""
        isPaused = false
        isPlaying = false
    }

    static func summarySpeech(_ script: String) -> String {
        ElevenLabsSpeech.spokenText(
            script
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\n- ", with: ". ")
                .replacingOccurrences(of: "\n• ", with: ". ")
                .replacingOccurrences(of: "\n* ", with: ". ")
        )
    }
}

struct SaveJump: Identifiable, Hashable {
    let id: UUID
}

struct FeedCard: View {
    let post: FeedPost
    let save: SaveItem?
    var articleSaved = false
    var onWhy: ((UUID) -> Void)? = nil
    var onAsk: ((UUID) -> Void)? = nil
    var onMute: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var remote: UIImage?
    @State private var page: InAppPage?
    @State private var confirmingUnsave = false
    @State private var savedHere = false
    @State private var savedID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.height / 2
            VStack(spacing: 0) {
                photo(in: geo.size.width, height: half)
                    .frame(width: geo.size.width, height: half, alignment: .bottom)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { onMute?() })

                VStack(alignment: .leading, spacing: 10) {
                    Text((post.sourceName.isEmpty ? post.interest : post.sourceName).uppercased() + "  ·  " + FeedNews.dateLine(post.publishedAt).uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mutedCopy)
                        .tracking(0.6)
                    Text(post.title)
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .foregroundStyle(copy)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(post.cardBlurb)
                        .font(.system(size: 16))
                        .foregroundStyle(copy.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if let url = URL(string: post.headlineURL), !post.headlineURL.isEmpty {
                            Button("Read source") {
                                if !OutboundLink.open(url) {
                                    page = InAppPage(id: url)
                                }
                            }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(colorScheme == .dark ? .black : SyncTheme.paper)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(colorScheme == .dark ? Color.white : SyncTheme.ink)
                                .clipShape(Capsule())
                        }
                        Button {
                            ArticleShare.share(post)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(colorScheme == .dark ? .black : SyncTheme.paper)
                                .frame(width: 36, height: 36)
                                .background(colorScheme == .dark ? Color.white : SyncTheme.ink)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Share")
                        Button {
                            if isSaved {
                                confirmingUnsave = true
                            } else {
                                saveNews(note: "", collectionName: "")
                            }
                        } label: {
                            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(colorScheme == .dark ? .black : SyncTheme.paper)
                                .frame(width: 36, height: 36)
                                .background(colorScheme == .dark ? Color.white : SyncTheme.ink)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(isSaved ? "Remove from library" : "Save to library")
                        Button {
                            onAsk?(post.id)
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(colorScheme == .dark ? .black : SyncTheme.paper)
                                .frame(width: 36, height: 36)
                                .background(colorScheme == .dark ? Color.white : SyncTheme.ink)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Ask about this")
                        if let save {
                            Button("Why this") { onWhy?(save.saveID) }
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(copy)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(width: geo.size.width, height: half, alignment: .topLeading)
                .clipped()
                .background(letterbox)
            }
            .contentShape(Rectangle())
        }
        .background(letterbox)
        .sheet(item: $page) { page in
            SafariTab(url: page.url)
                .ignoresSafeArea()
        }
        .confirmationDialog("Remove from library?", isPresented: $confirmingUnsave, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { unsaveNews() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This save will be deleted.")
        }
        .task {
            if let cached = FeedImageCache.image(for: post.id) {
                remote = cached
                return
            }
            if let image = await FeedNews.loadFastImage(for: post) {
                remote = image
            }
        }
    }

    @ViewBuilder
    private func photo(in width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            letterbox
            if let image = localImage ?? remote {
                let landscape = image.size.width > image.size.height + 1
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: landscape ? .fit : .fill)
                    .frame(width: width, height: max(height - 40, 80), alignment: .bottom)
                    .clipped()
                    .padding(.bottom, 20)
            } else {
                letterbox
                    .padding(.bottom, 20)
            }
        }
    }

    private var copy: Color {
        SyncTheme.ink
    }

    private var mutedCopy: Color {
        SyncTheme.inkMuted
    }

    private var letterbox: Color {
        SyncTheme.paper
    }

    private var localImage: UIImage? {
        FeedImageCache.image(for: post.id)
    }

    private var isSaved: Bool { articleSaved || savedHere }

    private func saveNews(note: String, collectionName: String) {
        guard !isSaved else { return }
        let briefing = post.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CaptureService.ingest(
            urlString: url.isEmpty ? nil : url,
            text: briefing.isEmpty ? post.title : briefing,
            imageData: nil,
            context: modelContext
        )
        result.save.title = post.title
        result.save.summary = briefing
        if result.save.creatorName.isEmpty {
            result.save.creatorName = post.sourceName
        }
        if result.save.topicsCSV.isEmpty, !post.interest.isEmpty {
            result.save.topicsCSV = post.interest
        }
        if result.save.imageFileName.isEmpty, let data = (localImage ?? remote)?.jpegData(compressionQuality: 0.85) {
            result.save.imageFileName = MediaStore.save(data, id: result.save.saveID)
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            result.save.rawText = SaveNote.merging(trimmedNote, into: result.save.rawText)
        }
        let bag = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bag.isEmpty {
            let bags = (try? modelContext.fetch(FetchDescriptor<CollectionItem>())) ?? []
            if let existing = CollectionHousekeeping.match(bag, in: bags) {
                if !result.save.collections.contains(where: { $0.collectionID == existing.collectionID }) {
                    result.save.collections.append(existing)
                }
            } else {
                let created = CollectionItem(name: bag)
                modelContext.insert(created)
                result.save.collections.append(created)
            }
        }
        try? modelContext.save()
        savedID = result.save.saveID
        savedHere = true
        LibraryBrain.pull(context: modelContext, reread: result.save)
    }

    private func unsaveNews() {
        let raw = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let canon = SourceAdapter.canonicalize(raw)
        let items = (try? modelContext.fetch(FetchDescriptor<SaveItem>())) ?? []
        if let item = items.first(where: { save in
            save.saveID == savedID
                || (!canon.isEmpty && save.canonicalURL == canon)
                || save.sourceURL == raw
        }) {
            modelContext.delete(item)
            try? modelContext.save()
        }
        savedHere = false
        savedID = nil
    }
}

struct StoryDetailView: View {
    @State private var post: FeedPost
    @Query(sort: \SaveItem.savedAt, order: .reverse) private var saves: [SaveItem]
    @Query(sort: \CollectionItem.name) private var collections: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @StateObject private var reader = FeedSpeaker()
    @State private var showingAsk = false
    @State private var showingSaveSheet = false
    @State private var confirmingUnsave = false
    @State private var picture: UIImage?
    @State private var savedHere = false
    @State private var savedID: UUID?
    @State private var hasAskThread = false
    @State private var page: InAppPage?

    init(post: FeedPost) {
        _post = State(initialValue: post)
        _picture = State(initialValue: FeedImageCache.image(for: post.id))
    }

    private var relatedSave: SaveItem? {
        saves.first(where: { $0.saveID == post.saveID })
    }

    private var savedArticle: SaveItem? {
        let raw = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let canon = SourceAdapter.canonicalize(raw)
        return saves.first { item in
            (!canon.isEmpty && item.canonicalURL == canon) || item.sourceURL == raw
        }
    }

    private var storedSave: SaveItem? {
        if let savedArticle { return savedArticle }
        if let savedID { return saves.first { $0.saveID == savedID } }
        return nil
    }

    private var isSaved: Bool { storedSave != nil || savedHere }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Text(post.sourceName.isEmpty ? "Story" : post.sourceName)
                    Text("·")
                    Text(FeedNews.dateLine(post.publishedAt))
                    if !post.interest.isEmpty {
                        Text("·")
                        Text(post.interest)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SyncTheme.inkMuted)

                Text(post.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !post.script.isEmpty {
                    SaveSummaryBlock(text: post.script)
                }

                if let url = URL(string: post.headlineURL), !post.headlineURL.isEmpty {
                    Button {
                        if !OutboundLink.open(url) {
                            page = InAppPage(id: url)
                        }
                    } label: {
                        storyActionRow(title: "Open original", symbol: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                }

                if let save = relatedSave {
                    NavigationLink {
                        SaveDetailView(save: save)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("From your library")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SyncTheme.inkMuted)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Text(save.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SyncTheme.ink)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SyncTheme.highlight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .padding(.bottom, 8)
        }
        .syncPullToRefresh {
            if let next = FeedStore.load().first(where: { $0.id == post.id }) {
                post = await FeedStudio.ensureBriefing(next)
            }
        }
        .background(SyncTheme.paper.ignoresSafeArea())
        .onAppear {
            hasAskThread = !SaveChatStore.load(saveID: post.id).isEmpty
        }
        .onDisappear { reader.stop() }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPicture() }
        .task {
            guard FeedStudio.isPlaceholder(post) else { return }
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(2))
                guard FeedStudio.isPlaceholder(post) else { return }
                if let stored = FeedStore.load().first(where: { $0.id == post.id }),
                   !FeedStudio.isPlaceholder(stored) {
                    var t = Transaction()
                    t.animation = nil
                    withTransaction(t) { post = stored }
                    return
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                showingAsk = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask about this story")
                            .font(.system(size: 16, weight: .medium))
                        if hasAskThread {
                            Text("Continue the thread")
                                .font(.system(size: 12))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SyncTheme.inkMuted)
                }
                .foregroundStyle(SyncTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SyncTheme.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(SyncTheme.paper.opacity(0.92))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(alignment: .center, spacing: 0) {
                    NavIconButton(accessibility: reader.isPlaying ? "Pause" : "Read aloud") {
                        reader.toggleReadAloud(post)
                    } label: {
                        Image(systemName: reader.isPlaying ? "pause.fill" : "speaker.wave.2")
                    }
                    NavIconButton(accessibility: isSaved ? "Remove from library" : "Save to library") {
                        if isSaved {
                            confirmingUnsave = true
                        } else {
                            showingSaveSheet = true
                        }
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    }
                    NavIconButton(accessibility: "Share") {
                        ArticleShare.share(post)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    NavIconButton(accessibility: "Ask about this story") {
                        showingAsk = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }
            }
        }
        .sheet(item: $page) { page in
            SafariTab(url: page.url)
                .ignoresSafeArea()
        }
        .confirmationDialog("Remove from library?", isPresented: $confirmingUnsave, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { unsaveNews() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This save will be deleted.")
        }
        .sheet(isPresented: $showingSaveSheet) {
            NewsSaveSheet(collections: collections) { note, collectionName in
                saveNews(note: note, collectionName: collectionName)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(SyncTheme.paper)
        }
        .fullScreenCover(isPresented: $showingAsk) {
            FeedAskSheet(post: post, save: relatedSave)
                .presentationBackground(SyncTheme.paper)
        }
    }

    private func storyActionRow(title: String, symbol: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: symbol)
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(SyncTheme.ink)
        .padding(14)
        .background(SyncTheme.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SyncTheme.line, lineWidth: 1)
        )
    }

    private func saveNews(note: String, collectionName: String) {
        guard !isSaved else { return }
        let briefing = post.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = post.headlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CaptureService.ingest(
            urlString: url.isEmpty ? nil : url,
            text: briefing.isEmpty ? post.title : briefing,
            imageData: nil,
            context: modelContext
        )
        result.save.title = post.title
        result.save.summary = briefing
        if result.save.creatorName.isEmpty {
            result.save.creatorName = post.sourceName
        }
        if result.save.topicsCSV.isEmpty, !post.interest.isEmpty {
            result.save.topicsCSV = post.interest
        }
        if result.save.imageFileName.isEmpty, let data = picture?.jpegData(compressionQuality: 0.85) {
            result.save.imageFileName = MediaStore.save(data, id: result.save.saveID)
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            result.save.rawText = SaveNote.merging(trimmedNote, into: result.save.rawText)
        }
        let bag = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bag.isEmpty {
            if let existing = CollectionHousekeeping.match(bag, in: collections) {
                if !result.save.collections.contains(where: { $0.collectionID == existing.collectionID }) {
                    result.save.collections.append(existing)
                }
            } else {
                let created = CollectionItem(name: bag)
                modelContext.insert(created)
                result.save.collections.append(created)
            }
        }
        try? modelContext.save()
        savedID = result.save.saveID
        savedHere = true
        LibraryBrain.pull(context: modelContext, reread: result.save)
    }

    private func unsaveNews() {
        if let item = storedSave {
            modelContext.delete(item)
            try? modelContext.save()
        }
        savedHere = false
        savedID = nil
    }

    private func loadPicture() async {
        if picture != nil { return }
        if let image = await FeedNews.loadFastImage(for: post) {
            picture = image
        }
    }
}

struct NewsSaveSheet: View {
    let collections: [CollectionItem]
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var collectionName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Note and collection are optional. Leave them blank and sync will file this from the briefing.")
                        .font(.system(size: 15))
                        .foregroundStyle(SyncTheme.inkMuted)

                    TextField("A note for yourself", text: $note, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.ink)
                        .lineLimit(2...6)
                        .padding(14)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )

                    TextField("Collection name", text: $collectionName)
                        .font(.system(size: 16))
                        .foregroundStyle(SyncTheme.ink)
                        .padding(14)
                        .background(SyncTheme.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SyncTheme.line, lineWidth: 1)
                        )

                    if !listed.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(listed) { bag in
                                    Button(bag.name) { collectionName = bag.name }
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(SyncTheme.ink)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(SyncTheme.paperRaised)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(SyncTheme.line, lineWidth: 1))
                                }
                            }
                        }
                    }

                    Button {
                        onSave(note, collectionName)
                        dismiss()
                    } label: {
                        Text("Save to library")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SyncTheme.paper)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(SyncTheme.ink)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .background(SyncTheme.paper.ignoresSafeArea())
            .navigationTitle("Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SyncTheme.inkMuted)
                }
            }
        }
    }

    private var listed: [CollectionItem] {
        collections.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct FeedAskSheet: View {
    let post: FeedPost
    let save: SaveItem?
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [SaveChatLine] = []
    @State private var draft = ""
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(post.title)
                            .font(.system(size: 18, weight: .semibold, design: .serif))
                            .foregroundStyle(SyncTheme.ink)
                            .padding(.top, 8)
                        if lines.isEmpty, !loading {
                            Text("Ask anything about this briefing.")
                                .font(.system(size: 16))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                        ForEach(lines) { line in
                            if !line.text.isEmpty {
                                bubble(line)
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
                .scrollBounceBehavior(.basedOnSize)

                HStack(alignment: .center, spacing: 8) {
                    TextField("Ask about this", text: $draft, axis: .vertical)
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
                            .font(.system(size: 16, weight: .medium))
                        Text("Ask")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(SyncTheme.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    if !lines.isEmpty {
                        Button("Clear") {
                            lines = []
                            SaveChatStore.clear(saveID: post.id)
                        }
                        .foregroundStyle(SyncTheme.inkMuted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(SyncTheme.ink)
                }
            }
        }
        .onAppear {
            lines = SaveChatStore.load(saveID: post.id)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loading
    }

    private func bubble(_ line: SaveChatLine) -> some View {
        let mine = line.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            ChatMarkdown.Rich(raw: mine ? line.text : LibraryAsk.strippedHeading(line.text), color: mine ? SyncTheme.paper : SyncTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(mine ? SyncTheme.ink : SyncTheme.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func send() async {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        lines.append(SaveChatLine.user(q))
        SaveChatStore.write(saveID: post.id, lines: lines)
        lines.append(SaveChatLine.assistant(""))
        loading = true
        let history = lines.dropLast(2).suffix(12).map { ($0.role, $0.text) }
        let answer = await FeedAsk.reply(question: q, post: post, save: save, history: Array(history)) { text in
            loading = false
            if let i = lines.indices.last {
                lines[i].text = text
            }
        }
        if let i = lines.indices.last {
            lines[i].text = answer
        }
        SaveChatStore.write(saveID: post.id, lines: lines)
        loading = false
    }
}

enum FeedAsk {
    static func reply(
        question: String,
        post: FeedPost,
        save: SaveItem?,
        history: [(String, String)],
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> String {
        if !IntelligenceKey.isConfigured {
            return "Ask isn’t available right now."
        }
        let prior = history.suffix(10).map { role, text in
            "\(role == "user" ? "User" : "Assistant"): \(text)"
        }.joined(separator: "\n")
        let related: String
        if let save {
            related = """
            Related library save: \(save.title)
            Notes: \(save.summary.isEmpty ? String(save.rawText.prefix(1200)) : save.summary)
            """
        } else {
            related = "(none)"
        }
        let user = """
        \(prior.isEmpty ? "" : "Conversation so far:\n\(prior)\n\n")
        New question: \(question)

        BRIEFING TITLE: \(post.title)
        HEADLINE: \(post.headline.isEmpty ? post.title : post.headline)
        SOURCE: \(post.sourceName)
        URL: \(post.headlineURL)
        INTEREST: \(post.interest)
        SCRIPT:
        \(post.script)

        \(related)

        Answer from this briefing. If the related save helps, use it. Never start with a heading.
        """
        guard let text = await AnthropicLibrary.reply(
            system: "You answer questions about one news briefing in a personal feed. Stay on this story. Paragraph then bullets when listing. Never start with a title.",
            user: user,
            maxTokens: 700,
            onDelta: onDelta
        ) else {
            return "Couldn’t reach the model. Try again in a moment."
        }
        return LibraryAsk.strippedHeading(text)
    }
}

