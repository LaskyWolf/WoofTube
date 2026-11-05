import AVKit
import SwiftUI
import SwiftyTube

/// The floating card above the tabs, for a video or a Short. It can be flicked off the side, leaving a small handle.
struct PlayerOverlay: View {
    static let zoomSource = "player"

    let zoom: Namespace.ID
    @Environment(Router.self) private var router
    @State private var dragOffset = CGSize.zero
    @State private var isMiniLeading = false
    @State private var isMiniTop = false
    @State private var isDocked = false

    /// The title, pause and close strip under the mini video.
    private static let miniStripHeight: CGFloat = 44
    /// The glass shows this far around the video.
    private static let miniInset = Layout.rowPadding
    /// Follows the video's corners, so the glass stays the same width around them.
    private static let cardRadius = Layout.tileRadius + miniInset
    private static let miniMargin: CGFloat = 12
    /// Keeps the miniplayer just above the tab bar, which sits outside this view's safe area.
    private static let tabBarClearance: CGFloat = 58
    private static let handleSize = CGSize(width: 44, height: 96)
    /// The rest of the handle stays off screen, so it reads as attached to the edge.
    private static let handleVisibleWidth: CGFloat = 24

    /// The Short in the card. The card stays under its page, because the page zooms out of it and back in.
    private var short: ShortsModel? { router.shortsModel }
    private var miniPlayerObject: MpvPlayer { short?.player ?? router.player }
    private var miniVideo: YouTubeVideo? { short?.currentVideo ?? router.current }
    private var miniSize: CGSize { short == nil ? CGSize(width: 192, height: 108) : CGSize(width: 108, height: 192) }
    private var miniCardWidth: CGFloat { miniSize.width + Self.miniInset * 2 }
    private var miniCardHeight: CGFloat { Self.miniInset + miniSize.height + Self.miniStripHeight }

    var body: some View {
        GeometryReader { geometry in
            if router.current != nil || short != nil {
                content(geometry)
            }
        }
        .ignoresSafeArea(.keyboard)
        .accessibilityHidden(router.isExpanded || router.shortsRoute != nil)
        .onChange(of: router.isExpanded || router.shortsRoute != nil) { _, expanded in
            if expanded { isDocked = false }
        }
    }

    private func content(_ geometry: GeometryProxy) -> some View {
        let insets = geometry.safeAreaInsets
        let screen = CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom
        )
        let mini = CGPoint(
            x: isMiniLeading ? Self.miniMargin : screen.width - miniCardWidth - Self.miniMargin,
            y: isMiniTop ? insets.top + Self.miniMargin : screen.height - miniCardHeight - insets.bottom - Self.tabBarClearance
        )
        let hiddenX = isMiniLeading ? -miniCardWidth - Self.miniMargin : screen.width + Self.miniMargin

        return ZStack(alignment: .topLeading) {
            card(origin: mini, screen: screen)
                .offset(x: isDocked ? hiddenX : mini.x + dragOffset.width, y: mini.y + dragOffset.height)
            if isDocked {
                handle
                    .offset(
                        x: isMiniLeading ? Self.handleVisibleWidth - Self.handleSize.width : screen.width - Self.handleVisibleWidth,
                        y: mini.y + (miniCardHeight - Self.handleSize.height) / 2
                    )
                    .transition(.opacity)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .animation(.snappy, value: isDocked)
        .ignoresSafeArea()
    }

    private func card(origin: CGPoint, screen: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardRadius, style: .circular)
        let isShort = short != nil
        return ZStack(alignment: .topLeading) {
            AmbientImage(
                player: miniPlayerObject,
                video: miniVideo,
                storyboard: isShort ? nil : router.storyboard,
                isPaused: isShort ? router.isShortsPageOnScreen : router.isWatchPageOnScreen
            )
            .frame(width: miniCardWidth, height: miniCardHeight)
            .clipped()
            .blur(radius: 24, opaque: true)
            .saturation(1.4)
            .opacity(0.7)
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Color.clear.glassEffect(.regular, in: shape)

            MpvVideoView(player: miniPlayerObject, isActive: isShort ? !router.isShortsPageOnScreen : !router.isWatchPageOnScreen)
                .id(isShort)
                .overlay { VideoPoster(player: miniPlayerObject, video: miniVideo) }
                .overlay { MovingVideoCover(video: miniVideo, fills: isShort) }
                .frame(width: miniSize.width, height: miniSize.height)
                .background(.black)
                .clipShape(.rect(cornerRadius: Layout.tileRadius, style: .continuous))
                .padding(Self.miniInset)
                .allowsHitTesting(false)

            MiniControls(
                player: miniPlayerObject,
                // A Short's narrow card has no room for the title.
                title: isShort ? nil : miniVideo?.title,
                videoAreaHeight: Self.miniInset + miniSize.height,
                onExpand: {
                    if isShort {
                        router.expandShorts()
                    } else {
                        router.isExpanded = true
                    }
                },
                onClose: {
                    if isShort {
                        router.closeShorts()
                    } else {
                        router.close()
                    }
                },
                onDragChanged: { value in dragOffset = value.translation },
                onDragEnded: { value in finishMiniDrag(value, origin: origin, screen: screen) }
            )

            CardEdgeProgress(clock: miniPlayerObject.clock, player: miniPlayerObject, radius: Self.cardRadius)
        }
        .frame(width: miniCardWidth, height: miniCardHeight)
        .matchedTransitionSource(id: Self.zoomSource, in: zoom) { source in
            source.clipShape(.rect(cornerRadius: Self.cardRadius))
        }
    }

    private var handle: some View {
        Button {
            isDocked = false
        } label: {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.19))
                .overlay(alignment: .leading) {
                    HandleChevron()
                        .stroke(Color(white: 0.75), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: 8, height: 26)
                        .padding(.leading, 8)
                }
                .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                .scaleEffect(x: isMiniLeading ? -1 : 1)
                // Reaches 44 pt, using the space next to the visible part.
                .contentShape(Rectangle().inset(by: -Layout.rowSpacing))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Video")
    }

    /// Snaps to the corner the flick is heading for. A flick past the screen's side hides the card.
    private func finishMiniDrag(_ value: DragGesture.Value, origin: CGPoint, screen: CGSize) {
        let endX = origin.x + value.predictedEndTranslation.width + miniCardWidth / 2
        let endY = origin.y + value.predictedEndTranslation.height + miniCardHeight / 2
        withAnimation(.snappy) {
            isMiniLeading = endX < screen.width / 2
            isMiniTop = endY < screen.height / 2
            isDocked = endX < 0 || endX > screen.width
            dragOffset = .zero
        }
    }
}

/// Points at the side of the screen the card comes back from, like the system's Picture in Picture.
private struct HandleChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// The video page. It opens with the system zoom from the tapped cover or the floating card, which also
/// gives it the system's swipe down to close.
struct WatchPage: View {
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsComments = false
    @State private var pullDistance: CGFloat = 0
    /// Pinching out crops the video to fill the whole screen in full screen.
    @State private var fillsScreen = false

    private var isFullscreen: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            video
                .gesture(PlayerDismissGesture.closing(isEnabled: !isFullscreen, distance: $pullDistance) { router.isExpanded = false })
            if !isFullscreen {
                ScrollView {
                    WatchDetailsView(showsComments: $showsComments)
                }
            }
        }
        .background(alignment: .top) {
            // It stays in place while resting, so it comes back with its colours instead of the poster's.
            ZStack(alignment: .top) {
                Color(.systemBackground)
                AmbientBackdrop(
                    player: router.player,
                    video: router.current,
                    storyboard: router.storyboard,
                    isPaused: isFullscreen
                )
                .opacity(isFullscreen ? 0 : 1)
                if isFullscreen {
                    Color.black
                }
            }
            .ignoresSafeArea()
        }
        .offset(y: pullDistance)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .sheet(isPresented: $showsComments) {
            if let token = router.details?.commentsToken {
                CommentsSheet(token: token)
            }
        }
        .routerPresentations(router, isActive: true)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            Orientation.unlockIfHeldUpright()
        }
        // The phone can lock again while paused, like every other video app.
        .onReceive(router.player.$isPaused.removeDuplicates()) { paused in
            UIApplication.shared.isIdleTimerDisabled = !paused
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var video: some View {
        VideoArea(isFullscreen: isFullscreen) {
            ZStack {
                MpvVideoView(player: router.player, isActive: router.isWatchPageOnScreen, fills: isFullscreen && fillsScreen)
                    .overlay { VideoPoster(player: router.player, video: router.current) }
                    .background(.black)
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: isFullscreen ? .all : [])
                MovingVideoCover(video: router.current, fills: isFullscreen && fillsScreen)
                    .ignoresSafeArea(edges: isFullscreen ? .all : [])
                CaptionOverlay(clock: router.player.clock, cues: router.captionCues, isFullscreen: isFullscreen)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                PlayerControls(player: router.player, sleepTimer: router.sleepTimer, isFullscreen: isFullscreen, fillsScreen: $fillsScreen)
                SponsorSkipButton()
            }
        }
    }
}

/// The picture that was showing when the zoom started, over the video on both the page and the card.
struct MovingVideoCover: View {
    let video: YouTubeVideo?
    var fills = false
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if router.isVideoMoving {
                Color.black
                    .overlay {
                        if let still = router.stillFrame {
                            Image(uiImage: still).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
                        } else if let video {
                            VideoCoverImage(url: video.thumbnailURL, videoId: video.videoId, isShort: video.isShort, maxPixels: 640)
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// All the space in full screen, otherwise the page's width at 16:9.
/// One view for both, so the video and its controls survive the rotation.
private struct VideoArea: SwiftUI.Layout {
    let isFullscreen: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: isFullscreen ? proposal.height ?? 0 : width * 9 / 16)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Woof Music's pull-down to close: the page follows the finger and closes when released far or
/// fast enough. It goes first, because the system's own pull-down often loses to the buttons and
/// sliders: every other gesture except taps and long presses waits until this one has decided
/// the touch isn't a downward pull.
struct PlayerDismissGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ distance: CGFloat, _ velocity: CGFloat) -> Void

    /// Far enough, a fifth of the screen, or a quick flick closes.
    @MainActor
    static func closing(isEnabled: Bool, distance: Binding<CGFloat>, onClose: @escaping () -> Void) -> PlayerDismissGesture {
        PlayerDismissGesture(isEnabled: isEnabled) { pulled in
            distance.wrappedValue = max(0, pulled)
        } onEnded: { pulled, velocity in
            if pulled > UIScreen.main.bounds.height * 0.2 || (pulled > 20 && velocity > 800) {
                // The page stays where the finger left it, so the closing zoom starts from there.
                onClose()
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { distance.wrappedValue = 0 }
            }
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Window coordinates: the page moves while dragged, the window doesn't.
        let distance = recognizer.translation(in: nil).y
        switch recognizer.state {
        case .began, .changed:
            onChanged(distance)
        case .ended:
            onEnded(distance, recognizer.velocity(in: nil).y)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            !(other is UITapGestureRecognizer || other is UILongPressGestureRecognizer)
        }
    }
}

/// YouTube's ambient mode in Woof Music's style: the part of the video playing now, blurred
/// and fading into the page.
private struct AmbientBackdrop: View {
    let player: MpvPlayer
    let video: YouTubeVideo?
    let storyboard: Storyboard?
    let isPaused: Bool

    private static let height: CGFloat = 560

    var body: some View {
        AmbientImage(player: player, video: video, storyboard: storyboard, isPaused: isPaused)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipped()
        .blur(radius: 50, opaque: true)
        .saturation(1.4)
        .opacity(0.65)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.25), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A frame of the video that follows the picture, or the poster until one loads.
struct AmbientImage: View {
    @ObservedObject private var clock: PlayerClock
    private let player: MpvPlayer
    let video: YouTubeVideo?
    let storyboard: Storyboard?
    /// Nothing can see it, so it keeps the frame it has.
    let isPaused: Bool

    /// Seconds between frames. The clock ticks far more often, so only this view redraws with it.
    private static let refresh = 3.0
    @Environment(\.scenePhase) private var scenePhase

    init(player: MpvPlayer, video: YouTubeVideo?, storyboard: Storyboard?, isPaused: Bool) {
        clock = player.clock
        self.player = player
        self.video = video
        self.storyboard = storyboard
        self.isPaused = isPaused
    }

    var body: some View {
        AmbientFrame(player: player, moment: isPaused || scenePhase != .active ? nil : (clock.time / Self.refresh).rounded(.down) * Self.refresh, video: video, storyboard: storyboard)
    }
}

private struct AmbientFrame: View {
    let player: MpvPlayer
    let moment: Double?
    let video: YouTubeVideo?
    let storyboard: Storyboard?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: UIImage?

    private static let liveFrameWidth: CGFloat = 160
    private static let fade = 0.6

    var body: some View {
        ZStack {
            if let frame {
                Image(uiImage: frame).resizable().scaledToFill().transition(.opacity).id(frame)
            } else if let video {
                VideoCoverImage(url: video.thumbnailURL, videoId: video.videoId, isShort: video.isShort, maxPixels: 320)
            }
        }
        .onChange(of: video?.videoId) { frame = nil }
        .task(id: "\(video?.videoId ?? "")|\(moment ?? -1)|\(storyboard?.urlTemplate ?? "")") { await loadFrame() }
    }

    private func loadFrame() async {
        guard let moment, !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let player = player
        if let live = await offMain({ player.currentFrame(width: Self.liveFrameWidth) }) {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.fade)) { frame = live }
            return
        }
        // The video can't give a frame while it's off, so this falls back on YouTube's preview sheets.
        guard let storyboard else { return }
        let spot = storyboard.frame(at: moment)
        guard let url = spot.url?.absoluteString else { return }
        var image = ImageStore.image(for: url)
        if image == nil { image = try? await ImageStore.load(url) }
        guard !Task.isCancelled, let sheet = image?.cgImage else { return }
        let size = storyboard.frameSize
        let area = CGRect(x: size.width * CGFloat(spot.column), y: size.height * CGFloat(spot.row), width: size.width, height: size.height)
        guard let cropped = sheet.cropping(to: area) else { return }
        withAnimation(.easeInOut(duration: 1)) { frame = UIImage(cgImage: cropped) }
    }
}

/// Woof Music's player icon: white, no background, with a shadow to read over the video.
struct PlayerGlyphLabelStyle: LabelStyle {
    var size: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }
}

/// Woof Music's PlayerSkipButtonStyle: a soft disc shows only under the finger.
struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0), in: .circle)
    }
}

/// UIKit gesture recognizers, because they settle tap, hold and drag on one view reliably.
struct PlayerTouchSurface: UIViewRepresentable {
    let onTap: () -> Void
    /// True when a hold starts, false when it ends. Only Shorts use it.
    var onHold: ((Bool) -> Void)?
    /// How far the finger moved sideways while holding, as a fraction of the view's width.
    var onHoldMoved: ((CGFloat) -> Void)?
    /// True for the leading half of the video.
    var onDoubleTap: ((Bool) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?
    /// When false the drag is left to whatever sits behind, like the system's swipe to close.
    var isDragEnabled = true
    /// How far two fingers spread: over 1 outward, under 1 inward.
    var onPinch: ((CGFloat) -> Void)?

    private static let holdDuration = 0.35

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        view.addGestureRecognizer(tap)
        if onDoubleTap != nil {
            let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }
        if onHold != nil {
            let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
            hold.minimumPressDuration = Self.holdDuration
            view.addGestureRecognizer(hold)
        }
        if onDragEnded != nil {
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
            pan.delegate = coordinator
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
        }
        if onPinch != nil {
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:))))
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerTouchSurface
        private var holdStartX: CGFloat = 0

        init(parent: PlayerTouchSurface) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            parent.isDragEnabled
        }

        @objc func tapped() {
            parent.onTap()
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onDoubleTap?(recognizer.location(in: view).x < view.bounds.midX)
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                holdStartX = recognizer.location(in: nil).x
                parent.onHold?(true)
            case .changed:
                let width = max(recognizer.view?.bounds.width ?? 1, 1)
                parent.onHoldMoved?((recognizer.location(in: nil).x - holdStartX) / width)
            case .ended, .cancelled, .failed: parent.onHold?(false)
            default: break
            }
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .ended { parent.onPinch?(recognizer.scale) }
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended || recognizer.state == .cancelled else { return }
            let move = recognizer.translation(in: nil)
            parent.onDragEnded?(CGSize(width: move.x, height: move.y))
        }
    }
}

/// The controls on the floating card: the video shows above, then its title, pause and close.
private struct MiniControls: View {
    @ObservedObject var player: MpvPlayer
    let title: String?
    let videoAreaHeight: CGFloat
    let onExpand: () -> Void
    let onClose: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: videoAreaHeight)
            HStack(spacing: 0) {
                Text(title ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.leading, Layout.rowSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    player.togglePause()
                } label: {
                    Label {
                        Text(player.isPaused ? "Play" : "Pause")
                    } icon: {
                        PlayPauseGlyph(isPaused: player.isPaused, size: 15)
                    }
                }
                Button("Close", systemImage: "xmark", action: onClose)
            }
            .labelStyle(MiniGlyphLabelStyle())
            .buttonStyle(ZoomPressStyle())
            .frame(maxHeight: .infinity)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onExpand)
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged(onDragChanged)
                .onEnded(onDragEnded)
        )
    }
}

/// An icon with a full size tap target inside the card's strip.
private struct MiniGlyphLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

/// Playback progress in a straight line across the card's whole bottom, cut by its corners.
/// Its own view, so only the line redraws as the time ticks.
private struct CardEdgeProgress: View {
    @ObservedObject var clock: PlayerClock
    @ObservedObject var player: MpvPlayer
    let radius: CGFloat
    private static let lineHeight: CGFloat = 5

    private var duration: Double { player.duration }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12))
                Rectangle().fill(.tint).frame(width: geometry.size.width * min(clock.time / max(duration, 1), 1))
            }
            .frame(height: Self.lineHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(.rect(cornerRadius: radius, style: .circular))
        .allowsHitTesting(false)
    }
}

/// Woof Music's ProgressBar: a thin track that thickens while scrubbing.
struct ProgressBar: View {
    @Binding var progress: Double
    /// Where chapters start, from 0 to 1. The bar splits at each one.
    var marks: [Double] = []
    /// Colored parts of the video, drawn over the bar.
    var highlights: [BarHighlight] = []
    /// Shows the bar as thick as while scrubbing, for scrubbing that happens elsewhere.
    var isEmphasized = false
    let onEditingChanged: (Bool) -> Void
    @GestureState private var isScrubbing = false
    @State private var didStartEditing = false
    /// A segment of a few seconds in a long video stays visible.
    private static let minHighlightWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let isThick = isScrubbing || isEmphasized
            let inset: CGFloat = isThick ? 0 : Layout.chipSpacing
            let trackWidth = max(0, geometry.size.width - inset * 2)
            let height: CGFloat = isThick ? 12 : (marks.isEmpty ? 5 : 7)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3)).frame(height: height)
                Rectangle().fill(.tint).frame(width: trackWidth * min(max(progress, 0), 1), height: height)
                ForEach(highlights) { highlight in
                    Rectangle()
                        .fill(highlight.color)
                        .frame(width: max(trackWidth * (highlight.end - highlight.start), Self.minHighlightWidth), height: height)
                        .offset(x: trackWidth * highlight.start)
                }
            }
            .frame(height: height)
            .clipShape(BarSegments(marks: marks, position: progress, otherHeight: isThick ? 6 : 3))
            .padding(.horizontal, inset)
            .animation(.easeInOut(duration: 0.2), value: isThick)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isScrubbing) { _, active, _ in active = true }
                    .onChanged { value in
                        if !didStartEditing {
                            didStartEditing = true
                            onEditingChanged(true)
                        }
                        progress = Double(min(max(value.location.x / max(geometry.size.width, 1), 0), 1))
                    }
                    .onEnded { _ in
                        didStartEditing = false
                        onEditingChanged(false)
                    }
            )
            .onChange(of: isScrubbing) { _, scrubbing in
                // A cancelled drag never calls onEnded, so the edit finishes here.
                if !scrubbing, didStartEditing {
                    didStartEditing = false
                    onEditingChanged(false)
                }
            }
        }
        .frame(height: 24)
    }
}

/// One rounded piece per chapter, with a small gap between them.
/// The chapter at `position` fills the height, and the others are thinner, as on YouTube.
private struct BarSegments: Shape {
    let marks: [Double]
    let position: Double
    var otherHeight: CGFloat
    private static let gap: CGFloat = 2

    var animatableData: CGFloat {
        get { otherHeight }
        set { otherHeight = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let edges = [0] + marks + [1]
        var path = Path()
        for (start, end) in zip(edges, edges.dropFirst()) {
            let isCurrent = start <= position && (position < end || end == 1)
            let height = isCurrent ? rect.height : min(otherHeight, rect.height)
            let x = rect.minX + rect.width * start + (start > 0 ? Self.gap / 2 : 0)
            let width = rect.width * (end - start) - (start > 0 ? Self.gap / 2 : 0) - (end < 1 ? Self.gap / 2 : 0)
            path.addRoundedRect(in: CGRect(x: x, y: rect.midY - height / 2, width: max(width, 1), height: height), cornerSize: CGSize(width: height / 2, height: height / 2))
        }
        return path
    }
}

/// Shows one frame by moving the whole sheet behind a small window.
private struct StoryboardPreview: View {
    let storyboard: Storyboard
    let seconds: Double
    private static let width: CGFloat = 128

    var body: some View {
        let frame = storyboard.frame(at: seconds)
        let scale = Self.width / storyboard.frameSize.width
        let height = storyboard.frameSize.height * scale
        CachedImage(url: frame.url?.absoluteString, maxPixels: nil)
            .frame(width: Self.width * CGFloat(storyboard.columns), height: height * CGFloat(storyboard.rows))
            .offset(x: -Self.width * CGFloat(frame.column), y: -height * CGFloat(frame.row))
            .frame(width: Self.width, height: height, alignment: .topLeading)
            .background(Color.black.opacity(0.4))
        .frame(width: Self.width, height: height)
        .clipShape(.rect(cornerRadius: Layout.cardRadius))
        .allowsHitTesting(false)
    }
}

/// The progress bar and times, as in Woof Music's player. Only this part redraws as the time ticks.
private struct PlayerProgress: View {
    @ObservedObject var clock: PlayerClock
    let player: MpvPlayer
    let duration: Double
    let isFullscreen: Bool
    let storyboard: Storyboard?
    let chapters: [Chapter]
    let segments: [SponsorSegment]
    let onScrubbing: (Bool) -> Void
    private static let timeDrop: CGFloat = 5
    @State private var position = 0.0
    @State private var isEditing = false

    var body: some View {
        let total = max(duration, 1)
        let shownTime = isEditing ? position * total : clock.time
        let chapter = chapters.last { $0.start <= shownTime }
        let segment = segments.first { $0.range.contains(shownTime) }
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                HStack(alignment: .bottom) {
                    if player.isLiveStream {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, Layout.rowPadding)
                            .padding(.vertical, 2)
                            .background(.tint, in: .capsule)
                    } else {
                        Text("\(shownTime.clockText) | \(duration.clockText)")
                    }
                    if let chapter {
                        chapterMenu(current: chapter)
                    }
                    if let segment {
                        HStack(spacing: Layout.chipSpacing / 2) {
                            Circle().fill(segment.category.color).frame(width: 8, height: 8)
                            Text(segment.category.title).font(.caption2.weight(.semibold))
                        }
                        .fixedSize()
                    }
                }
                // The buttons beside it need their 44 pt, so this reaches into the bar's empty space.
                .offset(y: Self.timeDrop)
                Spacer(minLength: 0)
                RoutePicker().frame(width: 44, height: 44)
                Button {
                    Orientation.setFullscreen(!isFullscreen)
                } label: {
                    Label {
                        Text(isFullscreen ? "Exit Full Screen" : "Full Screen")
                    } icon: {
                        Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                .buttonStyle(PlayerPressStyle())
                .labelStyle(PlayerGlyphLabelStyle(size: 15))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(.leading, Layout.chipSpacing)

            if !player.isLiveStream {
                ProgressBar(
                    progress: Binding(get: { isEditing ? position : clock.time / total }, set: { position = $0 }),
                    marks: chapters.dropFirst().map { $0.start / total },
                    highlights: segments.map { BarHighlight(id: $0.id, start: $0.range.lowerBound / total, end: min($0.range.upperBound / total, 1), color: $0.category.color) },
                    onEditingChanged: { editing in
                        if editing {
                            position = clock.time / total
                        } else {
                            player.seek(to: position * total)
                        }
                        isEditing = editing
                        onScrubbing(editing)
                    }
                )
            }
        }
        // Above the bar without taking up room, so the controls don't move while scrubbing.
        .overlay(alignment: .top) {
            if isEditing, let storyboard {
                StoryboardPreview(storyboard: storyboard, seconds: position * total)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
        }
        .sensoryFeedback(.selection, trigger: chapter?.start) { _, _ in isEditing }
    }

    /// The name of the current chapter. It lists all of them, replacing a row under the video.
    private func chapterMenu(current: Chapter) -> some View {
        Menu {
            ForEach(chapters, id: \.self) { chapter in
                Button {
                    player.seek(to: chapter.start)
                } label: {
                    if chapter == current {
                        Label(chapter.title, systemImage: "checkmark")
                    } else {
                        Text(chapter.title)
                    }
                    Text(chapter.start.clockText)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(current.title).lineLimit(1)
                Image(systemName: "chevron.right").imageScale(.small)
            }
            .font(.caption2.weight(.semibold))
            .frame(minHeight: 44, alignment: .bottom)
            .contentShape(.rect)
        }
        .accessibilityLabel("Chapter: \(current.title)")
    }
}

private struct SeekHint {
    let id = UUID()
    let isLeading: Bool
    /// Double taps in a row add up.
    let seconds: Int
}

/// A moon with a ring that shrinks as the time runs out.
private struct SleepGlyph: View {
    @ObservedObject var timer: SleepTimer
    private static let ringSize: CGFloat = 32

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Image(systemName: "moon.zzz.fill")
                .background {
                    if let endsAt = timer.endsAt, let minutes = timer.minutes {
                        Circle()
                            .trim(from: 0, to: CGFloat(max(endsAt.timeIntervalSince(context.date) / Double(minutes * 60), 0)))
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: Self.ringSize, height: Self.ringSize)
                    }
                }
        }
    }
}

private struct PlayerControls: View {
    private static let skipSeconds = 10
    private static let exitFullscreenDistance: CGFloat = 60
    /// The same distance upward opens Up Next.
    private static let upNextDistance: CGFloat = 60
    /// A pinch smaller than this is two fingers resting on the screen.
    private static let pinchMargin: CGFloat = 0.05
    /// mpv often waits a moment for data with no visible effect, so the spinner waits longer.
    private static let spinnerDelay = Duration.milliseconds(600)

    @ObservedObject var player: MpvPlayer
    @ObservedObject var sleepTimer: SleepTimer
    let isFullscreen: Bool
    @Binding var fillsScreen: Bool

    @Environment(Router.self) private var router
    @State private var showsControls = true
    @State private var showsSleepTimer = false
    @State private var hideTask: Task<Void, Never>?
    @State private var seekHint: SeekHint?
    @State private var showsSpinner = false
    @State private var showsUpNext = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func setUpNext(_ isShown: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy) {
            showsUpNext = isShown
            if isShown { showsControls = false }
        }
        if isShown { hideTask?.cancel() }
    }

    /// Nothing to show yet, so the spinner appears at once.
    private var isStarting: Bool {
        !player.isVideoReady && router.loadError == nil && player.errorText == nil
    }

    /// Playing video that ran out of data, which often lasts too little to be worth a spinner.
    private var isLoading: Bool {
        player.isVideoReady && player.isBuffering
    }

    var body: some View {
        ZStack {
            PlayerTouchSurface(
                onTap: {
                    guard !showsUpNext else { return setUpNext(false) }
                    withAnimation(.easeOut(duration: 0.15)) { showsControls.toggle() }
                    scheduleHide()
                },
                onDoubleTap: { isLeading in
                    guard !player.isLiveStream else { return }
                    player.skip(by: Double(isLeading ? -Self.skipSeconds : Self.skipSeconds))
                    let previous = seekHint?.isLeading == isLeading ? seekHint?.seconds ?? 0 : 0
                    seekHint = SeekHint(isLeading: isLeading, seconds: previous + Self.skipSeconds)
                },
                onDragEnded: { translation in
                    if translation.height < -Self.upNextDistance {
                        setUpNext(true)
                    } else if translation.height > Self.exitFullscreenDistance {
                        if showsUpNext { setUpNext(false) } else { Orientation.setFullscreen(false) }
                    }
                },
                isDragEnabled: isFullscreen,
                onPinch: { scale in
                    guard isFullscreen, abs(scale - 1) > Self.pinchMargin else { return }
                    fillsScreen = scale > 1
                }
            )
            .ignoresSafeArea(edges: isFullscreen ? .all : [])

            if isStarting || showsSpinner {
                ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
            }
            if showsControls {
                controls.transition(.opacity)
            }
            if showsUpNext {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                UpNextPanel { setUpNext(false) }
                    .padding(.horizontal, Layout.cardSpacing)
                    .padding(.bottom, Layout.rowSpacing)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95, anchor: .bottom).combined(with: .opacity))
            }
            if let seekHint {
                VStack(spacing: Layout.cardSpacing) {
                    Image(systemName: seekHint.isLeading ? "gobackward.10" : "goforward.10")
                        .font(.system(size: 28, weight: .semibold))
                    if seekHint.seconds > Self.skipSeconds {
                        Text("\(seekHint.isLeading ? "−" : "+")\(seekHint.seconds)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .frame(maxWidth: .infinity, alignment: seekHint.isLeading ? .leading : .trailing)
                    .padding(.horizontal, 40)
                    .allowsHitTesting(false)
                    .id(seekHint.id)
                    .task(id: seekHint.id) {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        self.seekHint = nil
                    }
            }
        }
        .environment(\.colorScheme, .dark)
        .buttonStyle(PlayerPressStyle())
        .labelStyle(PlayerGlyphLabelStyle())
        .sheet(isPresented: $showsSleepTimer) {
            SleepTimerSheet(timer: sleepTimer)
        }
        .sensoryFeedback(.selection, trigger: fillsScreen)
        .onChange(of: isFullscreen) { if !isFullscreen { showsUpNext = false } }
        .accessibilityAction(named: "Up Next") { if isFullscreen { setUpNext(true) } }
        .onAppear(perform: scheduleHide)
        .onChange(of: player.isPaused) { scheduleHide() }
        .task(id: isLoading) {
            guard isLoading else {
                showsSpinner = false
                return
            }
            try? await Task.sleep(for: Self.spinnerDelay)
            if !Task.isCancelled { showsSpinner = true }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                if sleepTimer.isActive {
                    Button {
                        showsSleepTimer = true
                    } label: {
                        Label {
                            Text("Sleep Timer")
                        } icon: {
                            SleepGlyph(timer: sleepTimer)
                        }
                    }
                }
                if player.speed != 1 {
                    speedMenu
                }
                optionsMenu
            }
            Spacer(minLength: 0)
            PlayerProgress(clock: player.clock, player: player, duration: player.duration, isFullscreen: isFullscreen, storyboard: router.storyboard, chapters: router.details?.chapters ?? [], segments: router.usesSponsorBlock ? router.sponsorSegments : []) { scrubbing in
                if scrubbing {
                    hideTask?.cancel()
                } else {
                    scheduleHide()
                }
            }
        }
        // Centred on the whole video, not on the space between the top buttons and the bar.
        .overlay {
            if !isStarting, !showsSpinner {
                Button {
                    player.togglePause()
                } label: {
                    Label {
                        Text(player.isPaused ? "Play" : "Pause")
                    } icon: {
                        PlayPauseGlyph(isPaused: player.isPaused, size: 34)
                    }
                }
                .labelStyle(PlayerGlyphLabelStyle(size: 34))
            }
        }
        .padding(.horizontal, Layout.cardSpacing)
        .background(alignment: .top) {
            if !isFullscreen {
                closeHandle
            }
        }
        .background {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.7),
                .init(color: .black.opacity(0.35), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: isFullscreen ? .all : [])
        }
    }

    /// Woof Music's player handle, on the video. It stays behind the buttons in the same row.
    private var closeHandle: some View {
        Button {
            router.isExpanded = false
        } label: {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .frame(width: 80, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Video")
    }

    /// Woof Music's speed chip: accent filled away from 1x.
    private var speedMenu: some View {
        Menu {
            speedPicker
        } label: {
            HStack(spacing: 3) {
                SpeedGauge(speed: player.speed)
                Text(player.speed.speedText)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
            }
                .foregroundStyle(.white)
                .padding(.horizontal, Layout.chipSpacing)
                .padding(.vertical, 3)
                .background { Capsule().fill(.tint) }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Playback speed, \(player.speed.speedText)")
    }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(get: { player.speed }, set: { speed in
            player.setSpeed(speed)
        })) {
            ForEach(Router.speeds, id: \.self) { speed in
                Text(speed == 1 ? "Normal" : speed.speedText).tag(speed)
            }
        }
    }

    @ViewBuilder
    private var captionsMenu: some View {
        if !router.captions.isEmpty {
            Menu {
                CaptionChoices(tracks: router.captions, selected: router.selectedCaption) { router.selectCaption($0) }
            } label: {
                Label("Captions", systemImage: router.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill")
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            captionsMenu
            if router.audioTracks.count > 1 {
                Menu("Audio Track", systemImage: "waveform") {
                    ForEach(router.audioTracks) { track in
                        Button {
                            router.selectAudioTrack(track)
                        } label: {
                            if router.selectedAudioTrack == track.id {
                                Label(track.name, systemImage: "checkmark")
                            } else {
                                Text(track.name)
                            }
                        }
                    }
                }
            }
            Picker("Quality", systemImage: "sparkles.tv", selection: Binding(get: { router.maxHeight }, set: { height in
                router.changeQuality(to: height)
            })) {
                ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Speed", systemImage: player.speed.gaugeSymbol, selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                ForEach(Router.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : speed.speedText).tag(speed)
                }
            }
            .pickerStyle(.menu)
            if let screen = TVLink.shared.screen {
                Button("Play on \(screen.name)", systemImage: "tv") { router.playOnTV() }
            }
            Button(sleepTimer.isActive ? "Sleep Timer · On" : "Sleep Timer…", systemImage: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz") {
                showsSleepTimer = true
            }
            if let summary = router.streamSummary {
                Section(summary) {}
            }
        } label: {
            // The Shorts player's mark, in the accent color.
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.tint)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("More")
        // Hiding the controls would take the open menu with them.
        .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
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

/// Full screen's Up Next: the related videos in a row that scrolls sideways, floating like Woof Music's queue.
private struct UpNextPanel: View {
    let onClose: () -> Void
    @Environment(Router.self) private var router

    private static let cardWidth: CGFloat = 168
    private static let radius: CGFloat = 24

    private var videos: [YouTubeVideo] {
        (router.details?.related ?? []).filter { !$0.isShort }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Layout.chipSpacing) {
                Text("Up Next")
                    .font(.title2.bold())
                Spacer(minLength: 0)
                autoplayPill
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .accessibilityLabel("Close Up Next")
            }
            .padding(.leading, 20)
            .padding(.trailing, Layout.cardSpacing)
            .padding(.top, Layout.cardSpacing)
            if videos.isEmpty {
                Text("Nothing to suggest yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                        ForEach(videos, id: \.videoId) { video in
                            Button {
                                router.play(video, expand: false)
                                onClose()
                            } label: {
                                card(video)
                            }
                            .buttonStyle(ZoomPressStyle())
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                // A sideways scroll view would otherwise take all the height it's offered.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Layout.chipSpacing)
                .padding(.bottom, 16)
            }
        }
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.radius))
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height > 60, abs(value.translation.height) > abs(value.translation.width) { onClose() }
        })
        .accessibilityAction(.escape, onClose)
    }

    /// Woof Music's queue pills: brighter when on.
    private var autoplayPill: some View {
        Button {
            router.autoplay.toggle()
        } label: {
            Label("Autoplay", systemImage: "play.square.stack")
                // The player's own label style shows only the icon.
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.white.opacity(router.autoplay ? 0.15 : 0.07), in: .capsule)
                .foregroundStyle(.white.opacity(router.autoplay ? 1 : 0.6))
                .frame(height: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(ZoomPressStyle())
        .sensoryFeedback(.selection, trigger: router.autoplay)
        .accessibilityValue(router.autoplay ? "On" : "Off")
    }

    private func card(_ video: YouTubeVideo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            VideoCover(video: video, maxPixels: 600)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { VideoBadge(video: video, extras: VideoExtras(), isCompact: true) }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
            VideoTitle(video: video)
                .font(.subheadline.weight(.semibold))
                // Two lines always, so every card in the row has the same height.
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .padding(.top, 5)
            Text(video.channelTitle ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.cardWidth)
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

private struct PlaybackFailure: View {
    @ObservedObject var player: MpvPlayer
    @Environment(Router.self) private var router

    var body: some View {
        if router.isMembersOnly, let video = router.current {
            membersOnly(video)
        } else if let failure = router.loadError ?? player.errorText {
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let video = router.current {
                    Button("Try Again") { router.play(video) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Joining happens on YouTube, so the button opens the video there.
    private func membersOnly(_ video: YouTubeVideo) -> some View {
        VStack(spacing: Layout.chipSpacing) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Members Only")
                .font(.headline)
            Text("Only members of \(router.details?.channelTitle ?? video.channelTitle ?? "this channel") can watch this video. You can join on YouTube.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = URL(string: "https://www.youtube.com/watch?v=\(video.videoId)") {
                Link("Open in YouTube", destination: url)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Layout.rowSpacing)
        .materialCard()
    }
}

private struct WatchDetailsView: View {
    @Binding var showsComments: Bool
    @Environment(Router.self) private var router
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var showsDescription = false
    @State private var showsPlaylists = false
    @State private var showsChat = false
    @State private var confirmsDeleteDownload = false
    @State private var likeTaps = 0
    @State private var dislikeTaps = 0
    @State private var shareTaps = 0
    @State private var laterTaps = 0
    @State private var finishedDownloads = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            infoHeader
            PlaybackFailure(player: router.player)
            if let details = router.details {
                descriptionCard(details)
                if router.isLive, router.liveChatToken != nil {
                    Button { showsChat = true } label: {
                        HStack {
                            Label {
                                Text("Live Chat")
                            } icon: {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .glyphMotion(showsChat ? .bubblePop : nil, trigger: showsChat)
                            }
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(Layout.rowSpacing)
                        .frame(minHeight: 44)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.tileRadius))
                        .contentShape(.rect)
                    }
                    .buttonStyle(ZoomPressStyle(scale: 0.98))
                }
                if details.commentsToken != nil {
                    CommentsCard(details: details) { showsComments = true }
                }
                if !router.queue.isEmpty {
                    QueueCard()
                }
                if !details.related.isEmpty {
                    if !router.queue.isEmpty {
                        Rectangle()
                            .fill(Color.primary.opacity(0.2))
                            .frame(height: 1)
                            .padding(.vertical, Layout.chipSpacing)
                            .accessibilityHidden(true)
                    }
                    Text("Up Next")
                        .font(.title3.bold())
                        .padding(.top, Layout.chipSpacing)
                    // Lazy, so each card asks for its like counts only when it comes into view.
                    LazyVStack(spacing: Layout.rowSpacing * 2) {
                        ForEach(details.related, id: \.videoId) { video in
                            VideoButton(video: video)
                        }
                    }
                }
            }
        }
        .padding(Layout.screenPadding)
        .sheet(isPresented: $showsChat) {
            if let token = router.liveChatToken {
                LiveChatSheet(token: token)
            }
        }
        .sheet(isPresented: $showsPlaylists) {
            if let video = router.current {
                PlaylistPickerSheet(video: video)
            }
        }
    }

    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            if let video = router.current {
                VideoTitle(video: video)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details = router.details {
                channelRow(details)
                actions(details)
            } else if !router.detailsUnavailable {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    HStack(spacing: Layout.rowSpacing) {
                        ShimmerBlock(width: Layout.avatarSmall, height: Layout.avatarSmall, radius: Layout.avatarSmall / 2)
                        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                            ShimmerBlock(width: 140, height: 14)
                            ShimmerBlock(width: 90, height: 12)
                        }
                        Spacer(minLength: 0)
                        ShimmerBlock(width: 96, height: 38, radius: 19)
                    }
                    HStack(spacing: 10) {
                        ShimmerFill(radius: 19).frame(height: 38)
                        ForEach(0..<4, id: \.self) { _ in
                            ShimmerBlock(width: 38, height: 38, radius: 19)
                        }
                    }
                    ForEach(0..<2, id: \.self) { _ in
                        ShimmerFill(radius: Layout.sheetRadius).frame(height: 88)
                    }
                }
                .shimmerClock()
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func channelLabel(_ details: WatchDetails) -> some View {
        HStack(spacing: Layout.rowSpacing) {
            if details.collaborators.count > 1 {
                AvatarStack(urls: details.collaborators.map(\.avatar), size: Layout.avatarSmall)
            } else {
                Avatar(url: details.channelAvatar, size: Layout.avatarSmall)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(details.channelTitle ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(details.subscribers ?? (details.collaborators.count > 1 ? "\(details.collaborators.count) creators" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func channelRow(_ details: WatchDetails) -> some View {
        if let id = details.channelId {
            HStack(spacing: Layout.rowSpacing) {
                if details.collaborators.count > 1 {
                    Menu {
                        ForEach(details.collaborators) { creator in
                            Menu {
                                Button("Open Channel", systemImage: "person.crop.circle") {
                                    router.openChannelPage(creator.channelId)
                                }
                                Button("Subscribe", systemImage: "person.badge.plus") {
                                    router.run { _ = try await InnerTubeClient.wooftube.subscribe(channelId: creator.channelId) }
                                }
                                Button("Unsubscribe", systemImage: "person.badge.minus") {
                                    router.run { _ = try await InnerTubeClient.wooftube.unsubscribe(channelId: creator.channelId) }
                                }
                            } label: {
                                Text(creator.name)
                                Text(creator.subtitle)
                            }
                        }
                    } label: {
                        channelLabel(details)
                    }
                    .buttonStyle(ZoomPressStyle(scale: 0.98))
                } else {
                    Button {
                        router.openChannelPage(id)
                    } label: {
                        channelLabel(details)
                    }
                    .buttonStyle(ZoomPressStyle(scale: 0.98))
                }
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
        // Spacing 0 keeps the shapes apart instead of letting nearby glass merge.
        return GlassEffectContainer(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button {
                        likeTaps += 1
                        setLike(isLiked ? "INDIFFERENT" : "LIKE")
                    } label: {
                        likeLabel(
                            icon: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                            text: (isLiked ? details.likeCountLiked : details.likeCount) ?? "Like",
                            isActive: isLiked,
                            motion: isLiked ? .like(emojis: VideoFlavor.emojis(for: router.current?.title)) : .deflate,
                            taps: likeTaps
                        )
                    }
                    .accessibilityLabel("Like")
                    Divider().frame(height: 18)
                    Button {
                        dislikeTaps += 1
                        setLike(isDisliked ? "INDIFFERENT" : "DISLIKE")
                    } label: {
                        likeLabel(
                            icon: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                            text: details.dislikeCount.map { ($0 + (isDisliked ? 1 : 0)).compactText },
                            isActive: isDisliked,
                            motion: isDisliked ? .dislike : .rise,
                            taps: dislikeTaps
                        )
                    }
                    .accessibilityLabel("Dislike")
                }
                .frame(maxWidth: .infinity)
                .glassEffect(.regular.interactive(), in: .capsule)
                if let id = router.current?.videoId, let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                    ShareLink(item: url) {
                        HeaderRoundIcon(systemImage: "square.and.arrow.up")
                            .symbolEffect(.bounce.up.byLayer, value: shareTaps)
                    }
                    .simultaneousGesture(TapGesture().onEnded { shareTaps += 1 })
                    .accessibilityLabel("Share")
                    Button {
                        laterTaps += 1
                        toggleWatchLater(id, isSaved: details.isInWatchLater)
                    } label: {
                        ClockGlyph(isSaved: details.isInWatchLater, trigger: laterTaps)
                            .frame(width: 38, height: 38)
                            .glassEffect(.regular.interactive(), in: .circle)
                            // Reaches 44 pt, using the gap between neighbouring buttons.
                            .contentShape(Circle().inset(by: -3))
                    }
                    .accessibilityLabel(details.isInWatchLater ? "Remove from Watch Later" : "Save to Watch Later")
                    Button {
                        showsPlaylists = true
                    } label: {
                        HeaderRoundIcon(systemImage: "text.badge.plus")
                            .symbolEffect(.bounce.byLayer, value: showsPlaylists)
                    }
                    .accessibilityLabel("Add to Playlist")
                    if let video = router.current {
                        let isSaved = downloads.isDownloaded(id)
                        let isSaving = downloads.isQueued(id)
                        Button {
                            if isSaved {
                                confirmsDeleteDownload = true
                            } else {
                                router.run { try await downloads.download(video, from: router.playlistVideos, maxHeight: router.maxHeight) }
                            }
                        } label: {
                            if isSaving {
                                DownloadRing(fraction: downloads.active.first { $0.id == id }?.fraction ?? 0)
                            } else {
                                HeaderRoundIcon(systemImage: isSaved ? "checkmark" : "arrow.down.to.line", motion: .checkStamp, trigger: finishedDownloads)
                            }
                        }
                        .disabled(isSaving)
                        .onChange(of: isSaving) { wasSaving, _ in
                            if wasSaving, isSaved { finishedDownloads += 1 }
                        }
                        .accessibilityLabel(isSaved ? "Delete Download" : isSaving ? "Downloading" : "Download")
                        .confirmationDialog("Delete this download?", isPresented: $confirmsDeleteDownload, titleVisibility: .visible) {
                            Button("Delete Download", role: .destructive) {
                                if let item = downloads.items.first(where: { $0.id == id }) { downloads.delete(item) }
                            }
                        }
                    }
                }
            }
            .buttonStyle(GlassPressStyle())
            .sensoryFeedback(.impact(weight: .light), trigger: details.likeStatus)
            .sensoryFeedback(.success, trigger: details.isInWatchLater) { _, saved in saved }
        }
    }

    private func likeLabel(icon: String, text: String?, isActive: Bool, motion: GlyphScript, taps: Int) -> some View {
        HStack(spacing: Layout.rowPadding) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .glyphMotion(motion, trigger: taps)
            if let text {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, Layout.chipSpacing)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        // Reaches 44 pt, using the space around the capsule.
        .contentShape(Rectangle().inset(by: -3))
    }

    /// Closed, the whole card opens it. Open, it isn't a button, so its links can take taps.
    @ViewBuilder
    private func descriptionCard(_ details: WatchDetails) -> some View {
        if showsDescription {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                descriptionText(details)
                Button("Show Less") { toggleDescription() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .materialCard()
            .environment(\.openURL, OpenURLAction { router.openDescriptionLink($0) })
        } else {
            Button {
                toggleDescription()
            } label: {
                descriptionText(details)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .materialCard()
            }
            .buttonStyle(ZoomPressStyle(scale: 0.98))
        }
    }

    private func descriptionText(_ details: WatchDetails) -> some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            let metadata = [details.views, details.age ?? router.current?.publishedTimeText, details.date].compactMap { $0 }
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · ")).font(.subheadline.weight(.semibold))
            }
            if let description = details.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(showsDescription ? nil : 2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func toggleDescription() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy) { showsDescription.toggle() }
    }

    private func toggleWatchLater(_ id: String, isSaved: Bool) {
        router.setDetails { $0.isInWatchLater = !isSaved }
        Task {
            do {
                if isSaved {
                    try await PlaylistActions.remove(id, from: YouTubeFeeds.watchLaterPlaylistId)
                } else {
                    try await PlaylistActions.add(id, to: YouTubeFeeds.watchLaterPlaylistId)
                }
            } catch {
                if router.current?.videoId == id { router.setDetails { $0.isInWatchLater = isSaved } }
                router.actionMessage = error.localizedDescription
            }
        }
    }

    private func setLike(_ status: String) {
        guard let id = router.current?.videoId, let previous = router.details?.likeStatus else { return }
        router.setDetails { $0.likeStatus = status }
        Task {
            do {
                try await YouTubeAPI.setLike(status, videoId: id)
            } catch {
                if router.current?.videoId == id { router.setDetails { $0.likeStatus = previous } }
                router.actionMessage = error.localizedDescription
            }
        }
    }
}

/// The real progress of this video's download, around the arrow that's coming in.
private struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(fraction, 0.03)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .glyphMotion(.arrowDrop, trigger: 0, playsOnAppear: true)
        }
        .padding(5)
        .frame(width: 38, height: 38)
        .glassEffect(.regular, in: .circle)
    }
}

/// The most relevant comment, in a card that opens the rest. For videos and Shorts.
struct CommentsCard: View {
    /// Nil until it loads. The card already shows, so the page around it doesn't jump.
    let details: WatchDetails?
    var commentLines = 2
    /// Keeps the comment's place while it loads.
    var isLoading = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                HStack(spacing: Layout.rowPadding) {
                    Text("Comments").font(.subheadline.weight(.semibold))
                    if let count = details?.commentCount {
                        Text(count)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let comment = details?.topComment {
                    HStack(alignment: .top, spacing: Layout.chipSpacing) {
                        Avatar(url: comment.avatar, size: Layout.avatarSmall)
                        Text(comment.text)
                            .font(.footnote)
                            .lineLimit(commentLines)
                            .multilineTextAlignment(.leading)
                    }
                } else if isLoading {
                    HStack(spacing: Layout.chipSpacing) {
                        Circle()
                            .fill(Color(.secondarySystemFill))
                            .frame(width: 24, height: 24)
                        Text("The most relevant comment goes here")
                            .font(.footnote)
                            .lineLimit(1)
                            .redacted(reason: .placeholder)
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .materialCard()
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
        .disabled(details == nil)
    }
}

/// What plays next, apart from YouTube's suggestions below. A long playlist stays short until opened.
private struct QueueCard: View {
    @Environment(Router.self) private var router
    @State private var showsAll = false

    private static let collapsedCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(router.playlistTitle ?? "Queue")
                    .font(.title3.bold())
                    .lineLimit(2)
                Text("\(router.queue.count)\(router.playlistTitle == nil ? "" : "+") next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(showsAll ? router.queue : Array(router.queue.prefix(Self.collapsedCount)), id: \.videoId) { video in
                    Button {
                        router.playFromQueue(video)
                    } label: {
                        CompactVideoRow(video: video)
                    }
                    .buttonStyle(ZoomPressStyle(scale: 0.98))
                    .videoMenu(video)
                }
            }
            if router.queue.count > Self.collapsedCount {
                Button(showsAll ? "Show Less" : "Show All") {
                    withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy) { showsAll.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialCard()
    }
}

extension View {
    /// The cards on the video page, over the blurred thumbnail.
    func materialCard() -> some View {
        padding(Layout.rowSpacing)
            .background(.regularMaterial, in: .rect(cornerRadius: Layout.sheetRadius, style: .continuous))
            .clipShape(.rect(cornerRadius: Layout.sheetRadius, style: .continuous))
    }
}

struct SubscribeButton: View {
    let channelId: String
    let isSubscribed: Bool
    /// Spelled out with an icon and as wide as it can be, for the channel page's header.
    var isLarge = false
    let onChange: (Bool) -> Void
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            toggle()
        } label: {
            if isLarge {
                Label(isSubscribed ? "Subscribed" : "Subscribe", systemImage: isSubscribed ? "person.fill.checkmark" : "person.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSubscribed ? Color.primary : Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .glassEffect(Glass.regular.tint(isSubscribed ? nil : settings.accentColor).interactive(), in: .capsule)
                    .contentShape(.capsule)
            } else {
                Text(isSubscribed ? "Subscribed" : "Subscribe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSubscribed ? Color.primary : Color.white)
                    .contentTransition(.interpolate)
                    .padding(.horizontal, Layout.screenPadding)
                    .frame(height: 38)
                    .glassEffect(Glass.regular.tint(isSubscribed ? nil : settings.accentColor).interactive(), in: .capsule)
                    .contentShape(.capsule)
            }
        }
        .buttonStyle(GlassPressStyle())
        .glyphMotion(isSubscribed ? .subscribed : .unsubscribed, trigger: taps)
        .animation(reduceMotion ? nil : .snappy, value: isSubscribed)
        .accessibilityLabel(isSubscribed ? "Unsubscribe" : "Subscribe")
        .sensoryFeedback(.selection, trigger: isSubscribed)
    }

    private func toggle() {
        Self.set(!isSubscribed, channelId: channelId, onChange: onChange)
    }

    /// Shows the change straight away, and takes it back if YouTube refuses.
    static func set(_ target: Bool, channelId: String, onChange: @escaping (Bool) -> Void) {
        onChange(target)
        Subscriptions.shared.setSubscribed(channelId, target)
        Task {
            let tube = InnerTubeClient.wooftube
            do {
                _ = target ? try await tube.subscribe(channelId: channelId) : try await tube.unsubscribe(channelId: channelId)
            } catch {
                onChange(!target)
                Subscriptions.shared.setSubscribed(channelId, !target)
            }
        }
    }
}

/// The channel page's search button grown into a search bar, with the results under it.
private struct ChannelSearchContent: View {
    static let barId = "channelSearchBar"
    /// The code channel pages use for their search tab.
    private static let searchTab = "EgZzZWFyY2jyBgQKAloA"

    let channelId: String
    let channelTitle: String
    let morph: Namespace.ID
    let onClose: () -> Void
    @State private var model = FeedModel()
    @State private var text = ""
    @State private var query = ""
    @FocusState private var isFocused: Bool

    private var source: FeedSource { .scoped(browseId: channelId, params: Self.searchTab, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Layout.chipSpacing) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(channelTitle.isEmpty ? "Search this channel" : "Search \(channelTitle)", text: $text)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                Button("Close Search", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(ZoomPressStyle())
            }
            .padding(.leading, Layout.screenPadding)
            .frame(height: 50)
            .glassEffect(.regular, in: .capsule)
            .matchedGeometryEffect(id: Self.barId, in: morph)
            .padding(.horizontal, Layout.screenPadding)
            .padding(.vertical, Layout.chipSpacing)

            if query.isEmpty {
                ContentUnavailableView("Search This Channel", systemImage: "magnifyingglass")
            } else {
                FeedContent(model: model, retry: { await model.load(source) }, isCompact: true) { EmptyView() }
            }
        }
        .onAppear { isFocused = true }
        .task(id: text) {
            // Waits for a pause in typing, because each change cancels this task.
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            if !Task.isCancelled { query = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .task(id: query) {
            if !query.isEmpty { await model.load(source) }
        }
    }
}

/// Woof Music's artist page over the channel's banner, then the pinned or latest video,
/// then the channel's tabs as filters.
struct ChannelView: View {
    @State private var searchTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let channelId: String

    @State private var model = FeedModel()
    @State private var page: YouTubeChannelPage?
    @State private var isSubscribed = false
    @State private var selectedTab: String?
    @State private var isLoading = true
    @State private var featured: YouTubeVideo?
    @State private var isFeaturedPinned = false
    @State private var avatar: String?
    @State private var isSearching = false
    @Namespace private var searchMorph

    private static let shownTabs: Set<String> = ["videos", "playlists", "posts", "community"]
    private var tabs: [YouTubeChannelTab] {
        page?.tabs.filter { tab in
            tab.browseId != nil && Self.tabName(tab).map { Self.shownTabs.contains($0) } == true
        } ?? []
    }

    /// A tab's params hold its English name in any app language: a field tag, the length, then the name.
    private static func tabName(_ tab: YouTubeChannelTab) -> String? {
        guard var text = tab.params?.removingPercentEncoding else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: text).map({ [UInt8]($0) }), bytes.count > 2, bytes.count >= 2 + Int(bytes[1]) else { return nil }
        return String(decoding: bytes[2..<(2 + Int(bytes[1]))], as: UTF8.self)
    }

    /// SwiftyTube searches the whole header in a random order, so it can return the banner as the
    /// avatar. Old-style headers don't have this key and keep SwiftyTube's answer.
    private static func avatarURL(in json: [String: Any]) -> String? {
        let avatar = JSON.first("decoratedAvatarViewModel", in: json["header"])
        let url = (JSON.first("sources", in: avatar) as? [[String: Any]])?.last?["url"] as? String
        // YouTube's largest is 160 pixels, which is blurry at this size. The address sets the size.
        return url?.replacingOccurrences(of: "=s160-", with: "=s400-")
    }

    var body: some View {
        GeometryReader { geometry in
            if isSearching {
                ChannelSearchContent(channelId: channelId, channelTitle: page?.channel?.title ?? "", morph: searchMorph) {
                    withAnimation(.snappy) { isSearching = false }
                }
                .transition(.opacity)
            } else {
                content(topInset: geometry.safeAreaInsets.top)
                    .transition(.opacity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    private func content(topInset: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if page == nil, isLoading {
                    loadingHeader
                } else {
                    header(topInset: topInset)
                }
                if let featured {
                    SectionTitle(title: isFeaturedPinned ? "Pinned Video" : "Latest Video")
                    VideoButton(video: featured)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.bottom, Layout.rowPadding)
                }
                if tabs.count > 1 {
                    FilterChips(titles: tabs.map(\.title), selected: selectedTab, onTap: select)
                }
                if model.items.isEmpty, model.isLoading || isLoading {
                    LoadingRows(kind: .compact)
                }
                FeedRows(model: model, isCompact: true)
                if let description = page?.channel?.description, !description.isEmpty {
                    SectionTitle(title: "About")
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.bottom, Layout.sectionGap)
                }
            }
        }
        .detailBarTitle(page?.channel?.title ?? "")
    }

    /// Stands in for the whole header, so the real buttons only ever appear in their final place.
    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: Layout.menuRowSpacing) {
            ShimmerBlock(width: Layout.avatarLarge, height: Layout.avatarLarge, radius: Layout.avatarLarge / 2)
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                ShimmerBlock(width: 90, height: 13)
                ShimmerBlock(width: 160, height: 22)
                ShimmerBlock(width: 110, height: 15)
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, ChannelBanner.contentInset)
        .padding(.bottom, Layout.screenPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmerClock()
        .accessibilityHidden(true)
    }

    private func header(topInset: CGFloat) -> some View {
        let channel = page?.channel
        let banner = page?.bannerURL
        let avatarURL = avatar ?? channel?.thumbnailURL
        return DetailHeaderCard(meta: channel?.handle ?? "Channel", title: channel?.title ?? "", artSize: Layout.avatarLarge) {
            CoverImage(url: avatarURL)
                .clipShape(.circle)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
        } secondary: {
            if let subscribers = channel?.subscriberCountText {
                Text(subscribers)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } buttons: {
            SubscribeButton(channelId: channelId, isSubscribed: isSubscribed, isLarge: true) { isSubscribed = $0 }
            Button {
                searchTaps += 1
                Task {
                    try? await Task.sleep(for: .seconds(reduceMotion ? 0 : 0.34))
                    withAnimation(.snappy) { isSearching = true }
                }
            } label: {
                HeaderRoundIcon(systemImage: "magnifyingglass", motion: .lensZoom, trigger: searchTaps)
                    .matchedGeometryEffect(id: ChannelSearchContent.barId, in: searchMorph)
            }
            .accessibilityLabel("Search This Channel")
        }
        .padding(.top, banner == nil ? Layout.screenPadding : ChannelBanner.contentInset)
        .padding(.bottom, Layout.screenPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                BlurredArtworkBackdrop(url: banner ?? avatarURL)
                if let banner {
                    ChannelBanner(url: banner, topInset: topInset)
                }
            }
        }
    }

    private func select(_ title: String) {
        guard let tab = tabs.first(where: { $0.title == title }) else { return }
        Task { await show(tab) }
    }

    /// The card above the filters already shows one video, so the list leaves it out.
    private func show(_ tab: YouTubeChannelTab) async {
        guard let id = tab.browseId else { return }
        selectedTab = tab.title
        await model.load(.browse(id, params: tab.params), keepChips: true)
        if featured == nil, var latest = model.rowVideos.first {
            latest.channelAvatarURL = nil
            featured = latest
        }
        if let featuredId = featured?.videoId, let item = model.items.first(where: { $0.id == featuredId }) {
            model.remove(item)
        }
    }

    /// Opens on Videos, because a channel's Home tab repeats the other tabs in rows.
    private func load() async {
        defer { isLoading = false }
        guard page == nil, let json = try? await InnerTubeClient.wooftube.browse(browseId: channelId) else { return }
        page = await offMain { YouTubeChannelParser.channelPage(in: json) }
        avatar = Self.avatarURL(in: json)
        let (subscribed, trailer) = await offMain {
            (JSON.first("subscribed", in: json) as? Bool == true, JSON.first("channelVideoPlayerRenderer", in: json) as? [String: Any])
        }
        isSubscribed = subscribed || Subscriptions.shared.ids.contains(channelId)
        if let player = trailer, let id = player["videoId"] as? String {
            featured = YouTubeVideo(
                videoId: id,
                title: JSON.text(player["title"]) ?? "",
                channelTitle: page?.channel?.title,
                channelId: channelId,
                viewCountText: JSON.text(player["viewCountText"]),
                publishedTimeText: JSON.text(player["publishedTimeText"])
            )
            isFeaturedPinned = true
        }
        if let tab = tabs.first(where: { Self.tabName($0) == "videos" }) ?? tabs.first {
            await show(tab)
        }
    }
}
