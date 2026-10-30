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
            // The same PlayerSurface stays in place in both layouts, so the video never reloads.
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    PlayerSurface(player: router.player, isFullscreen: isFullscreen)
                        .frame(width: geometry.size.width, height: isFullscreen ? geometry.size.height : geometry.size.width * 9 / 16)
                    if !isFullscreen {
                        ScrollView {
                            WatchDetailsView(showsComments: $showsComments)
                        }
                    }
                }
            }
            .background(alignment: .top) {
                Color.black.ignoresSafeArea()
                    .frame(maxHeight: isFullscreen ? .infinity : 0)
            }
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(isFullscreen)
            .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
            .sheet(isPresented: $showsComments) {
                if let token = router.details?.commentsToken {
                    CommentsSheet(token: token)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.playerNamespace, nil)
        .interactiveDismissDisabled(isFullscreen)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            Orientation.unlockIfHeldUpright()
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

    private var isLoading: Bool {
        router.loadError == nil && (router.streamSummary == nil || player.isBuffering)
    }

    var body: some View {
        ZStack {
            MpvVideoView(player: player)
                .background(.black)
                .ignoresSafeArea(edges: isFullscreen ? .all : .top)

            // The tap target sits under the buttons, so a tap on a button can't also toggle the controls.
            Color.clear
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { showsControls.toggle() }
                    scheduleHide()
                }

            if isLoading {
                ProgressView().tint(.white).controlSize(.large)
            }
            if showsControls {
                controls.transition(.opacity)
            }
        }
        .onAppear(perform: scheduleHide)
        .onChange(of: player.isPaused) { scheduleHide() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: Layout.chipSpacing) {
                glassButton("Close", icon: "chevron.down") {
                    router.isExpanded = false
                }
                Spacer()
                RoutePicker()
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                optionsMenu
            }
            Spacer(minLength: 0)
            if !isLoading {
                HStack(spacing: 24) {
                    glassButton("Back 10 Seconds", icon: "gobackward.10") { player.skip(by: -10) }
                    glassButton(player.isPaused ? "Play" : "Pause", icon: player.isPaused ? "play.fill" : "pause.fill") {
                        player.togglePause()
                    }
                    .controlSize(.extraLarge)
                    glassButton("Forward 10 Seconds", icon: "goforward.10") { player.skip(by: 10) }
                }
            }
            Spacer(minLength: 0)
            scrubber
        }
        .padding(Layout.chipSpacing)
        .tint(.white)
        .foregroundStyle(.white)
    }

    private var scrubber: some View {
        HStack(spacing: Layout.chipSpacing) {
            HStack(spacing: Layout.chipSpacing) {
                Text((isScrubbing ? scrubPosition : player.time).clockText)
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : player.time },
                        set: { scrubPosition = $0 }
                    ),
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
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, Layout.screenPadding)
            .frame(minHeight: 44)
            .glassEffect(.regular, in: .capsule)

            glassButton(isFullscreen ? "Exit Full Screen" : "Full Screen", icon: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                Orientation.setFullscreen(!isFullscreen)
            }
        }
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
            if let summary = router.streamSummary {
                Section(summary) {}
            }
        } label: {
            Label("Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
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
        .controlSize(.large)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !player.isPaused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsControls = false }
        }
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
        VStack(alignment: .leading, spacing: Layout.sectionSpacing * 1.5) {
            if let video = router.current {
                Text(video.title)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = router.loadError ?? router.player.errorText {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let details = router.details {
                channelRow(details)
                actions(details)
                descriptionCard(details)
                if details.commentsToken != nil {
                    commentsCard
                }
                if !details.related.isEmpty {
                    Text("Up Next").font(.headline)
                    ForEach(details.related, id: \.videoId) { video in
                        Button {
                            router.play(video)
                        } label: {
                            VideoRow(video: video)
                        }
                        .buttonStyle(RowPressStyle())
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
        .padding(Layout.screenPadding)
        .alert("That Didn't Work", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func channelRow(_ details: WatchDetails) -> some View {
        if let id = details.channelId {
            HStack(spacing: Layout.rowSpacing) {
                NavigationLink {
                    ChannelView(channelId: id)
                } label: {
                    HStack(spacing: Layout.rowSpacing) {
                        Avatar(url: details.channelAvatar, size: Layout.thumbSmall)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(details.channelTitle ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(details.subscribers ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
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
            HStack(spacing: Layout.chipSpacing) {
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
            .controlSize(.large)
            .sensoryFeedback(.impact(weight: .light), trigger: details.likeStatus)
        }
        .scrollClipDisabled()
    }

    private func descriptionCard(_ details: WatchDetails) -> some View {
        Button {
            withAnimation(.snappy) { showsDescription.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                if let metadata = details.metadata, !metadata.isEmpty {
                    Text(metadata).font(.subheadline.weight(.semibold))
                }
                if let description = details.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsDescription ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.rowSpacing)
            .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Layout.tileRadius))
        }
        .buttonStyle(.plain)
    }

    private var commentsCard: some View {
        Button {
            showsComments = true
        } label: {
            HStack {
                Text("Comments").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(Layout.rowSpacing)
            .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Layout.tileRadius))
        }
        .buttonStyle(.plain)
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
        .sensoryFeedback(.selection, trigger: isSubscribed)
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
                HStack(spacing: Layout.rowSpacing) {
                    Avatar(url: channel.thumbnailURL, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.title).font(.headline)
                        if let subscribers = channel.subscriberCountText {
                            Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
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
                .buttonStyle(RowPressStyle())
                .listRowInsets(Layout.rowInsets)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading, page == nil { LoadingRows() }
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
