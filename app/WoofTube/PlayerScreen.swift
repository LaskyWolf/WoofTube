import AVKit
import SwiftUI
import SwiftyTube

struct WatchView: View {
    @EnvironmentObject private var router: Router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsComments = false

    private var isFullscreen: Bool { verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PlayerSurface(player: router.player, isFullscreen: isFullscreen)
                if !isFullscreen {
                    ScrollView {
                        WatchDetailsView(showsComments: $showsComments)
                    }
                }
            }
            .background(isFullscreen ? Color.black : Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(isFullscreen)
            .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
            .sheet(isPresented: $showsComments) {
                if let token = router.details?.commentsToken {
                    CommentsSheet(token: token)
                }
            }
        }
    }
}

private struct PlayerSurface: View {
    @ObservedObject var player: MpvPlayer
    let isFullscreen: Bool

    @EnvironmentObject private var router: Router
    @State private var showsControls = true
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        MpvVideoView(player: player)
            .aspectRatio(isFullscreen ? nil : 16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: isFullscreen ? .infinity : nil)
            .background(.black)
            .ignoresSafeArea(isFullscreen ? .all : [])
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                scheduleHide()
            }
            .overlay {
                if showsControls { controls.transition(.opacity) }
                if router.streamSummary == nil, router.loadError == nil {
                    ProgressView().tint(.white)
                }
            }
            .onAppear(perform: scheduleHide)
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 8) {
                glassButton("Close", icon: "chevron.down") { router.isExpanded = false }
                Spacer()
                RoutePicker().frame(width: 44, height: 44).glassEffect(.regular, in: .circle)
                optionsMenu
            }
            Spacer()
            glassButton(player.isPaused ? "Play" : "Pause", icon: player.isPaused ? "play.fill" : "pause.fill") {
                player.togglePause()
            }
            .controlSize(.extraLarge)
            Spacer()
            HStack(spacing: 8) {
                Text(player.time.clockText)
                Slider(
                    value: isScrubbing ? $scrubPosition : .constant(player.time),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubPosition = player.time
                            hideTask?.cancel()
                        } else {
                            player.seek(to: scrubPosition)
                            scheduleHide()
                        }
                        isScrubbing = editing
                    }
                )
                Text(player.duration.clockText)
                glassButton(isFullscreen ? "Exit Full Screen" : "Full Screen", icon: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    rotate()
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(8)
        .tint(.white)
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(get: { router.maxHeight }, set: { router.changeQuality(to: $0) })) {
                ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
            }
            .pickerStyle(.menu)
            Menu("Speed") {
                ForEach([0.5, 1, 1.25, 1.5, 2], id: \.self) { speed in
                    Button("\(speed.formatted())x") { player.setSpeed(speed) }
                }
            }
            if !router.captions.isEmpty {
                Menu("Captions") {
                    Button("Off") { router.selectCaption(nil) }
                    ForEach(router.captions, id: \.languageCode) { track in
                        Button(track.name ?? track.languageCode ?? "Unknown") { router.selectCaption(track) }
                    }
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private func glassButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon) {
            action()
            scheduleHide()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !player.isPaused else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showsControls = false }
        }
    }

    private func rotate() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: isFullscreen ? .portrait : .landscapeRight))
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct WatchDetailsView: View {
    @Binding var showsComments: Bool
    @EnvironmentObject private var router: Router
    @State private var showsDescription = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video = router.current {
                Text(video.title).font(.title3.bold())
            }
            if let failure = router.loadError ?? router.player.errorText {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let details = router.details {
                if let metadata = details.metadata, !metadata.isEmpty {
                    Text(metadata).font(.subheadline).foregroundStyle(.secondary)
                }
                channelRow(details)
                actions(details)
                if let description = details.description {
                    DisclosureGroup("Description", isExpanded: $showsDescription) {
                        Text(description).font(.subheadline).textSelection(.enabled)
                    }
                }
                if details.commentsToken != nil {
                    Button("Comments", systemImage: "bubble.left") { showsComments = true }
                        .buttonStyle(.glass)
                }
                if let summary = router.streamSummary {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(details.related, id: \.videoId) { video in
                    Button {
                        router.play(video)
                    } label: {
                        VideoRow(video: video)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .alert("That Didn't Work", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func channelRow(_ details: WatchDetails) -> some View {
        HStack(spacing: 12) {
            if let id = details.channelId {
                NavigationLink {
                    ChannelView(channelId: id)
                } label: {
                    Avatar(url: details.channelAvatar, size: 40)
                    VStack(alignment: .leading) {
                        Text(details.channelTitle ?? "").font(.subheadline.weight(.semibold))
                        Text(details.subscribers ?? "").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                SubscribeButton(channelId: id, isSubscribed: details.isSubscribed) { value in
                    router.setDetails { $0.isSubscribed = value }
                }
            }
        }
    }

    private func actions(_ details: WatchDetails) -> some View {
        let isLiked = details.likeStatus == "LIKE"
        let isDisliked = details.likeStatus == "DISLIKE"
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button((isLiked ? details.likeCountLiked : details.likeCount) ?? "Like", systemImage: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                    setLike(isLiked ? "INDIFFERENT" : "LIKE")
                }
                Button("Dislike", systemImage: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                    setLike(isDisliked ? "INDIFFERENT" : "DISLIKE")
                }
                .labelStyle(.iconOnly)
                if let id = router.current?.videoId, let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                    ShareLink(item: url)
                    Button("Watch Later", systemImage: "clock") { saveToWatchLater(id) }
                }
            }
            .buttonStyle(.glass)
        }
    }

    private func setLike(_ status: String) {
        guard let id = router.current?.videoId, let previous = router.details?.likeStatus else { return }
        router.setDetails { $0.likeStatus = status }
        Task {
            do {
                let tube = InnerTubeClient.wooftube
                switch status {
                case "LIKE": _ = try await tube.like(videoId: id)
                case "DISLIKE": _ = try await tube.dislike(videoId: id)
                default: _ = try await tube.unlike(videoId: id)
                }
            } catch {
                router.setDetails { $0.likeStatus = previous }
                actionError = error.localizedDescription
            }
        }
    }

    private func saveToWatchLater(_ id: String) {
        Task {
            do {
                _ = try await InnerTubeClient.wooftube.editPlaylist(
                    playlistId: YouTubeFeeds.watchLaterPlaylistId,
                    actions: [["action": "ACTION_ADD_VIDEO", "addedVideoId": id]]
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

struct SubscribeButton: View {
    let channelId: String
    let isSubscribed: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button(isSubscribed ? "Subscribed" : "Subscribe") {
            let target = !isSubscribed
            onChange(target)
            Task {
                let tube = InnerTubeClient.wooftube
                do {
                    _ = target ? try await tube.subscribe(channelId: channelId) : try await tube.unsubscribe(channelId: channelId)
                } catch {
                    onChange(!target)
                }
            }
        }
        .modifier(SubscribeStyle(isSubscribed: isSubscribed))
    }
}

private struct SubscribeStyle: ViewModifier {
    let isSubscribed: Bool

    func body(content: Content) -> some View {
        if isSubscribed {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.glassProminent)
        }
    }
}

struct ChannelView: View {
    let channelId: String

    @EnvironmentObject private var router: Router
    @State private var page: YouTubeChannelPage?
    @State private var videos: [YouTubeVideo] = []
    @State private var isSubscribed = false
    @State private var isLoading = true

    var body: some View {
        List {
            if let channel = page?.channel {
                HStack(spacing: 12) {
                    Avatar(url: channel.thumbnailURL, size: 56)
                    VStack(alignment: .leading) {
                        Text(channel.title).font(.headline)
                        if let subscribers = channel.subscriberCountText {
                            Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    SubscribeButton(channelId: channelId, isSubscribed: isSubscribed) { isSubscribed = $0 }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(videos, id: \.videoId) { video in
                Button {
                    router.play(video)
                } label: {
                    VideoRow(video: video)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading, page == nil { ProgressView() }
        }
        .navigationTitle(page?.channel?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        let tube = InnerTubeClient.wooftube
        guard let json = try? await tube.browse(browseId: channelId) else { return }
        let parsed = YouTubeChannelParser.channelPage(in: json)
        page = parsed
        videos = parsed.videos.filter { !$0.isShort }
        isSubscribed = JSON.first("subscribed", in: json) as? Bool ?? false
        // Reuses the tab's own params, because YouTube rotates them.
        if let tab = parsed.tabs.first(where: { $0.browseId != nil && $0.params != nil && $0.title.localizedCaseInsensitiveContains("video") }),
           let tabJSON = try? await tube.browse(browseId: channelId, params: tab.params) {
            videos = YouTubeFeedParser.videos(in: tabJSON).filter { !$0.isShort }
        }
    }
}
