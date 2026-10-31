import SwiftUI
import SwiftyTube

/// Plays one Short at a time on its own 9:16 player and keeps the feed going with the search filter,
/// because YouTube answers FEshorts with an error when signed out.
@MainActor
final class ShortsModel: ObservableObject {
    private static let shortsSearchFilter = "EgIYAQ%3D%3D"

    @Published private(set) var shorts: [YouTubeVideo]
    @Published private(set) var details: WatchDetails?
    @Published private(set) var errorText: String?
    /// The Short attached to the player. Other pages show their thumbnail.
    @Published private(set) var playingId: String?
    @Published private(set) var captions: [YouTubeCaptionTrack] = []
    @Published private(set) var selectedCaption: String?
    @Published private(set) var captionCues: [CaptionCue] = []
    let player: MpvPlayer
    private var nextToken: String?
    private var didLoadMore = false

    init(shorts: [YouTubeVideo], player: MpvPlayer) {
        self.shorts = shorts
        self.player = player
    }

    func play(_ video: YouTubeVideo) async {
        player.prepareForNewVideo()
        playingId = video.videoId
        details = nil
        errorText = nil
        captions = []
        selectedCaption = nil
        captionCues = []
        do {
            let stream = try await StreamLoader.load(videoId: video.videoId, maxHeight: 1080)
            guard !Task.isCancelled else { return }
            captions = stream.captions
            player.load(url: stream.url)
        } catch {
            errorText = error.localizedDescription
        }
        let json = try? await InnerTubeClient.wooftube.next(videoId: video.videoId)
        details = json.map { WatchDetails(json: $0, videoId: video.videoId) }
        let dislikes = await DislikeCounts.fetch(videoId: video.videoId)
        if playingId == video.videoId { details?.dislikeCount = dislikes }
        await loadMoreIfNeeded(after: video)
    }

    func setLike(_ status: String, video: YouTubeVideo) async {
        guard let previous = details?.likeStatus else { return }
        details?.likeStatus = status
        let tube = InnerTubeClient.wooftube
        do {
            switch status {
            case "LIKE": _ = try await tube.like(videoId: video.videoId)
            case "DISLIKE": _ = try await tube.dislike(videoId: video.videoId)
            default: _ = try await tube.unlike(videoId: video.videoId)
            }
        } catch {
            details?.likeStatus = previous
            errorText = error.localizedDescription
        }
    }

    func setSubscribed(_ value: Bool) {
        details?.isSubscribed = value
    }

    func selectCaption(_ track: YouTubeCaptionTrack?) {
        selectedCaption = track?.languageCode
        captionCues = []
        guard let track else { return }
        Task {
            let cues = (try? await CaptionLoader.cues(for: track)) ?? []
            if selectedCaption == track.languageCode { captionCues = cues }
        }
    }

    private func loadMoreIfNeeded(after video: YouTubeVideo) async {
        guard video.videoId == shorts.last?.videoId else { return }
        let tube = InnerTubeClient.wooftube
        let json: [String: Any]?
        if let token = nextToken {
            nextToken = nil
            json = try? await tube.search(query: "shorts", continuation: token)
        } else if !didLoadMore {
            didLoadMore = true
            json = try? await tube.search(query: "shorts", params: Self.shortsSearchFilter)
        } else {
            json = nil
        }
        guard let json else { return }
        let known = Set(shorts.map(\.videoId))
        shorts += YouTubeFeedParser.videos(in: json).filter { $0.isShort && !known.contains($0.videoId) }
        nextToken = YouTubeFeedParser.continuation(in: json)
    }
}

struct ShortsView: View {
    @StateObject private var model: ShortsModel
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentId: String?
    @State private var showsComments = false
    @State private var showsDescription = false
    @State private var isBoosting = false

    /// Time for the full screen cover to close before the channel sheet can open.
    private static let coverCloseDelay = Duration.milliseconds(400)

    init(route: ShortsRoute, player: MpvPlayer) {
        _model = StateObject(wrappedValue: ShortsModel(shorts: route.videos, player: player))
        _currentId = State(initialValue: route.startId)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.shorts, id: \.videoId) { video in
                    page(video)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(video.videoId)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentId)
        .ignoresSafeArea()
        .background(.black)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topLeading) {
            Button("Close", systemImage: "chevron.down") { router.shortsRoute = nil }
                .buttonStyle(PlayerPressStyle())
                .labelStyle(PlayerGlyphLabelStyle(size: 20))
                .padding(.horizontal, Layout.chipSpacing)
        }
        .overlay(alignment: .top) {
            if isBoosting { BoostPill() }
        }
        .sheet(isPresented: $showsComments) {
            if let token = model.details?.commentsToken {
                CommentsSheet(token: token)
            }
        }
        .sheet(isPresented: $showsDescription) {
            ScrollView {
                Text(model.details?.description ?? "No description.")
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Layout.screenPadding)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: currentId) {
            guard let video = model.shorts.first(where: { $0.videoId == currentId }) else { return }
            await model.play(video)
        }
        .onChange(of: scenePhase) {
            model.player.setVideoEnabled(scenePhase != .background)
        }
        .onDisappear {
            model.player.setBoosted(false)
            model.player.stop()
        }
    }

    private func page(_ video: YouTubeVideo) -> some View {
        let isCurrent = video.videoId == currentId
        return ZStack(alignment: .bottom) {
            if video.videoId == model.playingId {
                MpvVideoView(player: model.player)
                VideoPoster(player: model.player, video: video)
            } else {
                CoverImage(url: video.thumbnailURL)
            }
            PlayerTouchSurface(
                onTap: { model.player.togglePause() },
                onBoost: { boosting in
                    isBoosting = boosting
                    model.player.setBoosted(boosting)
                }
            )
            if isCurrent {
                CaptionOverlay(clock: model.player.clock, cues: model.captionCues, isFullscreen: false)
                    .padding(.bottom, 160)
            }
            VStack(spacing: Layout.chipSpacing) {
                HStack(alignment: .bottom, spacing: Layout.rowSpacing) {
                    info(video, isCurrent: isCurrent)
                    if isCurrent {
                        rail(video)
                    }
                }
                .padding(.horizontal, Layout.screenPadding)
                if isCurrent {
                    ShortsProgress(clock: model.player.clock, player: model.player)
                }
            }
            .padding(.bottom, Layout.screenPadding)
        }
        .clipped()
    }

    private func info(_ video: YouTubeVideo, isCurrent: Bool) -> some View {
        let details = isCurrent ? model.details : nil
        return VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            HStack(spacing: Layout.chipSpacing) {
                Button {
                    guard let id = details?.channelId ?? video.channelId else { return }
                    router.shortsRoute = nil
                    Task {
                        try? await Task.sleep(for: Self.coverCloseDelay)
                        router.openChannel(id)
                    }
                } label: {
                    HStack(spacing: Layout.chipSpacing) {
                        Avatar(url: details?.channelAvatar ?? video.channelAvatarURL, size: 32)
                        Text(details?.channelTitle ?? video.channelTitle ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if let details, let id = details.channelId {
                    SubscribeButton(channelId: id, isSubscribed: details.isSubscribed) { model.setSubscribed($0) }
                }
            }
            Button {
                showsDescription = true
            } label: {
                Text(video.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isCurrent, let failure = model.errorText {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rail(_ video: YouTubeVideo) -> some View {
        let details = model.details
        let isLiked = details?.likeStatus == "LIKE"
        let isDisliked = details?.likeStatus == "DISLIKE"
        return VStack(spacing: Layout.chipSpacing) {
            Button {
                Task { await model.setLike(isLiked ? "INDIFFERENT" : "LIKE", video: video) }
            } label: {
                RailLabel(icon: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup", text: (isLiked ? details?.likeCountLiked : details?.likeCount) ?? "Like")
            }
            Button {
                Task { await model.setLike(isDisliked ? "INDIFFERENT" : "DISLIKE", video: video) }
            } label: {
                RailLabel(icon: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", text: details?.dislikeCount.map { ($0 + (isDisliked ? 1 : 0)).compactText } ?? "Dislike")
            }
            Button {
                showsComments = true
            } label: {
                RailLabel(icon: "bubble.left", text: details?.commentCount ?? "Comments")
            }
            if let url = URL(string: "https://www.youtube.com/shorts/\(video.videoId)") {
                ShareLink(item: url) {
                    RailLabel(icon: "square.and.arrow.up", text: "Share")
                }
            }
            ShortsMoreMenu(model: model, player: model.player, video: video, showsDescription: $showsDescription)
        }
        .buttonStyle(PlayerPressStyle())
    }
}

private struct RailLabel: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(.rect)
    }
}

private struct ShortsMoreMenu: View {
    @ObservedObject var model: ShortsModel
    @ObservedObject var player: MpvPlayer
    let video: YouTubeVideo
    @Binding var showsDescription: Bool
    @EnvironmentObject private var router: Router

    var body: some View {
        Menu {
            Button("Description", systemImage: "text.alignleft") { showsDescription = true }
            Button("Save to Watch Later", systemImage: "clock") {
                router.run { try await PlaylistActions.add(video.videoId, to: YouTubeFeeds.watchLaterPlaylistId) }
            }
            Picker("Speed", systemImage: "gauge.with.dots.needle.67percent", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                ForEach(Router.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : speed.speedText).tag(speed)
                }
            }
            .pickerStyle(.menu)
            if !model.captions.isEmpty {
                Menu("Captions", systemImage: "captions.bubble") {
                    Button("Off") { model.selectCaption(nil) }
                    ForEach(model.captions, id: \.languageCode) { track in
                        Button(track.name ?? track.languageCode ?? "Unknown") { model.selectCaption(track) }
                    }
                }
            }
        } label: {
            RailLabel(icon: "ellipsis", text: "More")
        }
    }
}

/// Its own view, so only the bar redraws as the time ticks.
private struct ShortsProgress: View {
    @ObservedObject var clock: PlayerClock
    @ObservedObject var player: MpvPlayer
    @State private var position = 0.0
    @State private var isEditing = false

    var body: some View {
        let total = max(player.duration, 1)
        ProgressBar(
            progress: Binding(get: { isEditing ? position : clock.time / total }, set: { position = $0 }),
            onEditingChanged: { editing in
                if editing {
                    position = clock.time / total
                } else {
                    player.seek(to: position * total)
                }
                isEditing = editing
            }
        )
    }
}
