import MediaPlayer
import SwiftUI
import SwiftyTube

struct ChannelRoute: Identifiable {
    let id: String
}

struct ShortsRoute: Identifiable {
    let model: ShortsModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
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
    /// True from when the video page has appeared until its closing animation ends.
    /// It decides which view holds the one video layer.
    @Published var isWatchPageOnScreen = false
    @Published private(set) var queue: [YouTubeVideo] = []
    @Published var channelRoute: ChannelRoute?
    /// The open Shorts page. With `shortsModel` set and this nil, the Short is in the floating card.
    @Published var shortsRoute: ShortsRoute?
    @Published private(set) var shortsModel: ShortsModel?
    /// Like `isWatchPageOnScreen`, for the Shorts player's layer.
    @Published var isShortsPageOnScreen = false
    /// The playlist the queue came from.
    @Published private(set) var playlistTitle: String?
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
    @Published var skipsSponsors: Bool {
        didSet { UserDefaults.standard.set(skipsSponsors, forKey: Self.skipsSponsorsKey) }
    }
    @Published private(set) var isCaptionTranslated = false
    @Published private(set) var audioTracks: [AudioTrack] = []
    @Published private(set) var selectedAudioTrack: String?
    @Published private(set) var storyboard: Storyboard?
    /// The details request failed, as it does for a download with no connection.
    @Published private(set) var detailsUnavailable = false

    let player = MpvPlayer()
    private(set) lazy var pictureInPicture: PictureInPicture = {
        let window = PictureInPicture(player: player)
        window.onFailure = { [weak self] message in self?.actionMessage = message }
        window.onRestore = { [weak self] in self?.isExpanded = true }
        return window
    }()
    /// The window for Shorts only opens by itself, when the app leaves the screen.
    private lazy var shortsPictureInPicture: PictureInPicture = {
        let window = PictureInPicture(player: shortsPlayer)
        window.onFailure = { [weak self] message in self?.actionMessage = message }
        window.onRestore = { [weak self] in self?.expandShorts() }
        return window
    }()
    /// Created on the first Short, and kept because mpv isn't torn down.
    private(set) lazy var shortsPlayer: MpvPlayer = {
        let player = MpvPlayer()
        player.setProperty("loop-file", "inf")
        return player
    }()
    private(set) lazy var sleepTimer = SleepTimer { [weak self] in self?.player.setPaused(true) }
    static let qualities = [2160, 1440, 1080, 720, 480, 360]
    static let speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private static let maxHeightKey = "maxHeight"
    private static let autoplayKey = "autoplay"
    private static let skipsSponsorsKey = "skipsSponsors"
    private static let captionLanguageKey = "captionLanguage"
    private var loadTask: Task<Void, Never>?
    private var didCreateShortsWindow = false
    private var nowPlayingSubscriptions: [Any] = []
    private var sponsorSegments: [ClosedRange<Double>] = []
    private var currentStream: LoadedStream?
    private var playlistModel: FeedModel?
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
        current = video
        channelRoute = nil
        if expand { isExpanded = true }
        updateAutomaticWindow()
        details = nil
        detailsUnavailable = false
        audioTracks = []
        selectedAudioTrack = nil
        storyboard = nil
        selectedCaption = nil
        captionCues = []
        sponsorSegments = []
        player.prepareForNewVideo()
        startStream(videoId: video.videoId, start: WatchPositions.start(for: video), isNewPlayback: true)
        Task { await loadDetails(videoId: video.videoId) }
        if skipsSponsors {
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
        guard queue.count < Self.playlistRefill, let model = playlistModel, model.hasMore, let last = model.items.last else { return }
        let known = Set(model.videos.map(\.videoId))
        Task {
            await model.loadMore(after: last)
            guard playlistModel === model else { return }
            queue += model.videos.filter { !known.contains($0.videoId) && !$0.isShort }
        }
    }

    func openShorts(_ videos: [YouTubeVideo], start: YouTubeVideo) {
        close()
        channelRoute = nil
        let model = ShortsModel(shorts: videos, startId: start.videoId, player: shortsPlayer)
        shortsModel = model
        shortsRoute = ShortsRoute(model: model)
        updateAutomaticWindow()
    }

    /// The Short keeps playing in the floating card.
    func minimizeShorts() {
        shortsRoute = nil
    }

    func expandShorts() {
        shortsRoute = shortsModel.map { ShortsRoute(model: $0) }
    }

    func closeShorts() {
        shortsRoute = nil
        guard let model = shortsModel else { return }
        shortsPictureInPicture.stop()
        model.player.stop()
        shortsModel = nil
        updateAutomaticWindow()
    }

    private func updateAutomaticWindow() {
        // The one losing the right goes first, because iOS allows one at a time.
        if shortsModel == nil {
            if didCreateShortsWindow { shortsPictureInPicture.startsAutomatically = false }
            pictureInPicture.startsAutomatically = current != nil
        } else {
            pictureInPicture.startsAutomatically = false
            didCreateShortsWindow = true
            shortsPictureInPicture.startsAutomatically = true
        }
    }

    /// iOS takes the video decoder away in the background unless the window is open.
    func sceneChanged(isBackground: Bool) {
        backgroundTask?.cancel()
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
        startStream(videoId: current.videoId, start: player.time, isNewPlayback: false)
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
        player.stop()
        sleepTimer.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func selectCaption(_ track: YouTubeCaptionTrack?, translated: Bool = false) {
        selectedCaption = track?.languageCode
        isCaptionTranslated = translated
        captionCues = []
        UserDefaults.standard.set(track?.languageCode, forKey: Self.captionLanguageKey)
        guard let track else { return }
        Task {
            do {
                let cues = try await CaptionLoader.cues(for: track, translated: translated)
                guard selectedCaption == track.languageCode else { return }
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
        if let segment = sponsorSegments.first(where: { $0.contains(time) }) {
            player.seek(to: segment.upperBound)
        }
    }

    private func startStream(videoId: String, start: Double, isNewPlayback: Bool) {
        loadTask?.cancel()
        streamSummary = nil
        loadError = nil
        captions = []
        loadTask = Task {
            if let local = DownloadStore.shared.stream(videoId: videoId) {
                streamSummary = "Downloaded"
                player.load(url: local, start: start)
                updateNowPlaying()
                return
            }
            do {
                let stream = try await StreamLoader.load(videoId: videoId, maxHeight: maxHeight)
                guard !Task.isCancelled else { return }
                currentStream = stream
                selectedAudioTrack = nil
                streamSummary = stream.summary
                captions = stream.captions
                restoreCaption()
                player.load(url: stream.url, start: start)
                updateNowPlaying()
                if let client = stream.client {
                    let extras = await StreamLoader.extras(videoId: videoId, client: client)
                    guard !Task.isCancelled else { return }
                    audioTracks = extras.tracks
                    storyboard = extras.storyboard
                }
                if isNewPlayback, let tracking = stream.trackingURL {
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
        guard let json = try? await InnerTubeClient.wooftube.next(videoId: videoId) else {
            if current?.videoId == videoId { detailsUnavailable = true }
            return
        }
        guard current?.videoId == videoId else { return }
        let loaded = WatchDetails(json: json, videoId: videoId)
        details = loaded
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
            player.$isPaused.sink { [weak self] _ in self?.updateNowPlaying() },
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
    private static let finishedFraction = 0.95
    private static let saveEverySeconds = 5
    // ponytail: grows by one number per video watched; prune by date if it ever gets large.
    private static var positions = ProfileStorage.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]

    static func start(for video: YouTubeVideo) -> Double {
        positions[video.videoId] ?? 0
    }

    /// From 0 to 1, for the line on a thumbnail.
    static func progress(of video: YouTubeVideo) -> Double? {
        guard let position = positions[video.videoId], let duration = video.durationSeconds, duration > 0 else { return nil }
        return min(position / Double(duration), 1)
    }

    static func save(videoId: String, time: Double, duration: Double) {
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

/// SponsorBlock's community list of sponsor segments. It receives the video ID, so it's opt-in.
enum SponsorBlock {
    static func segments(videoId: String) async -> [ClosedRange<Double>] {
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&category=sponsor"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let segment = entry["segment"] as? [Double], segment.count == 2, segment[0] < segment[1] else { return nil }
            return segment[0]...segment[1]
        }
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
