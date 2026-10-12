import AVFoundation
import Combine
import SwiftUI

/// Аудио-практика дня.
///
/// Адрес файла берётся из `/audio/{code}/resolve?lang=`; если бэкенд не отдал `url`
/// (публичный базовый адрес ещё не настроен), играем напрямую с `/audio/{code}/file`.
struct AudioCard: View {
    let eid: Int
    let code: String
    let title: String?

    @EnvironmentObject private var language: LanguageStore
    @Environment(\.theme) private var t
    @StateObject private var player = AudioPlayer()

    var body: some View {
        AccentCard(accent: t.dustyBlue) {
            HStack(spacing: t.spacing.m) {
                Button {
                    Haptics.light()
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(t.terracotta)
                }
                .disabled(player.isLoading)
                .accessibilityLabel(Text(player.isPlaying ? "a11y.pauseAudio" : "a11y.playAudio"))

                VStack(alignment: .leading, spacing: t.spacing.xs) {
                    LabelTag(text: L10n("today.audio").text, color: t.dustyBlue)
                    Text(title ?? code)
                        .font(t.font.bodyEmphasized)
                        .foregroundStyle(t.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if player.duration > 0 {
                        ProgressView(value: player.progress)
                            .tint(t.terracotta)
                            .accessibilityHidden(true)
                    }
                }

                if player.isLoading {
                    ProgressView().tint(t.terracotta)
                }
            }

            if let message = player.errorMessage {
                Text(message)
                    .font(t.font.caption)
                    .foregroundStyle(t.inkDim)
            }
        }
        .task {
            await player.prepare(code: code, language: language.current.rawValue)
        }
        .onDisappear { player.stop() }
    }
}

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?

    func prepare(code: String, language: String) async {
        isLoading = true
        defer { isLoading = false }

        let api = RidgeAPI.shared
        var url: URL?
        if let resolved = try? await api.resolveAudio(code: code, lang: language),
           let raw = resolved.url, let parsed = URL(string: raw) {
            url = parsed
        } else {
            // publicBaseURL ещё не настроен — берём файл прямо с бэкенда
            url = api.audioFileURL(code: code, lang: language)
        }

        guard let url else {
            errorMessage = L10n("error.notFound").text
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let total = item.duration.seconds
                if total.isFinite, total > 0 {
                    self.duration = total
                    self.progress = time.seconds / total
                }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

#Preview {
    AudioCard(eid: 1, code: "AUDIO_BOUND_W1_A1", title: "Практика первой недели")
        .padding()
        .environmentObject(LanguageStore.shared)
        .environment(\.theme, .warm)
        .background(Theme.warm.paper)
}
