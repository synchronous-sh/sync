import Foundation
import AVFoundation
import UIKit
import Security

struct LessonSection: Codable, Hashable, Identifiable {
    var id: String { title + body.prefix(24) }
    var eyebrow: String
    var title: String
    var body: String
    var callout: String
}

struct LessonQuestion: Codable, Hashable, Identifiable {
    var id: String { prompt }
    var prompt: String
    var choices: [String]
    var correct: Int
    var why: String
}

struct LessonPack: Codable, Hashable {
    var audioID: UUID
    var script: String
    var sections: [LessonSection]
    var questions: [LessonQuestion]
}

enum LessonStudio {
    private static let prefix = "lessonPack."

    static func key(pathID: String, lesson: String) -> String {
        "\(prefix)\(pathID).\(lesson)"
    }

    static func cached(pathID: String, lesson: String) -> LessonPack? {
        guard let data = UserDefaults.standard.data(forKey: key(pathID: pathID, lesson: lesson)) else { return nil }
        return try? JSONDecoder().decode(LessonPack.self, from: data)
    }

    static func store(_ pack: LessonPack, pathID: String, lesson: String) {
        if let data = try? JSONEncoder().encode(pack) {
            UserDefaults.standard.set(data, forKey: key(pathID: pathID, lesson: lesson))
        }
    }

    static func pack(for path: LearningPath, lesson: LearningLesson) async -> LessonPack {
        if let cached = cached(pathID: path.id, lesson: lesson.title), !cached.sections.isEmpty {
            return cached
        }
        if let generated = await generate(path: path, lesson: lesson) {
            store(generated, pathID: path.id, lesson: lesson.title)
            return generated
        }
        let fallback = localPack(path: path, lesson: lesson)
        store(fallback, pathID: path.id, lesson: lesson.title)
        return fallback
    }

    private static func generate(path: LearningPath, lesson: LearningLesson) async -> LessonPack? {
        guard IntelligenceKey.isConfigured else { return nil }
        let others = path.lessons.filter { $0.title != lesson.title }.prefix(4).map(\.title).joined(separator: ", ")
        let user = """
        Course: \(path.title)
        Course description: \(path.description)
        Lesson: \(lesson.title)
        Seed idea: \(lesson.core)
        How it works: \(lesson.mechanism)
        In practice: \(lesson.application)
        Nearby lessons: \(others)

        Write a rich teaching lesson. JSON only, no markdown fences:
        {
          "script": "spoken narration, 350-550 words, conversational, no lists",
          "sections": [
            {"eyebrow": "short label", "title": "section title", "body": "2-4 paragraphs", "callout": "one sharp takeaway"}
          ],
          "questions": [
            {"prompt": "question", "choices": ["A","B","C","D"], "correct": 0, "why": "one sentence"}
          ]
        }
        Need 5 or 6 sections and exactly 3 questions. correct is the index of the right choice. Teach the idea deeply with examples, history or mechanism, and a mistake people make.
        """
        guard let reply = await AnthropicLibrary.reply(
            system: "You write elite educational lessons for a mobile course. Output valid JSON only.",
            user: user,
            maxTokens: 2200
        ) else { return nil }
        return parse(reply, fallback: localPack(path: path, lesson: lesson))
    }

    private static func parse(_ raw: String, fallback: LessonPack) -> LessonPack? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let script = (json["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback.script
        let sections = (json["sections"] as? [[String: Any]] ?? []).compactMap { item -> LessonSection? in
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (item["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, body.count > 40 else { return nil }
            return LessonSection(
                eyebrow: item["eyebrow"] as? String ?? "",
                title: title,
                body: body,
                callout: item["callout"] as? String ?? ""
            )
        }
        let questions = (json["questions"] as? [[String: Any]] ?? []).compactMap { item -> LessonQuestion? in
            let prompt = (item["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let choices = (item["choices"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !prompt.isEmpty, choices.count >= 2 else { return nil }
            let correct = item["correct"] as? Int ?? 0
            return LessonQuestion(
                prompt: prompt,
                choices: Array(choices.prefix(4)),
                correct: min(max(0, correct), choices.count - 1),
                why: item["why"] as? String ?? ""
            )
        }
        guard sections.count >= 3 else { return nil }
        return LessonPack(
            audioID: fallback.audioID,
            script: script.isEmpty ? fallback.script : script,
            sections: sections,
            questions: questions.isEmpty ? fallback.questions : Array(questions.prefix(3))
        )
    }

    static func localPack(path: LearningPath, lesson: LearningLesson) -> LessonPack {
        let sections = [
            LessonSection(eyebrow: "The idea", title: lesson.title, body: lesson.core, callout: "Hold the definition before the details."),
            LessonSection(eyebrow: "How it works", title: "The mechanism", body: lesson.mechanism, callout: "If you can explain the mechanism, you understand it."),
            LessonSection(eyebrow: "In practice", title: "Where you see it", body: lesson.application, callout: "Look for this pattern in the real world."),
            LessonSection(
                eyebrow: "Go deeper",
                title: "Why this lesson exists",
                body: "\(path.title) is built from ideas like \(lesson.title.lowercased()). \(lesson.core) \(lesson.mechanism) The point is not memorizing a slogan. It is being able to notice the same structure when the labels change.",
                callout: "Transfer beats trivia."
            ),
            LessonSection(
                eyebrow: "Watch for this",
                title: "A common mix-up",
                body: "People often treat \(lesson.title.lowercased()) as a buzzword instead of a model. \(lesson.application) If an explanation cannot show a cause, a constraint, and an example, it is still too thin.",
                callout: "Demand a mechanism and an example."
            )
        ]
        let distractors = path.lessons.filter { $0.title != lesson.title }.map(\.title)
        let wrong = (distractors + ["A branding slogan", "A one-time event", "A coincidence with no structure"]).prefix(3)
        let questions = [
            LessonQuestion(
                prompt: "What is the core of \(lesson.title)?",
                choices: [lesson.core] + Array(wrong),
                correct: 0,
                why: lesson.core
            ),
            LessonQuestion(
                prompt: "How does \(lesson.title) actually operate?",
                choices: [lesson.mechanism, "It is chosen by majority vote.", "It only appears in textbooks.", "It replaces the need for evidence."],
                correct: 0,
                why: lesson.mechanism
            ),
            LessonQuestion(
                prompt: "Which is the best real-world use of this idea?",
                choices: [lesson.application, "Ignoring tradeoffs completely.", "Memorizing the title only.", "Avoiding any example."],
                correct: 0,
                why: lesson.application
            )
        ]
        let script = """
        This lesson is \(lesson.title), in the \(path.title) path. \(lesson.core) \
        Here is the mechanism. \(lesson.mechanism) \
        And here is where it shows up. \(lesson.application) \
        If you remember one thing, remember the mechanism, not the slogan. Then look for the same pattern in a new place.
        """
        let hasher = SHALike(path.id + lesson.title)
        return LessonPack(audioID: hasher.uuid, script: script, sections: sections, questions: questions)
    }

    static func speechID(_ seed: String) -> UUID {
        SHALike(seed).uuid
    }

    static func ask(
        question: String,
        path: LearningPath,
        lesson: LearningLesson,
        pack: LessonPack?,
        history: [(String, String)],
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> String {
        if !IntelligenceKey.isConfigured {
            return "Ask isn’t available right now."
        }
        let prior = history.suffix(8).map { role, text in
            "\(role == "user" ? "User" : "Assistant"): \(text)"
        }.joined(separator: "\n")
        let teaching = pack?.sections.map { "\($0.title): \($0.body)" }.joined(separator: "\n\n") ?? "\(lesson.core)\n\(lesson.mechanism)\n\(lesson.application)"
        let user = """
        \(prior.isEmpty ? "" : "Conversation so far:\n\(prior)\n\n")
        New question: \(question)

        COURSE: \(path.title)
        LESSON: \(lesson.title)
        TEACHING NOTES:
        \(teaching)
        """
        guard let text = await AnthropicLibrary.reply(
            system: "You are a patient tutor for one course lesson. Stay on this lesson. Explain clearly. Use a short paragraph then bullets when listing. Never start with a heading. If the student is confused, give an analogy.",
            user: user,
            maxTokens: 800,
            onDelta: onDelta
        ) else {
            return "Couldn’t reach the model. Try again in a moment."
        }
        return LibraryAsk.strippedHeading(text)
    }
}

private struct SHALike {
    var uuid: UUID

    init(_ seed: String) {
        var bytes = [UInt8](repeating: 0, count: 16)
        let data = Array(seed.utf8)
        for (i, byte) in data.enumerated() {
            bytes[i % 16] ^= byte
            bytes[(i * 3) % 16] &+= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum OpenAIImageKey {
    private static let service = "sh.synchronous.sync.openai"

    static func load() -> String {
        BundledAPIKeys.resolved(service: service, bundled: BundledAPIKeys.openai)
    }

    static func save(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static var isConfigured: Bool { !load().isEmpty }
}

private actor StudioImageGate {
    static let shared = StudioImageGate()
    private var running = 0

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        while running >= 2 {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        running += 1
        defer { running -= 1 }
        return await body()
    }
}

private actor StudioJobs {
    static let shared = StudioJobs()
    private var jobs: [UUID: Task<UIImage?, Never>] = [:]

    func run(_ id: UUID, _ work: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        if let job = jobs[id] { return await job.value }
        let job = Task { await work() }
        jobs[id] = job
        return await job.value
    }
}

enum StudioPack {
    static let size = 64

    static func image(for id: UUID) -> UIImage? {
        let hash = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = (abs(hash) % size) + 1
        return UIImage(named: String(format: "studio-%03d", index))
    }
}

enum StudioImage {
    static func make(prompt: String, id: UUID, size: String = "1024x1024") async -> UIImage? {
        if let hit = cached(id) { return hit }
        return await StudioImageGate.shared.run {
            await generate(prompt: prompt, id: id, size: size)
        }
    }

    static func fast(prompt: String, id: UUID, vertical: Bool) async -> UIImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        if let hit = cached(id) { return hit }
        let out = await StudioJobs.shared.run(id) {
            if let hit = cached(id) { return hit }
            return await StudioImageGate.shared.run {
                if let hit = cached(id) { return hit }
                let guarded = """
                \(prompt)
                Cinematic still, warm tungsten light from the left, teal shadows, film grain. No text, no logos, no nudes.
                """
                if let image = await uniqueRemote(prompt: guarded, id: id, vertical: vertical) {
                    return store(image, id: id)
                }
                return nil
            }
        }
        // #region agent log
        AgentDebug.log("C", "StudioImage.fast", "done", [
            "ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
            "ok": out != nil
        ])
        // #endregion
        return out
    }

    private static func cached(_ id: UUID) -> UIImage? {
        if let hit = FeedImageCache.image(for: id) { return hit }
        if let disk = UIImage(contentsOfFile: MediaStore.directory().appendingPathComponent("\(id.uuidString).jpg").path),
           disk.size.width >= 40 {
            FeedImageCache.store(disk, for: id)
            return disk
        }
        return nil
    }

    private static func generate(prompt: String, id: UUID, size: String) async -> UIImage? {
        if let hit = cached(id) { return hit }
        let guarded = """
        \(prompt)
        House style: cinematic editorial still, warm tungsten light from the left, charcoal and teal shadows, amber highlights, shallow depth of field, fine film grain.
        Original artwork only. Do not copy photographs, Wikipedia, stock, or known artworks.
        G-rated, all ages. No nudity, no sexual content, no gore, no graphic violence.
        No photorealistic likeness of a real public figure.
        No readable text, letters, logos, watermarks, or UI chrome.
        """
        let key = OpenAIImageKey.load()
        if !key.isEmpty,
           let image = await request(key: key, model: "gpt-image-1", prompt: guarded, size: size, extra: ["quality": "low"]) {
            return store(image, id: id)
        }
        if let image = await uniqueRemote(prompt: guarded, id: id, vertical: !size.contains("1024x1024") && size.contains("1536")) {
            return store(image, id: id)
        }
        return nil
    }

    private static func uniqueRemote(prompt: String, id: UUID, vertical: Bool) async -> UIImage? {
        let seed = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let width = 1280
        let height = 720
        let clipped = String(prompt.prefix(180))
        guard let encoded = clipped.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://image.pollinations.ai/prompt/\(encoded)?width=\(width)&height=\(height)&seed=\(seed)&nologo=true") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let image = UIImage(data: data), image.size.width >= 40 else { return nil }
        return image
    }

    private static func request(key: String, model: String, prompt: String, size: String, extra: [String: Any]) async -> UIImage? {
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 22
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": size,
            "n": 1
        ]
        for (k, v) in extra { body[k] = v }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // #region agent log
        AgentDebug.log("A", "StudioImage.request", "http", ["model": model, "status": status])
        // #endregion
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]],
              let row = rows.first else { return nil }
        if let b64 = row["b64_json"] as? String, let bytes = Data(base64Encoded: b64), let image = UIImage(data: bytes) {
            return image
        }
        if let remote = row["url"] as? String, let imageURL = URL(string: remote),
           let (bytes, imageResponse) = try? await URLSession.shared.data(from: imageURL),
           (imageResponse as? HTTPURLResponse)?.statusCode == 200 {
            return UIImage(data: bytes)
        }
        return nil
    }

    private static func store(_ image: UIImage, id: UUID) -> UIImage {
        FeedImageCache.store(image, for: id)
        if let jpeg = image.jpegData(compressionQuality: 0.86) {
            _ = MediaStore.save(jpeg, id: id)
        }
        return image
    }
}

enum LessonArt {
    static func load(course: String, pathID: String, lesson: String, slide: String, page: Int) async -> UIImage? {
        let id = SHALike("studio-pack|\(pathID)|\(page)|\(slide)").uuid
        if let hit = FeedImageCache.image(for: id) { return hit }
        if let name = CourseCovers.pageAsset(title: course, pathID: pathID, page: page),
           let image = UIImage(named: name) {
            FeedImageCache.store(image, for: id)
            // #region agent log
            AgentDebug.log("L", "LessonArt.load", "ok", ["src": "pack", "page": page, "name": name])
            // #endregion
            return image
        }
        return nil
    }
}
