import MediaPlayer
import SwiftUI
import SwiftyTube

struct ChannelRoute: Identifiable {
    let id: String
}

struct ShortsRoute: Identifiable {
    let videos: [YouTubeVideo]
    let startId: String
    var id: String { startId }
}

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
    @Published private(set) var queue: [YouTubeVideo] = []
    @Published var channelRoute: ChannelRoute?
    @Published var shortsRoute: ShortsRoute?
    @Published var actionMessage: String?
    @Published private(set) var details: WatchDetails?
    @Published private(set) var streamSummary: String?
    @Published private(set) var loadError: String?
    @Published private(set) var captions: [YouTubeCaptionTrack] = []
    @Published private(set) var selectedCaption: String?
    @Published private(set) var captionCues: [CaptionCue] = []
    @Published var maxHeight: Int {
        didSet { UserDefaults.standard.set(maxHeight, forKey: Self.maxHeightKey) }
    }
    @Published var autoplay: Bool {
        didSet { UserDefaults.standard.set(autoplay, forKey: Self.autoplayKey) }
    }

    let player = MpvPlayer()
    /// Created on the first Short, and kept because mpv isn't torn down.
    private(set) lazy var shortsPlayer: MpvPlayer = {
        let player = MpvPlayer(surfaceAspect: 9 / 16)
        player.setProperty("loop-file", "inf")
        return player
    }()
    private(set) lazy var sleepTimer = SleepTimer { [weak self] in self?.player.setPaused(true) }
    static let qualities = [2160, 1440, 1080, 720, 480, 360]
    static let speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private static let maxHeightKey = "maxHeight"
    private static let autoplayKey = "autoplay"
    private static let captionLanguageKey = "captionLanguage"
    private var loadTask: Task<Void, Never>?
    private var nowPlayingSubscriptions: [Any] = []

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: Self.maxHeightKey)
        maxHeight = saved > 0 ? saved : 1080
        autoplay = defaults.object(forKey: Self.autoplayKey) as? Bool ?? true
        setUpRemoteCommands()
        player.onEnded = { [weak self] in self?.playNextAfterEnd() }
    }

    func play(_ video: YouTubeVideo, expand: Bool = true) {
        if video.isShort {
            openShorts([video], start: video)
            return
        }
        current = video
        channelRoute = nil
        if expand { isExpanded = true }
        details = nil
        selectedCaption = nil
        captionCues = []
        startStream(videoId: video.videoId, start: 0)
        Task { await loadDetails(videoId: video.videoId) }
    }

    /// Plays the first video and queues the rest.
    func playAll(_ videos: [YouTubeVideo], shuffled: Bool = false) {
        let playable = videos.filter { !$0.isShort }
        let ordered = shuffled ? playable.shuffled() : playable
        guard let first = ordered.first else { return }
        play(first)
        queue = Array(ordered.dropFirst())
    }

    func openShorts(_ videos: [YouTubeVideo], start: YouTubeVideo) {
        close()
        channelRoute = nil
        shortsRoute = ShortsRoute(videos: videos, startId: start.videoId)
    }

    func playNext(_ video: YouTubeVideo) {
        if current == nil {
            play(video, expand: false)
        } else {
            queue.insert(video, at: 0)
        }
    }

    func addToQueue(_ video: YouTubeVideo) {
        if current == nil {
            play(video, expand: false)
        } else {
            queue.append(video)
        }
    }

    func openChannel(_ channelId: String) {
        channelRoute = ChannelRoute(id: channelId)
    }

    /// Runs a menu action. The haptic confirms it, and a failure shows as an alert.
    func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func changeQuality(to height: Int) {
        maxHeight = height
        guard let current else { return }
        startStream(videoId: current.videoId, start: player.time)
    }

    func close() {
        loadTask?.cancel()
        current = nil
        queue = []
        isExpanded = false
        player.setBoosted(false)
        player.stop()
        sleepTimer.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func selectCaption(_ track: YouTubeCaptionTrack?) {
        selectedCaption = track?.languageCode
        captionCues = []
        UserDefaults.standard.set(track?.languageCode, forKey: Self.captionLanguageKey)
        guard let track else { return }
        Task {
            do {
                let cues = try await CaptionLoader.cues(for: track)
                guard selectedCaption == track.languageCode else { return }
                captionCues = cues
                if cues.isEmpty { actionMessage = "YouTube returned no captions for this language." }
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func setDetails(_ update: (inout WatchDetails) -> Void) {
        guard var value = details else { return }
        update(&value)
        details = value
    }

    /// The queue goes first, then autoplay takes the first related video.
    private func playNextAfterEnd() {
        if sleepTimer.stopsAtVideoEnd {
            sleepTimer.cancel()
            return
        }
        if !queue.isEmpty {
            play(queue.removeFirst(), expand: false)
        } else if autoplay, let next = details?.related.first(where: { !$0.isShort }) {
            play(next, expand: false)
        }
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
                restoreCaption()
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

    /// Captions stay on for the next video, in the language last picked.
    private func restoreCaption() {
        guard selectedCaption == nil,
              let language = UserDefaults.standard.string(forKey: Self.captionLanguageKey),
              let track = captions.first(where: { $0.languageCode == language }) else { return }
        selectCaption(track)
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
            MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0.0 : player.speed
        ]
    }
}

extension Double {
    var clockText: String {
        let pattern: Duration.TimeFormatStyle.Pattern = self >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(self).formatted(.time(pattern: pattern))
    }

    /// "1.5x", as on the speed chip.
    var speedText: String {
        formatted(.number.precision(.fractionLength(0...2))) + "x"
    }
}
