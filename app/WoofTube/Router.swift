import MediaPlayer
import SwiftUI
import SwiftyTube

/// The video being watched. It lives above the tabs, so playback continues
/// while the user browses with the mini player.
@MainActor
final class Router: ObservableObject {
    @Published private(set) var current: YouTubeVideo?
    @Published var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            Orientation.videoPageChanged(isOpen: isExpanded)
        }
    }
    @Published var zoomSourceID = ""
    @Published private(set) var details: WatchDetails?
    @Published private(set) var streamSummary: String?
    @Published private(set) var loadError: String?
    @Published private(set) var captions: [YouTubeCaptionTrack] = []
    @Published var selectedCaption: String?
    @Published var maxHeight: Int {
        didSet { UserDefaults.standard.set(maxHeight, forKey: Self.maxHeightKey) }
    }

    let player = MpvPlayer(surfaceAspect: 16 / 9)
    static let qualities = [2160, 1440, 1080, 720, 480, 360]
    private static let maxHeightKey = "maxHeight"
    private var loadTask: Task<Void, Never>?
    private var nowPlayingSubscriptions: [Any] = []

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.maxHeightKey)
        maxHeight = saved > 0 ? saved : 1080
        setUpRemoteCommands()
    }

    func play(_ video: YouTubeVideo) {
        current = video
        if !isExpanded { zoomSourceID = video.videoId }
        isExpanded = true
        details = nil
        selectedCaption = nil
        player.setVideoEnabled(true)
        startStream(videoId: video.videoId, start: 0)
        Task { await loadDetails(videoId: video.videoId) }
    }

    func changeQuality(to height: Int) {
        maxHeight = height
        guard let current else { return }
        startStream(videoId: current.videoId, start: player.time)
    }

    func close() {
        loadTask?.cancel()
        current = nil
        isExpanded = false
        player.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func selectCaption(_ track: YouTubeCaptionTrack?) {
        selectedCaption = track?.languageCode
        player.showSubtitles(url: track?.baseURL.map { $0 + "&fmt=vtt" })
    }

    func setDetails(_ update: (inout WatchDetails) -> Void) {
        guard var value = details else { return }
        update(&value)
        details = value
    }

    private func startStream(videoId: String, start: Double) {
        loadTask?.cancel()
        streamSummary = nil
        loadError = nil
        captions = []
        loadTask = Task {
            do {
                let stream = try await StreamLoader.load(videoId: videoId, maxHeight: maxHeight)
                guard !Task.isCancelled else { return }
                streamSummary = stream.summary
                captions = stream.captions
                player.load(url: stream.url, start: start)
                updateNowPlaying()
                if start == 0, let tracking = stream.trackingURL {
                    try? await InnerTubeClient.wooftube.registerPlayback(trackingUrl: tracking, client: .web)
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private func loadDetails(videoId: String) async {
        guard let json = try? await InnerTubeClient.wooftube.next(videoId: videoId),
              current?.videoId == videoId else { return }
        details = WatchDetails(json: json, videoId: videoId)
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [player] _ in
            player.setPaused(false)
            return .success
        }
        center.pauseCommand.addTarget { [player] _ in
            player.setPaused(true)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [player] _ in
            player.togglePause()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(to: event.positionTime)
            return .success
        }
        nowPlayingSubscriptions = [
            player.$duration.sink { [weak self] _ in self?.updateNowPlaying() },
            player.$isPaused.sink { [weak self] _ in self?.updateNowPlaying() }
        ]
    }

    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.channelTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.time,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0.0 : 1.0
        ]
    }
}

extension Double {
    var clockText: String {
        let pattern: Duration.TimeFormatStyle.Pattern = self >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(self).formatted(.time(pattern: pattern))
    }
}
