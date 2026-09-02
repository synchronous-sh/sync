import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoRead {
    struct Insight {
        var ocr: String
        var transcript: String
        var frames: [Data]
    }

    static func inspect(_ url: URL) async -> Insight {
        let grabbed = await frames(from: url)
        var ocrChunks: [String] = []
        var scored: [(score: Int, data: Data)] = []
        for data in grabbed {
            let text = Enrichment.ocr(data)
            if !text.isEmpty { ocrChunks.append(text) }
            scored.append((text.count, data))
        }
        let uniqueOCR = uniqued(ocrChunks.joined(separator: "\n"))
        let bestFrames = scored.sorted { $0.score > $1.score }.prefix(4).map(\.data)
        let spoken = await Transcribe.fromMedia(url)
        let frames = bestFrames.isEmpty ? Array(grabbed.prefix(4)) : Array(bestFrames)
        return Insight(
            ocr: uniqueOCR,
            transcript: spoken,
            frames: frames
        )
    }

    private static func frames(from url: URL) async -> [Data] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        _ = try? await asset.load(.tracks)
        let duration = (try? await asset.load(.duration)) ?? .zero
        var length = CMTimeGetSeconds(duration)
        if !length.isFinite || length <= 0.05 {
            length = 6
        }

        var percents = [0.0, 0.12, 0.28, 0.45, 0.62, 0.78, 0.92]
        if length < 10 {
            percents = [0.0, 0.2, 0.4, 0.6, 0.8, 0.95]
        }
        let times = percents.map {
            CMTime(seconds: min(length * $0, max(0, length - 0.05)), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let stamps = times.map { NSValue(time: $0) }
        return await withCheckedContinuation { continuation in
            guard !stamps.isEmpty else {
                continuation.resume(returning: [])
                return
            }
            let bag = FrameBag(remaining: stamps.count)
            generator.generateCGImagesAsynchronously(forTimes: stamps) { _, image, _, result, _ in
                if result == .succeeded, let image, let data = jpeg(from: image, quality: 0.72) {
                    bag.append(data)
                }
                if let out = bag.finishOne() {
                    continuation.resume(returning: out)
                }
            }
        }
    }

    private static func jpeg(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func uniqued(_ text: String) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2 else { continue }
            let key = line.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private final class FrameBag: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [Data] = []
        private var remaining: Int
        private var finished = false

        init(remaining: Int) {
            self.remaining = remaining
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            if collected.count < 8 { collected.append(data) }
        }

        func finishOne() -> [Data]? {
            lock.lock()
            defer { lock.unlock() }
            remaining -= 1
            guard remaining == 0, !finished else { return nil }
            finished = true
            return collected
        }
    }
}
