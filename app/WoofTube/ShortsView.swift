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
        do {
            let stream = try await StreamLoader.load(videoId: video.videoId, maxHeight: 1080)
            guard !Task.isCancelled else { return }
            player.load(url: stream.url)
        } catch {
            errorText = error.localizedDescription
        }
        let json = try? await InnerTubeClient.wooftube.next(videoId: video.videoId)
        details = json.map { WatchDetails(json: $0, videoId: video.videoId) }
        await loadMoreIfNeeded(after: video)
    }

    func toggleLike(_ video: YouTubeVideo) async {
        guard let status = details?.likeStatus else { return }
        let isLiked = status == "LIKE"
        details?.likeStatus = isLiked ? "INDIFFERENT" : "LIKE"
        let tube = InnerTubeClient.wooftube
        do {
            _ = isLiked ? try await tube.unlike(videoId: video.videoId) : try await tube.like(videoId: video.videoId)
        } catch {
            details?.likeStatus = status
            errorText = error.localizedDescription
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
    @State private var isBoosting = false

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
        ZStack(alignment: .bottom) {
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
            HStack(alignment: .bottom, spacing: Layout.rowSpacing) {
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    if let channel = video.channelTitle {
                        Text(channel).font(.subheadline.weight(.semibold))
                    }
                    Text(video.title).font(.subheadline).lineLimit(3)
                    if video.videoId == currentId, let failure = model.errorText {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

                VStack(spacing: Layout.chipSpacing) {
                    let isLiked = video.videoId == currentId && model.details?.likeStatus == "LIKE"
                    Button("Like", systemImage: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        Task { await model.toggleLike(video) }
                    }
                    Button("Comments", systemImage: "bubble.left") { showsComments = true }
                    if let url = URL(string: "https://www.youtube.com/shorts/\(video.videoId)") {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(PlayerPressStyle())
                .labelStyle(PlayerGlyphLabelStyle(size: 24))
            }
            .padding(.horizontal, Layout.screenPadding)
            .padding(.bottom, 48)
        }
        .clipped()
    }
}
