import Foundation
import AVFoundation
@preconcurrency import Speech

private final class SpeechJob: @unchecked Sendable {
    let recognizer: SFSpeechRecognizer
    let request: SFSpeechURLRecognitionRequest

    init(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) {
        self.recognizer = recognizer
        self.request = request
    }
}

enum Transcribe {
    static func fromMedia(_ url: URL) async -> String {
        guard await ensurePermission() else { return "" }

        let audioURL = await withTimeout(seconds: 12, fallback: nil as URL?) {
            await flattenedAudio(from: url)
        } ?? url

        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return "" }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        let job = SpeechJob(recognizer: recognizer, request: request)
        return await withTimeout(seconds: 22, fallback: "") {
            await recognize(job)
        }
    }

    static func ensurePermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { next in
                continuation.resume(returning: next == .authorized)
            }
        }
    }

    static func askPermissionIfNeeded() {
        Task { _ = await ensurePermission() }
    }

    private static func recognize(_ job: SpeechJob) async -> String {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var best = ""
            let finish: (String) -> Void = { text in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: text)
            }
            job.recognizer.recognitionTask(with: job.request) { result, error in
                if let result {
                    best = result.bestTranscription.formattedString
                    if result.isFinal { finish(best) }
                } else if error != nil {
                    finish(best)
                }
            }
        }
    }

    private static func flattenedAudio(from video: URL) async -> URL? {
        let ext = video.pathExtension.lowercased()
        if ["m4a", "mp3", "wav", "caf", "aac"].contains(ext) { return video }

        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 90, preferredTimescale: 600)
        let seconds = min(90, max(1, CMTimeGetSeconds(duration)))
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        do {
            try await session.export(to: out, as: .m4a)
            return out
        } catch {
            return nil
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        work: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return fallback
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}
