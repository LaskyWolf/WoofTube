import AVKit
import SwiftUI
import SwiftyTube

/// One video surface above the tabs. It moves between the video page and the floating
/// miniplayer by scaling, so the video keeps drawing without a resize or a reload.
struct PlayerOverlay: View {
    @EnvironmentObject private var router: Router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var dragOffset = CGSize.zero
    @State private var isMiniLeading = false
    @State private var isMiniTop = false
    @State private var showsMiniControls = false
    @State private var showsComments = false

    private static let miniSize = CGSize(width: 192, height: 108)
    private static let miniMargin: CGFloat = 12
    /// Keeps the miniplayer above the tab bar, which sits outside this view's safe area.
    private static let tabBarHeight: CGFloat = 64
    private static let collapseDistance: CGFloat = 120
    private static let exitFullscreenDistance: CGFloat = 60

    private var isFullscreen: Bool { router.isExpanded && verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { geometry in
            if router.current != nil {
                content(geometry)
            }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .sheet(isPresented: $showsComments) {
            if let token = router.details?.commentsToken {
                CommentsSheet(token: token)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            if router.isExpanded { Orientation.unlockIfHeldUpright() }
        }
    }

    private func content(_ geometry: GeometryProxy) -> some View {
        let insets = geometry.safeAreaInsets
        let screen = CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom
        )
        let videoSize = isFullscreen ? screen : CGSize(width: screen.width, height: screen.width * 9 / 16)
        let expanded = isFullscreen ? CGPoint.zero : CGPoint(x: 0, y: insets.top)
        let mini = CGPoint(
            x: isMiniLeading ? Self.miniMargin : screen.width - Self.miniSize.width - Self.miniMargin,
            y: isMiniTop ? insets.top + Self.miniMargin : screen.height - Self.miniSize.height - insets.bottom - Self.tabBarHeight - Self.miniMargin
        )
        // 0 is the full video page, 1 is the miniplayer.
        let progress = router.isExpanded ? min(max(dragOffset.height, 0) / (screen.height * 0.6), 1) : 1
        let origin = router.isExpanded
            ? CGPoint(x: expanded.x + (mini.x - expanded.x) * progress, y: expanded.y + (mini.y - expanded.y) * progress)
            : CGPoint(x: mini.x + dragOffset.width, y: mini.y + dragOffset.height)
        let width = videoSize.width + (Self.miniSize.width - videoSize.width) * progress
        let scale = width / videoSize.width
        let radius = progress * Layout.tileRadius / scale

        return ZStack(alignment: .topLeading) {
            page(topInset: insets.top, bottomInset: insets.bottom, videoHeight: videoSize.height, progress: progress)

            MpvVideoView(player: router.player)
                .frame(width: videoSize.width, height: videoSize.height)
                .background(.black)
                .clipShape(.rect(cornerRadius: radius))
                .background {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.4 * progress), radius: 12 / scale, y: 4 / scale)
                }
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)

            if router.isExpanded {
                PlayerControls(
                    player: router.player,
                    isFullscreen: isFullscreen,
                    onDragChanged: { value in
                        if !isFullscreen { dragOffset = value.translation }
                    },
                    onDragEnded: { value in finishPageDrag(value, screenHeight: screen.height) }
                )
                .frame(width: videoSize.width, height: videoSize.height)
                .opacity(1 - progress * 4)
                .offset(x: expanded.x, y: expanded.y)
            } else {
                MiniControls(
                    player: router.player,
                    isVisible: $showsMiniControls,
                    onDragChanged: { value in dragOffset = value.translation },
                    onDragEnded: { value in finishMiniDrag(value, origin: mini, screen: screen) }
                )
                .frame(width: Self.miniSize.width, height: Self.miniSize.height)
                .clipShape(.rect(cornerRadius: Layout.tileRadius))
                .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .animation(.snappy, value: router.isExpanded)
        .ignoresSafeArea()
    }

    private func page(topInset: CGFloat, bottomInset: CGFloat, videoHeight: CGFloat, progress: CGFloat) -> some View {
        ZStack(alignment: .top) {
            (isFullscreen ? Color.black : Color(.systemBackground))
            if !isFullscreen {
                ScrollView {
                    WatchDetailsView(showsComments: $showsComments)
                }
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
                .padding(.top, topInset + videoHeight)
            }
        }
        .opacity(router.isExpanded ? 1 - progress : 0)
        .allowsHitTesting(router.isExpanded)
    }

    private func finishPageDrag(_ value: DragGesture.Value, screenHeight: CGFloat) {
        if isFullscreen {
            if value.translation.height > Self.exitFullscreenDistance {
                Orientation.setFullscreen(false)
            }
            return
        }
        if max(value.translation.height, value.predictedEndTranslation.height) > Self.collapseDistance {
            showsMiniControls = false
            router.isExpanded = false
        }
        withAnimation(.snappy) { dragOffset = .zero }
    }

    /// Snaps to the corner the flick is heading for.
    private func finishMiniDrag(_ value: DragGesture.Value, origin: CGPoint, screen: CGSize) {
        let endX = origin.x + value.predictedEndTranslation.width + Self.miniSize.width / 2
        let endY = origin.y + value.predictedEndTranslation.height + Self.miniSize.height / 2
        withAnimation(.snappy) {
            isMiniLeading = endX < screen.width / 2
            isMiniTop = endY < screen.height / 2
            dragOffset = .zero
        }
    }
}

private struct MiniControls: View {
    @ObservedObject var player: MpvPlayer
    @Binding var isVisible: Bool
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    @EnvironmentObject private var router: Router

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .onTapGesture {
                    if isVisible {
                        router.isExpanded = true
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { isVisible = true }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged(onDragChanged)
                        .onEnded(onDragEnded)
                )

            if isVisible {
                Color.black.opacity(0.35).allowsHitTesting(false)
                VStack {
                    HStack {
                        iconButton("Expand", icon: "arrow.up.left.and.arrow.down.right") { router.isExpanded = true }
                        Spacer()
                        iconButton("Close", icon: "xmark") { router.close() }
                    }
                    Spacer()
                }
                iconButton(player.isPaused ? "Play" : "Pause", icon: player.isPaused ? "play.fill" : "pause.fill") {
                    player.togglePause()
                }
                .font(.title2)
            }

            VStack {
                Spacer()
                ProgressView(value: min(player.time, max(player.duration, 1)), total: max(player.duration, 1))
                    .progressViewStyle(.linear)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .task(id: isVisible) {
            guard isVisible else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { isVisible = false }
        }
    }

    private func iconButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

private struct PlayerControls: View {
    @ObservedObject var player: MpvPlayer
    let isFullscreen: Bool
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @State private var showsControls = true
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var hideTask: Task<Void, Never>?

    private var isLoading: Bool {
        router.loadError == nil && (router.streamSummary == nil || player.isBuffering)
    }

    var body: some View {
        ZStack {
            // The tap target sits under the buttons, so a tap on a button can't also toggle the controls.
            Color.clear
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { showsControls.toggle() }
                    scheduleHide()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .global)
                        .onChanged(onDragChanged)
                        .onEnded(onDragEnded)
                )

            if isLoading {
                ProgressView().tint(.white).controlSize(.large)
            }
            if showsControls {
                controls.transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
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
                .tint(settings.accentColor)
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
                if !router.queue.isEmpty {
                    Text("Queue").font(.headline)
                    ForEach(router.queue, id: \.videoId) { video in
                        VideoButton(video: video)
                    }
                }
                if !details.related.isEmpty {
                    Text("Up Next").font(.headline)
                    ForEach(details.related, id: \.videoId) { video in
                        VideoButton(video: video)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
        .padding(Layout.screenPadding)
    }

    @ViewBuilder
    private func channelRow(_ details: WatchDetails) -> some View {
        if let id = details.channelId {
            HStack(spacing: Layout.rowSpacing) {
                Button {
                    router.openChannel(id)
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
                    .contentShape(.rect)
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
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button("Watch Later", systemImage: "clock") {
                        router.run { try await PlaylistActions.add(id, to: YouTubeFeeds.watchLaterPlaylistId) }
                    }
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
                router.actionMessage = error.localizedDescription
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
                VideoButton(video: video)
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
