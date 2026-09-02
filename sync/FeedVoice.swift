import AVFoundation
import SwiftUI

enum FeedVoice {
    static var displayName: String {
        if ElevenLabsKey.isConfigured {
            return ElevenLabsSpeech.voiceName
        }
        return systemCurrent()?.name ?? "Default"
    }

    static func systemCurrent() -> AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: "feedSpeechVoiceID") ?? ""
        if !id.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}

enum FeedSpeechSpeed {
    static let key = "feedSpeechSpeed"
    static let lowest: Double = 0.5
    static let highest: Double = 1.5
    static let standard: Double = 1.0

    static var current: Float {
        Float(stored)
    }

    static var stored: Double {
        get {
            let defaults = AppGroup.defaults ?? UserDefaults.standard
            if defaults.object(forKey: key) == nil { return standard }
            let value = defaults.double(forKey: key)
            let raw = value == 0 ? standard : value
            return Swift.min(highest, Swift.max(lowest, raw))
        }
        set {
            let value = Swift.min(highest, Swift.max(lowest, newValue))
            UserDefaults.standard.set(value, forKey: key)
            AppGroup.defaults?.set(value, forKey: key)
            NotificationCenter.default.post(name: .feedSpeechSpeedDidChange, object: nil)
        }
    }
}

struct FeedVoicePicker: View {
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ElevenLabsSpeech.voiceID
    @State private var speed = FeedSpeechSpeed.stored
    @State private var voices: [ElevenLabsVoice] = []
    @State private var loading = false
    @State private var message = ""
    @State private var previewPlayer: AVPlayer?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Speed")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(SyncTheme.ink)
                        Spacer()
                        Text(String(format: "%.1f×", speed))
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(SyncTheme.inkMuted)
                            .monospacedDigit()
                    }
                    Slider(value: $speed, in: FeedSpeechSpeed.lowest...FeedSpeechSpeed.highest, step: 0.1)
                        .tint(SyncTheme.ink)
                    HStack {
                        Text("Slower")
                        Spacer()
                        Text("1.0×")
                        Spacer()
                        Text("Faster")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(SyncTheme.inkMuted)
                }
                .listRowBackground(SyncTheme.paperRaised)
                .onChange(of: speed) { _, value in
                    FeedSpeechSpeed.stored = value
                    previewPlayer?.rate = FeedSpeechSpeed.current
                }
            }

            if !ElevenLabsKey.isConfigured {
                Text("Using the iPhone voice until ElevenLabs is ready.")
                    .font(.system(size: 14))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .listRowBackground(SyncTheme.paperRaised)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .listRowBackground(SyncTheme.paperRaised)
            }
            ForEach(voices) { voice in
                Button {
                    pick(voice)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(voice.name)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SyncTheme.ink)
                            Text(voice.subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(SyncTheme.inkMuted)
                        }
                        Spacer()
                        if voice.id == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(SyncTheme.ink)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(SyncTheme.paperRaised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SyncTheme.paper)
        .overlay {
            if loading && voices.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(SyncTheme.ink)
            }
        }
        .task { await loadVoices() }
        .onDisappear { previewPlayer?.pause() }
    }

    private func pick(_ voice: ElevenLabsVoice) {
        selected = voice.id
        ElevenLabsSpeech.select(voice)
        onChange()
        preview(voice)
    }

    private func loadVoices() async {
        loading = true
        defer { loading = false }
        voices = await ElevenLabsSpeech.voices()
        if voices.isEmpty {
            message = "Using the iPhone voice."
        }
    }

    private func preview(_ voice: ElevenLabsVoice) {
        previewPlayer?.pause()
        message = "Generating \(voice.name)…"
        Task {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            let name = await ElevenLabsSpeech.speak(
                "This is \(voice.name).",
                id: UUID(),
                voice: voice.id,
                skipCache: true
            )
            await MainActor.run {
                guard selected == voice.id else { return }
                guard let name, let url = MediaStore.fileURL(name) else {
                    message = "Couldn’t play a sample. The feed will use the iPhone voice."
                    return
                }
                message = ""
                let player = AVPlayer(url: url)
                player.rate = FeedSpeechSpeed.current
                previewPlayer = player
                player.play()
            }
        }
    }
}
