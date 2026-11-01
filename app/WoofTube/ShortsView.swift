import SwiftUI
import SwiftyTube

/// Plays one Short at a time on its own 9:16 player and keeps the feed going with the search filter,
/// because YouTube answers FEshorts with an error when signed out. It outlives the Shorts page,
/// so the Short carries on in the floating card.
@MainActor
final class ShortsModel: ObservableObject {
    /// The opening request of YouTube's own Shorts sequence.
    private static let firstSequence = "CA8%3D"
    /// Fetches more while this many Shorts are still ahead, so the swipe never reaches the end.
    private static let shortsAhead = 3
    private static let pagesToSkip = 3

    @Published private(set) var shorts: [YouTubeVideo]
    @Published var currentId: String?
    @Published private(set) var details: WatchDetails?
    /// True until the details and the top comment have come back.
    @Published private(set) var isLoadingDetails = true
    @Published private(set) var errorText: String?
    /// The Short attached to the player. Other pages show their thumbnail.
    @Published private(set) var playingId: String?
    @Published private(set) var captions: [YouTubeCaptionTrack] = []
    @Published private(set) var selectedCaption: String?
    @Published private(set) var captionCues: [CaptionCue] = []
    let player: MpvPlayer
    private var nextToken: String?
    private var isLoadingMore = false
    private var loadTask: Task<Void, Never>?

    var currentVideo: YouTubeVideo? { shorts.first { $0.videoId == currentId } }

    init(shorts: [YouTubeVideo], startId: String, player: MpvPlayer) {
        // The scroll view tells pages apart by their ID, so each Short can only appear once.
        var seen = Set<String>()
        self.shorts = shorts.filter { seen.insert($0.videoId).inserted }
        self.currentId = startId
        self.player = player
    }

    /// Does nothing when the page reopens on the Short that's already playing.
    func playCurrent() {
        guard let video = currentVideo, video.videoId != playingId || errorText != nil else { return }
        loadTask?.cancel()
        loadTask = Task { await play(video) }
    }

    func cancel() {
        loadTask?.cancel()
    }

    private func play(_ video: YouTubeVideo) async {
        SeenVideos.mark(video.videoId)
        if player.errorText != nil || errorText != nil { await StreamLoader.forget(videoId: video.videoId) }
        player.prepareForNewVideo()
        playingId = video.videoId
        details = nil
        isLoadingDetails = true
        errorText = nil
        captions = []
        selectedCaption = nil
        captionCues = []
        // At the same time as the stream, so the comment doesn't wait for the video.
        async let detailsLoaded: Void = loadDetails(of: video)
        do {
            let stream = try await StreamLoader.load(videoId: video.videoId, maxHeight: 1080)
            guard !Task.isCancelled else { return }
            captions = stream.captions
            // Shorts from the sequence arrive as bare IDs.
            if video.title.isEmpty, let index = shorts.firstIndex(where: { $0.videoId == video.videoId }) {
                shorts[index].title = stream.title ?? ""
                shorts[index].channelTitle = stream.channelTitle
                shorts[index].channelId = stream.channelId
            }
            player.load(url: stream.url)
            // So the next swipe finds its address ready.
            if let index = shorts.firstIndex(where: { $0.videoId == video.videoId }), shorts.indices.contains(index + 1) {
                let next = shorts[index + 1].videoId
                Task { _ = try? await StreamLoader.load(videoId: next, maxHeight: 1080) }
            }
            if captions.isEmpty {
                let found = await StreamLoader.captions(videoId: video.videoId)
                guard !Task.isCancelled else { return }
                captions = found
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorText = error.localizedDescription
        }
        await detailsLoaded
        guard !Task.isCancelled else { return }
        await loadMoreIfNeeded(after: video)
    }

    private func loadDetails(of video: YouTubeVideo) async {
        let json = try? await InnerTubeClient.wooftube.next(videoId: video.videoId)
        guard !Task.isCancelled else { return }
        details = json.map { WatchDetails(json: $0, videoId: video.videoId) }
        async let dislikes = DislikeCounts.fetch(videoId: video.videoId)
        async let comment = CommentsPage.topComment(token: details?.commentsToken)
        let (dislikeCount, topComment) = await (dislikes, comment)
        guard !Task.isCancelled else { return }
        details?.dislikeCount = dislikeCount
        details?.topComment = topComment
        isLoadingDetails = false
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
        guard shorts.suffix(Self.shortsAhead).contains(where: { $0.videoId == video.videoId }), !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        for _ in 0...Self.pagesToSkip {
            guard let json = try? await YouTubeAPI.post("reel/reel_watch_sequence", body: ["sequenceParams": nextToken ?? Self.firstSequence]) else { return }
            nextToken = JSON.string("token", in: json["continuationEndpoint"])
            let entries = json["entries"] as? [[String: Any]] ?? []
            var known = Set(shorts.map(\.videoId))
            let added = entries
                .compactMap { JSON.string("videoId", in: $0["command"]) }
                .filter { !SeenVideos.contains($0) && known.insert($0).inserted }
                .map { YouTubeVideo(videoId: $0, title: "", thumbnailURL: "https://i.ytimg.com/vi/\($0)/frame0.jpg", isShort: true) }
            shorts += added
            if !added.isEmpty || nextToken == nil { return }
        }
    }
}

/// Swipe sideways for the next Short. Hold to stop the video, and move while holding to scrub.
/// Swipe down to send it to the floating card.
struct ShortsView: View {
    @State private var likeTaps = 0
    @State private var dislikeTaps = 0
    @State private var subscribeTaps = 0
    @State private var shareTaps = 0
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The fingers' scrub: where it started, and whether to carry on playing after.
    private struct Scrub {
        let start: Double
        let wasPaused: Bool
    }

    @ObservedObject var model: ShortsModel
    @Environment(Router.self) private var router
    @State private var showsComments = false
    @State private var showsDescription = false
    @State private var scrub: Scrub?
    @State private var lastSeek = 0.0
    @State private var pullDistance: CGFloat = 0

    private static let commentAreaHeight: CGFloat = 82
    /// Seconds the scrub must move before the video seeks again.
    private static let seekStep = 0.25

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
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
        .scrollPosition(id: $model.currentId)
        .scrollDisabled(scrub != nil)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .top) {
            if scrub != nil {
                ScrubPill(clock: model.player.clock, player: model.player)
                    .padding(.top, Layout.controlHeight)
            }
        }
        .background(.black)
        .offset(y: pullDistance)
        .gesture(PlayerDismissGesture.closing(isEnabled: scrub == nil, distance: $pullDistance) { router.minimizeShorts() })
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: scrub != nil)
        .onReceive(model.player.$isPaused.removeDuplicates()) { paused in
            UIApplication.shared.isIdleTimerDisabled = !paused
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
        .onAppear { model.playCurrent() }
        .onChange(of: model.currentId) { model.playCurrent() }
    }

    private var topBar: some View {
        Button {
            router.minimizeShorts()
        } label: {
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send to Mini Player")
    }

    private func page(_ video: YouTubeVideo) -> some View {
        let isCurrent = video.videoId == model.currentId
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if video.videoId == model.playingId {
                    MpvVideoView(player: model.player, isActive: router.isShortsPageOnScreen, fills: true)
                    VideoPoster(player: model.player, video: video)
                    MovingVideoCover(poster: video.thumbnailURL, fills: true)
                } else {
                    CoverImage(url: video.thumbnailURL)
                }
                PlayerTouchSurface(
                    onTap: { model.player.togglePause() },
                    onHold: hold,
                    onHoldMoved: moveHold
                )
                if isCurrent {
                    ShortStartSpinner(player: model.player, hasFailed: model.errorText != nil)
                        .frame(maxHeight: .infinity)
                }
                if isCurrent {
                    CaptionOverlay(clock: model.player.clock, cues: model.captionCues, isFullscreen: false)
                        .padding(.bottom, 120)
                }
                VStack(spacing: Layout.chipSpacing) {
                    HStack(alignment: .bottom, spacing: Layout.rowSpacing) {
                        info(video, isCurrent: isCurrent)
                        if isCurrent {
                            rail(video)
                        }
                    }
                    .padding(.horizontal, Layout.screenPadding)
                    .opacity(scrub == nil ? 1 : 0)
                    if isCurrent {
                        ShortsProgress(clock: model.player.clock, player: model.player, isEmphasized: scrub != nil)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()
            .overlay {
                BottomCornersCover(radius: Layout.sheetRadius)
                    .fill(.black, style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            }

            commentArea(isCurrent: isCurrent)
        }
    }

    /// Takes the space that used to stay black under the video.
    private func commentArea(isCurrent: Bool) -> some View {
        Group {
            if !isCurrent || model.isLoadingDetails {
                CommentsCard(details: isCurrent ? model.details : nil, commentLines: 1, isLoading: true) { showsComments = true }
            } else if let details = model.details, details.commentsToken != nil {
                CommentsCard(details: details, commentLines: 1) { showsComments = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, Layout.chipSpacing)
        .padding(.top, Layout.chipSpacing)
        .frame(height: Self.commentAreaHeight, alignment: .top)
    }

    private func hold(_ isHeld: Bool) {
        if isHeld {
            scrub = Scrub(start: model.player.time, wasPaused: model.player.isPaused)
            lastSeek = model.player.time
            model.player.setPaused(true)
        } else if let finished = scrub {
            scrub = nil
            model.player.setPaused(finished.wasPaused)
        }
    }

    /// The video's whole length fits in the screen's width.
    private func moveHold(_ fraction: CGFloat) {
        guard let scrub else { return }
        let target = min(max(scrub.start + Double(fraction) * model.player.duration, 0), model.player.duration)
        guard abs(target - lastSeek) >= Self.seekStep else { return }
        lastSeek = target
        model.player.seek(to: target)
    }

    private func info(_ video: YouTubeVideo, isCurrent: Bool) -> some View {
        let details = isCurrent ? model.details : nil
        return VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            HStack(spacing: Layout.chipSpacing) {
                Button {
                    guard let id = details?.channelId ?? video.channelId else { return }
                    router.openChannelPage(id)
                } label: {
                    HStack(spacing: Layout.chipSpacing) {
                        Avatar(url: details?.channelAvatar ?? video.channelAvatarURL, size: Layout.avatarSmall)
                        Text(details?.channelTitle ?? video.channelTitle ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
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
        return VStack(spacing: Layout.screenPadding) {
            Button {
                likeTaps += 1
                Task { await model.setLike(isLiked ? "INDIFFERENT" : "LIKE", video: video) }
            } label: {
                RailLabel(icon: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup", text: (isLiked ? details?.likeCountLiked : details?.likeCount) ?? "Like", isActive: isLiked, motion: isLiked ? .deflate : .like(emojis: VideoFlavor.emojis(for: video.title)), trigger: likeTaps)
            }
            .accessibilityLabel("Like")
            .accessibilityAddTraits(isLiked ? .isSelected : [])
            Button {
                dislikeTaps += 1
                Task { await model.setLike(isDisliked ? "INDIFFERENT" : "DISLIKE", video: video) }
            } label: {
                RailLabel(icon: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", text: details?.dislikeCount.map { ($0 + (isDisliked ? 1 : 0)).compactText } ?? "Dislike", isActive: isDisliked, motion: isDisliked ? .rise : .dislike, trigger: dislikeTaps)
            }
            .accessibilityLabel("Dislike")
            .accessibilityAddTraits(isDisliked ? .isSelected : [])
            if let url = URL(string: "https://www.youtube.com/shorts/\(video.videoId)") {
                ShareLink(item: url) {
                    RailLabel(icon: "square.and.arrow.up", text: "Share")
                        .symbolEffect(.bounce.up.byLayer, value: shareTaps)
                }
                .simultaneousGesture(TapGesture().onEnded { shareTaps += 1 })
                .accessibilityLabel("Share")
            }
            ShortsMoreMenu(model: model, player: model.player, video: video, showsDescription: $showsDescription)
            if let details, let id = details.channelId {
                Button {
                    subscribeTaps += 1
                    SubscribeButton.set(!details.isSubscribed, channelId: id) { model.setSubscribed($0) }
                } label: {
                    RailLabel(icon: details.isSubscribed ? "person.fill.checkmark" : "person.badge.plus", glassTint: details.isSubscribed ? nil : settings.accentColor, motion: details.isSubscribed ? .unsubscribed : .subscribed, trigger: subscribeTaps)
                        .contentTransition(.symbolEffect(.replace))
                }
                .animation(reduceMotion ? nil : .snappy, value: details.isSubscribed)
                .accessibilityLabel(details.isSubscribed ? "Unsubscribe" : "Subscribe")
                .sensoryFeedback(.selection, trigger: details.isSubscribed)
            }
        }
        .buttonStyle(PlayerPressStyle())
    }
}

/// Black in the two bottom corners, drawn over the video. Rounding only some corners of a
/// view takes a mask, and a mask turns this video layer black during the zoom back to the card.
private struct BottomCornersCover: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous).path(in: rect))
        return path
    }
}

/// Shows until the Short has its first frame.
private struct ShortStartSpinner: View {
    @ObservedObject var player: MpvPlayer
    let hasFailed: Bool

    var body: some View {
        if !player.isVideoReady, !hasFailed, player.errorText == nil {
            ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
        } else if let failure = player.errorText, !hasFailed {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(Layout.screenPadding)
                .allowsHitTesting(false)
        } else if player.isPaused, !hasFailed {
            // Without this a paused Short looks like one that froze.
            Image(systemName: "play.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct RailLabel: View {
    let icon: String
    var text: String?
    var isActive = false
    var glassTint: Color?
    var motion: GlyphScript?
    var trigger: Int = 0

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                .glyphMotion(motion, trigger: trigger)
                .frame(width: 44, height: 44)
                .glassEffect((glassTint.map { Glass.regular.tint($0) } ?? .regular).interactive(), in: .circle)
            if let text {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
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
    @Environment(Router.self) private var router
    @State private var taps = 0

    var body: some View {
        Menu {
            Button("Description", systemImage: "text.alignleft") { showsDescription = true }
            Button("Save to Watch Later", systemImage: "clock") {
                router.run { try await PlaylistActions.add(video.videoId, to: YouTubeFeeds.watchLaterPlaylistId) }
            }
            Picker("Speed", systemImage: player.speed.gaugeSymbol, selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                ForEach(Router.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : speed.speedText).tag(speed)
                }
            }
            .pickerStyle(.menu)
            if !model.captions.isEmpty {
                Menu("Captions", systemImage: model.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill") {
                    Button("Off", systemImage: "xmark") { model.selectCaption(nil) }
                    ForEach(model.captions, id: \.languageCode) { track in
                        Button {
                            model.selectCaption(track)
                        } label: {
                            if model.selectedCaption == track.languageCode {
                                Label(track.name ?? track.languageCode ?? "Unknown", systemImage: "checkmark")
                            } else {
                                Text(track.name ?? track.languageCode ?? "Unknown")
                            }
                        }
                    }
                }
            }
        } label: {
            RailLabel(icon: "ellipsis")
                .symbolEffect(.bounce.byLayer, value: taps)
        }
        .simultaneousGesture(TapGesture().onEnded { taps += 1 })
        .accessibilityLabel("More")
    }
}

/// The time while scrubbing by holding the video.
private struct ScrubPill: View {
    @ObservedObject var clock: PlayerClock
    @ObservedObject var player: MpvPlayer

    var body: some View {
        Text("\(clock.time.clockText) / \(player.duration.clockText)")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, Layout.rowSpacing)
            .padding(.vertical, Layout.rowPadding)
            .background(.black.opacity(0.55), in: .capsule)
            .allowsHitTesting(false)
    }
}

/// Its own view, so only the bar redraws as the time ticks.
private struct ShortsProgress: View {
    @ObservedObject var clock: PlayerClock
    @ObservedObject var player: MpvPlayer
    let isEmphasized: Bool
    @State private var position = 0.0
    @State private var isEditing = false

    var body: some View {
        let total = max(player.duration, 1)
        ProgressBar(
            progress: Binding(get: { isEditing ? position : clock.time / total }, set: { position = $0 }),
            isEmphasized: isEmphasized,
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
