import AVFoundation
import Combine
import CryptoKit
import MediaPlayer
import SwiftUI
import SwiftyTube

struct ChannelRoute: Identifiable {
    let id: String
}

/// A channel opened as a real page, pushed in the tab it was opened from.
struct ChannelPageRoute: Hashable, Identifiable {
    let id: String
    let tab: AppTab
}

struct ShortsRoute: Identifiable {
    let model: ShortsModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}

/// The video being watched. It lives above the tabs, so playback continues
/// while the user browses with the mini player.
@MainActor
@Observable
final class Router {
    private(set) var current: YouTubeVideo?
    var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            Orientation.videoPageChanged(isOpen: isExpanded)
            videoStartedMoving(player, isOpening: isExpanded)
        }
    }
    /// True from when the video page has appeared until its closing animation ends.
    /// It decides which view holds the one video layer.
    var isWatchPageOnScreen = false {
        didSet { if !isWatchPageOnScreen { finishVideoMove(after: Self.layerSettleTime) } }
    }
    /// What the video page or the Short grows out of: the tapped cover, then the floating card.
    private(set) var zoomSource = PlayerOverlay.zoomSource
    /// The zoom draws the video layer black, so this still stands in on both the page and the card.
    private(set) var isVideoMoving = false
    private(set) var stillFrame: UIImage?
    private var moveTask: Task<Void, Never>?
    private static let stillWidth: CGFloat = 720
    private static let zoomTime = Duration.milliseconds(700)
    private static let layerSettleTime = Duration.milliseconds(150)
    private(set) var queue: [YouTubeVideo] = []
    var channelRoute: ChannelRoute?
    var channelPage: ChannelPageRoute?
    var selectedTab = AppTab.home
    /// The open Shorts page. With `shortsModel` set and this nil, the Short is in the floating card.
    var shortsRoute: ShortsRoute?
    private(set) var shortsModel: ShortsModel?
    /// Like `isWatchPageOnScreen`, for the Shorts player's layer.
    var isShortsPageOnScreen = false {
        didSet { if !isShortsPageOnScreen { finishVideoMove(after: Self.layerSettleTime) } }
    }
    /// The playlist the queue came from.
    private(set) var playlistTitle: String?
    var actionMessage: String? {
        didSet {
            if let actionMessage { FileLog.shared.append("action", "WARNING", actionMessage) }
        }
    }
    private(set) var details: WatchDetails?
    private(set) var streamSummary: String?
    private(set) var loadError: String?
    private(set) var captions: [YouTubeCaptionTrack] = []
    private(set) var selectedCaption: String?
    private(set) var captionCues: [CaptionCue] = []
    var maxHeight: Int {
        didSet { UserDefaults.standard.set(maxHeight, forKey: Self.maxHeightKey) }
    }
    var allowsPictureInPicture: Bool {
        didSet {
            UserDefaults.standard.set(allowsPictureInPicture, forKey: Self.pictureInPictureKey)
            updateAutomaticWindow()
        }
    }
    var autoplay: Bool {
        didSet { UserDefaults.standard.set(autoplay, forKey: Self.autoplayKey) }
    }
    var skipsSponsors: Bool {
        didSet { UserDefaults.standard.set(skipsSponsors, forKey: Self.skipsSponsorsKey) }
    }
    private(set) var audioTracks: [AudioTrack] = []
    private(set) var selectedAudioTrack: String?
    private(set) var storyboard: Storyboard?
    /// The details request failed, as it does for a download with no connection.
    private(set) var detailsUnavailable = false

    let player = MpvPlayer()
    @ObservationIgnored private(set) lazy var pictureInPicture: PictureInPicture = {
        let window = PictureInPicture(player: player)
        window.onFailure = { [weak self] message in self?.actionMessage = message }
        window.onRestore = { [weak self] in self?.isExpanded = true }
        return window
    }()
    /// The window for Shorts only opens by itself, when the app leaves the screen.
    @ObservationIgnored private lazy var shortsPictureInPicture: PictureInPicture = {
        let window = PictureInPicture(player: shortsPlayer)
        window.onFailure = { [weak self] message in self?.actionMessage = message }
        window.onRestore = { [weak self] in self?.expandShorts() }
        return window
    }()
    /// Created on the first Short, and kept because mpv isn't torn down.
    @ObservationIgnored private(set) lazy var shortsPlayer: MpvPlayer = {
        let player = MpvPlayer()
        player.setProperty("loop-file", "inf")
        return player
    }()
    @ObservationIgnored private(set) lazy var sleepTimer = SleepTimer { [weak self] in self?.player.setPaused(true) }
    static let qualities = [2160, 1440, 1080, 720, 480, 360]
    static let speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private static let maxHeightKey = "maxHeight"
    private static let autoplayKey = "autoplay"
    private static let handoffWaitSteps = 30
    private static let handoffLateSteps = 150
    private static let handoffUntouched = 15.0
    private static let pictureInPictureKey = "allowsPictureInPicture"
    private static let skipsSponsorsKey = "skipsSponsors"
    private static let captionLanguageKey = "captionLanguage"
    private var loadTask: Task<Void, Never>?
    private var didCreateShortsWindow = false
    private var wasInBackground = false
    private var watchReporter: WatchReporter?
    private(set) var isLive = false {
        didSet { player.isLiveStream = isLive }
    }
    private(set) var liveChatToken: String?
    private var nowPlayingSubscriptions: [Any] = []
    private var sponsorSegments: [ClosedRange<Double>] = []
    private var currentStream: LoadedStream?
    private var playlistModel: FeedModel?
    /// What the current video was started from, for downloading its neighbours.
    var playlistVideos: [YouTubeVideo] { playlistModel?.videos ?? [] }
    private var backgroundTask: Task<Void, Never>?
    /// Long enough for iOS to open the window by itself when the app leaves the screen.
    private static let windowStartDelay = Duration.seconds(1)
    /// Fewer videos than this left in the queue fetches the playlist's next page.
    private static let playlistRefill = 5

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: Self.maxHeightKey)
        maxHeight = saved > 0 ? saved : 1080
        autoplay = defaults.object(forKey: Self.autoplayKey) as? Bool ?? true
        allowsPictureInPicture = defaults.object(forKey: Self.pictureInPictureKey) as? Bool ?? true
        skipsSponsors = defaults.bool(forKey: Self.skipsSponsorsKey)
        setUpRemoteCommands()
        player.onEnded = { [weak self] in self?.playNextAfterEnd() }
    }

    func play(_ video: YouTubeVideo, expand: Bool = true) {
        if video.isShort {
            openShorts([video], start: video)
            return
        }
        closeShorts()
        SeenVideos.mark(video.videoId)
        WatchedChannels.mark(video.channelId)
        current = video
        liveChatToken = nil
        channelRoute = nil
        if expand {
            if !isExpanded { zoomSource = video.videoId }
            isExpanded = true
        }
        updateAutomaticWindow()
        details = nil
        detailsUnavailable = false
        audioTracks = []
        selectedAudioTrack = nil
        storyboard = nil
        selectedCaption = nil
        captionCues = []
        sponsorSegments = []
        player.expectedDuration = Double(video.durationSeconds ?? 0)
        player.prepareForNewVideo()
        // The frame taken above belongs to the previous video.
        stillFrame = nil
        startStream(videoId: video.videoId, start: WatchPositions.start(for: video), isNewPlayback: true)
        player.isLiveStream = video.isLive
        Task { await loadDetails(videoId: video.videoId) }
        if skipsSponsors, !SearchSettings.isIncognito {
            Task {
                let segments = await SponsorBlock.segments(videoId: video.videoId)
                if current?.videoId == video.videoId { sponsorSegments = segments }
            }
        }
    }

    /// Plays the first video and queues the rest.
    func playAll(_ videos: [YouTubeVideo], shuffled: Bool = false) {
        let playable = videos.filter { !$0.isShort }
        let ordered = shuffled ? playable.shuffled() : playable
        guard let first = ordered.first else { return }
        play(first)
        queue = Array(ordered.dropFirst())
        playlistTitle = nil
        playlistModel = nil
    }

    /// Plays a video from a playlist page, then the ones after it in order.
    func playPlaylist(_ video: YouTubeVideo, title: String, model: FeedModel) {
        let videos = model.videos.filter { !$0.isShort }
        play(video)
        queue = Array(videos.drop { $0.videoId != video.videoId }.dropFirst())
        playlistTitle = title
        playlistModel = model
        refillQueue()
    }

    /// Jumps ahead in the queue. The videos before it are skipped.
    func playFromQueue(_ video: YouTubeVideo) {
        queue = Array(queue.drop { $0.videoId != video.videoId }.dropFirst())
        play(video)
        refillQueue()
    }

    private func refillQueue() {
        guard queue.count < Self.playlistRefill, let model = playlistModel else { return }
        Task {
            if model.hasMore, let last = model.items.last { await model.loadMore(after: last) }
            guard playlistModel === model else { return }
            // Carries on after the last one already lined up, including pages the playlist screen loaded.
            let videos = model.videos.filter { !$0.isShort }
            let lined = Set(queue.map(\.videoId) + [current?.videoId].compactMap { $0 })
            guard let index = videos.lastIndex(where: { lined.contains($0.videoId) }) else { return }
            queue += videos[(index + 1)...]
        }
    }

    func openShorts(_ videos: [YouTubeVideo], start: YouTubeVideo) {
        close()
        channelRoute = nil
        let model = ShortsModel(shorts: videos, startId: start.videoId, player: shortsPlayer)
        shortsModel = model
        zoomSource = start.videoId
        videoStartedMoving(shortsPlayer, isOpening: true)
        stillFrame = nil
        shortsRoute = ShortsRoute(model: model)
        updateAutomaticWindow()
    }

    /// The Short keeps playing in the floating card.
    func minimizeShorts() {
        if shortsRoute != nil { videoStartedMoving(shortsPlayer, isOpening: false) }
        shortsRoute = nil
    }

    func expandShorts() {
        videoStartedMoving(shortsPlayer, isOpening: true)
        shortsRoute = shortsModel.map { ShortsRoute(model: $0) }
    }

    private func videoStartedMoving(_ moving: MpvPlayer, isOpening: Bool) {
        moveTask?.cancel()
        stillFrame = moving.currentFrame(width: Self.stillWidth)
        isVideoMoving = true
        // A closing page says when it's gone. An opening one doesn't say when its zoom ends.
        if isOpening { finishVideoMove(after: Self.zoomTime) }
    }

    private func finishVideoMove(after delay: Duration) {
        moveTask?.cancel()
        moveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isVideoMoving = false
            stillFrame = nil
            zoomSource = PlayerOverlay.zoomSource
        }
    }

    func closeShorts() {
        shortsRoute = nil
        guard let model = shortsModel else { return }
        shortsPictureInPicture.stop()
        model.cancel()
        model.player.stop()
        shortsModel = nil
        updateAutomaticWindow()
    }

    private func updateAutomaticWindow() {
        // The one losing the right goes first, because iOS allows one at a time.
        if shortsModel == nil {
            if didCreateShortsWindow { shortsPictureInPicture.startsAutomatically = false }
            pictureInPicture.startsAutomatically = allowsPictureInPicture && current != nil
        } else {
            pictureInPicture.startsAutomatically = false
            didCreateShortsWindow = true
            shortsPictureInPicture.startsAutomatically = allowsPictureInPicture
        }
    }

    /// iOS takes the video decoder away in the background unless the window is open.
    func sceneChanged(isBackground: Bool) {
        backgroundTask?.cancel()
        if isBackground {
            wasInBackground = true
            SeenVideos.save()
        }
        let shorts = shortsModel == nil ? nil : shortsPictureInPicture
        guard isBackground else {
            player.setVideoEnabled(true)
            shortsModel?.player.setVideoEnabled(true)
            return
        }
        backgroundTask = Task {
            try? await Task.sleep(for: Self.windowStartDelay)
            guard !Task.isCancelled else { return }
            if !pictureInPicture.isActive { player.setVideoEnabled(false) }
            if shorts?.isActive == false { shortsModel?.player.setVideoEnabled(false) }
        }
    }

    /// Coming back to the app takes the video back from the floating window.
    func sceneBecameActive() {
        guard wasInBackground else { return }
        wasInBackground = false
        if pictureInPicture.isActive {
            pictureInPicture.stop()
            isExpanded = true
        } else if didCreateShortsWindow, shortsPictureInPicture.isActive {
            shortsPictureInPicture.stop()
            expandShorts()
        }
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

    /// A sheet, for a channel among many, as on the Home feed.
    func openChannel(_ channelId: String) {
        channelRoute = ChannelRoute(id: channelId)
    }

    /// The whole page, when the channel is what the person is looking at.
    /// The video carries on in the floating card.
    func openChannelPage(_ channelId: String) {
        channelRoute = nil
        isExpanded = false
        shortsRoute = nil
        channelPage = ChannelPageRoute(id: channelId, tab: selectedTab)
    }

    /// Runs a menu action. The haptic confirms it, and a failure shows as an alert.
    func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
                // The person cancelled it, so there's nothing to report.
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func changeQuality(to height: Int) {
        maxHeight = height
        guard let current else { return }
        startStream(videoId: current.videoId, start: isLive ? 0 : player.time, isNewPlayback: false)
    }

    func close() {
        loadTask?.cancel()
        closeShorts()
        pictureInPicture.stop()
        current = nil
        updateAutomaticWindow()
        queue = []
        playlistTitle = nil
        playlistModel = nil
        isExpanded = false
        watchReporter?.finish()
        watchReporter = nil
        player.stop()
        sleepTimer.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func selectCaption(_ track: YouTubeCaptionTrack?) {
        selectedCaption = track?.languageCode
        captionCues = []
        UserDefaults.standard.set(track?.languageCode, forKey: Self.captionLanguageKey)
        guard let track else { return }
        let videoId = current?.videoId
        Task {
            do {
                let cues = try await CaptionLoader.cues(for: track)
                guard selectedCaption == track.languageCode, current?.videoId == videoId else { return }
                captionCues = cues
                if cues.isEmpty { actionMessage = "YouTube returned no captions for this language." }
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func selectAudioTrack(_ track: AudioTrack) {
        guard let videoURL = currentStream?.videoURL else { return }
        selectedAudioTrack = track.id
        let url = StreamFallback.combineVideoAndAudio(videoURL: videoURL, audioURL: track.url, duration: currentStream?.duration)
        player.load(url: url, start: player.time)
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
            refillQueue()
        } else if autoplay, let next = details?.related.first(where: { !$0.isShort }) {
            play(next, expand: false)
        }
    }

    /// Saves the position and jumps over sponsor segments as playback advances.
    private func playbackTick(_ time: Double) {
        guard let current, player.duration > 0 else { return }
        WatchPositions.save(videoId: current.videoId, time: time, duration: player.duration)
        watchReporter?.tick(time)
        // Leaves out the end, because the seek below lands there and calls this again at once.
        if let segment = sponsorSegments.first(where: { time >= $0.lowerBound && time < $0.upperBound }) {
            player.seek(to: segment.upperBound)
        }
    }

    private func loadMissingCaptions(videoId: String) async {
        guard captions.isEmpty else { return }
        let found = await StreamLoader.captions(videoId: videoId)
        guard !Task.isCancelled else { return }
        captions = found
        restoreCaption()
    }

    /// The video waits a moment for the account, so it usually starts in the right place.
    private func handoffStart(from start: Double, isNewPlayback: Bool, duration: Int?) async -> Double {
        guard isNewPlayback, let watchReporter else { return start }
        await watchReporter.waitForAccount(steps: Self.handoffWaitSteps)
        return watchReporter.position(local: start, duration: (duration ?? current?.durationSeconds).map(Double.init))
    }

    /// A slower answer still counts: the video moves there, unless you've already moved it yourself.
    private func finishHandoff(videoId: String, local: Double, startedAt: Double, duration: Int?) {
        guard let watchReporter else { return }
        let seconds = (duration ?? current?.durationSeconds).map(Double.init)
        Task {
            await watchReporter.waitForAccount(steps: Self.handoffLateSteps)
            player.note(watchReporter.summary(local: local, duration: seconds))
            let target = watchReporter.position(local: local, duration: seconds)
            guard abs(target - startedAt) > 1 else { return }
            for _ in 0..<Self.handoffLateSteps where !player.isVideoReady {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard current?.videoId == videoId, player.isVideoReady,
                  abs(player.time - startedAt) < Self.handoffUntouched else { return }
            player.seek(to: target)
        }
    }

    private func startStream(videoId: String, start: Double, isNewPlayback: Bool) {
        loadTask?.cancel()
        streamSummary = nil
        loadError = nil
        captions = []
        isLive = false
        if isNewPlayback {
            watchReporter?.finish()
            watchReporter = WatchReporter(videoId: videoId)
        }
        loadTask = Task {
            if let local = DownloadStore.shared.stream(videoId: videoId) {
                streamSummary = "Downloaded"
                let from = await handoffStart(from: start, isNewPlayback: isNewPlayback, duration: nil)
                guard !Task.isCancelled else { return }
                player.load(url: local, start: from)
                if isNewPlayback { finishHandoff(videoId: videoId, local: start, startedAt: from, duration: nil) }
                updateNowPlaying()
                await loadMissingCaptions(videoId: videoId)
                return
            }
            do {
                let started = Date()
                let stream = try await StreamLoader.load(videoId: videoId, maxHeight: maxHeight)
                player.note("Stream found in \(Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))) s")
                guard !Task.isCancelled else { return }
                currentStream = stream
                selectedAudioTrack = nil
                streamSummary = stream.summary
                isLive = stream.isLive
                captions = stream.captions
                restoreCaption()
                let from = stream.isLive ? start : await handoffStart(from: start, isNewPlayback: isNewPlayback, duration: stream.duration)
                guard !Task.isCancelled else { return }
                player.load(url: stream.url, start: from)
                if isNewPlayback, !stream.isLive { finishHandoff(videoId: videoId, local: start, startedAt: from, duration: stream.duration) }
                updateNowPlaying()
                await loadMissingCaptions(videoId: videoId)
                guard !Task.isCancelled else { return }
                if let client = stream.client {
                    let extras = await StreamLoader.extras(videoId: videoId, client: client)
                    guard !Task.isCancelled else { return }
                    audioTracks = extras.tracks
                    storyboard = extras.storyboard
                }
                if storyboard == nil, !stream.isLive {
                    let found = await StreamLoader.storyboard(videoId: videoId)
                    guard !Task.isCancelled else { return }
                    storyboard = found
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
        guard let json = try? await InnerTubeClient.wooftube.next(videoId: videoId) else {
            if current?.videoId == videoId { detailsUnavailable = true }
            return
        }
        guard current?.videoId == videoId else { return }
        let loaded = await offMain { WatchDetails(json: json, videoId: videoId) }
        guard current?.videoId == videoId else { return }
        details = loaded
        WatchedChannels.mark(loaded.channelId)
        liveChatToken = JSON.string("continuation", in: JSON.first("liveChatRenderer", in: json))
        async let dislikes = DislikeCounts.fetch(videoId: videoId)
        async let comment = CommentsPage.topComment(token: loaded.commentsToken)
        async let options = PlaylistActions.options(for: videoId)
        let (dislikeCount, firstComment, playlists) = await (dislikes, comment, options)
        guard current?.videoId == videoId else { return }
        setDetails {
            $0.dislikeCount = dislikeCount
            $0.topComment = firstComment
            $0.isInWatchLater = playlists.contains { $0.id == YouTubeFeeds.watchLaterPlaylistId && $0.containsVideo }
        }
    }

    private var activePlayer: MpvPlayer { shortsModel?.player ?? player }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.activePlayer.setPaused(false)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.activePlayer.setPaused(true)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.activePlayer.togglePause()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(to: event.positionTime)
            return .success
        }
        nowPlayingSubscriptions = [
            // These fire just before the value changes, so the update waits for the next turn.
            player.$duration.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateNowPlaying() },
            player.$isPaused.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateNowPlaying() },
            player.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateNowPlaying() },
            // A stream that won't play shouldn't come back from the cache when the video is opened again.
            player.$errorText.compactMap { $0 }.sink { [weak self] _ in
                guard let videoId = self?.current?.videoId else { return }
                Task { await StreamLoader.forget(videoId: videoId) }
            },
            player.clock.$time.sink { [weak self] time in self?.playbackTick(time) }
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

extension CommentsPage {
    /// YouTube sorts comments by relevance first, so this is the one it would show.
    static func topComment(token: String?) async -> Comment? {
        guard let token, let json = try? await InnerTubeClient.wooftube.next(continuation: token) else { return nil }
        return CommentsPage(json: json).comments.first
    }
}

/// Where each video was left, on this device.
enum WatchPositions {
    static func reload() {
        positions = ProfileStorage.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private static let key = "watchPositions"
    private static let minimumPosition = 10.0
    static let finishedFraction = 0.95
    private static let saveEverySeconds = 5
    // ponytail: grows by one number per video watched; prune by date if it ever gets large.
    private static var positions = ProfileStorage.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]

    static func start(for video: YouTubeVideo) -> Double {
        positions[video.videoId] ?? 0
    }

    /// Reports go out every 30 seconds and YouTube's progress is a whole percent, so a smaller
    /// difference than this is the same viewing. A bigger one is another device.
    static func handoff(local: Double, account: Double?, duration: Double?) -> Double {
        guard let account else { return local }
        if let duration, duration > 0, account / duration >= finishedFraction { return local }
        let margin = max(handoffMargin, (duration ?? 0) * 0.02)
        return abs(account - local) > margin ? account : local
    }

    private static let handoffMargin = 45.0

    /// YouTube's own progress, for a video this phone has no position for.
    static func seed(videoId: String, time: Double) {
        if positions[videoId] == nil { positions[videoId] = time }
    }

    /// From 0 to 1, for the line on a thumbnail.
    static func progress(of video: YouTubeVideo) -> Double? {
        guard let position = positions[video.videoId], let duration = video.durationSeconds, duration > 0 else { return nil }
        return min(position / Double(duration), 1)
    }

    static func save(videoId: String, time: Double, duration: Double) {
        guard !SearchSettings.isIncognito else { return }
        if time / duration >= finishedFraction {
            guard positions.removeValue(forKey: videoId) != nil else { return }
        } else if time >= minimumPosition, Int(time) % saveEverySeconds == 0, Int(positions[videoId] ?? -1) != Int(time) {
            positions[videoId] = time
        } else {
            return
        }
        ProfileStorage.defaults.set(positions, forKey: key)
    }
}

/// YouTube hides dislike counts, so this is Return YouTube Dislike's community estimate.
struct VoteCounts {
    let likes: Int
    let dislikes: Int
}

@MainActor
enum DislikeCounts {
    static let enabledKey = "showsDislikeCounts"
    private static var cache: [String: VoteCounts] = [:]
    /// The service limits requests, so a refusal stops them for a while.
    private static var pausedUntil = Date.distantPast

    static func cached(videoId: String) -> VoteCounts? {
        cache[videoId]
    }

    static func votes(videoId: String) async -> VoteCounts? {
        guard !SearchSettings.isIncognito else { return nil }
        if let known = cache[videoId] { return known }
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true, Date() > pausedUntil,
              let url = URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(videoId)"),
              let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if (response as? HTTPURLResponse)?.statusCode == 429 {
            pausedUntil = Date().addingTimeInterval(60)
            return nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let likes = json["likes"] as? Int, let dislikes = json["dislikes"] as? Int else { return nil }
        let votes = VoteCounts(likes: likes, dislikes: dislikes)
        cache[videoId] = votes
        return votes
    }

    static func fetch(videoId: String) async -> Int? {
        await votes(videoId: videoId)?.dislikes
    }
}

extension Int {
    /// "1.2K", like YouTube's like count.
    var compactText: String {
        formatted(.number.notation(.compactName))
    }
}

/// SponsorBlock's community list of sponsor segments. It's opt-in, and it only receives the start
/// of a code many videos share, so it answers for all of them and can't tell which one is playing.
enum SponsorBlock {
    static func segments(videoId: String) async -> [ClosedRange<Double>] {
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments/\(hashPrefix(of: videoId))?category=sponsor"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return segments(in: entries, videoId: videoId)
    }

    private static func hashPrefix(of videoId: String) -> String {
        SHA256.hash(data: Data(videoId.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    private static func segments(in entries: [[String: Any]], videoId: String) -> [ClosedRange<Double>] {
        let entry = entries.first { $0["videoID"] as? String == videoId }
        return (entry?["segments"] as? [[String: Any]] ?? []).compactMap { item in
            guard let segment = item["segment"] as? [Double], segment.count == 2, segment[0] < segment[1] else { return nil }
            return segment[0]...segment[1]
        }
    }

    static func selfCheck() {
        assert(hashPrefix(of: "dQw4w9WgXcQ") == "5f6b")
        let entries: [[String: Any]] = [
            ["videoID": "other", "segments": [["segment": [1.0, 2.0]]]],
            ["videoID": "mine", "segments": [["segment": [3.0, 4.0]], ["segment": [5.0, 5.0]]]]
        ]
        assert(segments(in: entries, videoId: "mine") == [3.0...4.0])
        assert(segments(in: entries, videoId: "none").isEmpty)
    }
}

extension Double {
    var clockText: String {
        // Duration.seconds crashes on an invalid number.
        guard isFinite else { return "0:00" }
        let pattern: Duration.TimeFormatStyle.Pattern = self >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(self).formatted(.time(pattern: pattern))
    }

    /// "1.5x", as on the speed chip.
    var speedText: String {
        formatted(.number.precision(.fractionLength(0...2))) + "x"
    }
}
