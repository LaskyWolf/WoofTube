import SwiftUI
import SwiftyTube

/// YouTube answers FEshorts with an error when signed out, and it can't be tested signed in
/// from a computer, so this falls back to the search filter for Shorts.
@MainActor
final class ShortsModel: ObservableObject {
    private static let shortsSearchFilter = "EgIYAQ%3D%3D"

    @Published private(set) var shorts: [YouTubeVideo] = []
    @Published private(set) var isLoading = true
    @Published private(set) var details: WatchDetails?
    @Published private(set) var errorText: String?
    let player = MpvPlayer(surfaceAspect: 9 / 16)
    private var nextToken: String?

    init() {
        player.setLooping(true)
    }

    func load() async {
        defer { isLoading = false }
        let tube = InnerTubeClient.wooftube
        if let json = try? await tube.browse(browseId: YouTubeFeeds.shorts) {
            shorts = YouTubeFeedParser.videos(in: json).filter(\.isShort)
        }
        if shorts.isEmpty, let json = try? await tube.search(query: "shorts", params: Self.shortsSearchFilter) {
            shorts = YouTubeFeedParser.videos(in: json).filter(\.isShort)
            nextToken = YouTubeFeedParser.continuation(in: json)
        }
    }

    func play(_ video: YouTubeVideo) async {
        details = nil
        errorText = nil
        do {
            let stream = try await StreamLoader.load(videoId: video.videoId, maxHeight: 1080)
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
        guard video.videoId == shorts.last?.videoId, let token = nextToken else { return }
        nextToken = nil
        guard let json = try? await InnerTubeClient.wooftube.search(query: "shorts", continuation: token) else { return }
        let known = Set(shorts.map(\.videoId))
        shorts += YouTubeFeedParser.videos(in: json).filter { $0.isShort && !known.contains($0.videoId) }
        nextToken = YouTubeFeedParser.continuation(in: json)
    }
}

struct ShortsView: View {
    let isActive: Bool

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ShortsModel()
    @State private var currentId: String?
    @State private var showsComments = false

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
        .ignoresSafeArea(edges: .top)
        .background(.black)
        .overlay {
            if model.shorts.isEmpty {
                if model.isLoading {
                    ProgressView().tint(.white)
                } else {
                    ContentUnavailableView("No Shorts", systemImage: "play.square.stack")
                }
            }
        }
        .toolbarColorScheme(.dark, for: .tabBar)
        .onChange(of: scenePhase) { model.player.setVideoEnabled(scenePhase != .background) }
        .sheet(isPresented: $showsComments) {
            if let token = model.details?.commentsToken {
                CommentsSheet(token: token)
            }
        }
        .task {
            await model.load()
            currentId = model.shorts.first?.videoId
        }
        .task(id: PlayKey(id: currentId, isActive: isActive)) {
            guard isActive, let video = model.shorts.first(where: { $0.videoId == currentId }) else {
                model.player.stop()
                return
            }
            await model.play(video)
        }
    }

    private struct PlayKey: Hashable {
        let id: String?
        let isActive: Bool
    }

    private func page(_ video: YouTubeVideo) -> some View {
        ZStack(alignment: .bottom) {
            if video.videoId == currentId, isActive {
                MpvVideoView(player: model.player)
            } else {
                AsyncImage(url: video.thumbnailURL.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.black
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
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

                VStack(spacing: 12) {
                    let isLiked = video.videoId == currentId && model.details?.likeStatus == "LIKE"
                    sideButton("Like", icon: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        Task { await model.toggleLike(video) }
                    }
                    sideButton("Comments", icon: "bubble.left") { showsComments = true }
                    if let url = URL(string: "https://www.youtube.com/shorts/\(video.videoId)") {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 48)
        }
        .contentShape(.rect)
        .onTapGesture { model.player.togglePause() }
    }

    private func sideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}
