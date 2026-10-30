import SwiftUI
import SwiftyTube

struct PlayerScreen: View {
    let video: YouTubeVideo

    @StateObject private var player = MpvPlayer()
    @State private var streamSummary: String?
    @State private var loadError: String?
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MpvVideoView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .overlay {
                        if streamSummary == nil, loadError == nil {
                            ProgressView().tint(.white)
                        }
                    }

                VStack(alignment: .leading, spacing: 16) {
                    Text(video.title)
                        .font(.title3.bold())

                    HStack(spacing: 12) {
                        Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                            player.togglePause()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .controlSize(.large)

                        Slider(
                            value: isScrubbing ? $scrubPosition : .constant(player.time),
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubPosition = player.time
                                } else {
                                    player.seek(to: scrubPosition)
                                }
                                isScrubbing = editing
                            }
                        )

                        Text(Duration.seconds(player.time).formatted(.time(pattern: .minuteSecond)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let streamSummary {
                        Text(streamSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let failure = loadError ?? player.errorText {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let stream = try await StreamLoader.load(videoId: video.videoId)
                streamSummary = stream.summary
                player.load(url: stream.url)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear { player.stop() }
    }
}
