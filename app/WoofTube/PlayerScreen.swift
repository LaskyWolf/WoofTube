import AVKit
import SwiftUI
import SwiftyTube

/// The floating card above the tabs, for a video or a Short. It can be flicked off the side, leaving a small handle.
struct PlayerOverlay: View {
    static let zoomSource = "player"

    let zoom: Namespace.ID
    @EnvironmentObject private var router: Router
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
    /// Keeps the miniplayer above the tab bar, which sits outside this view's safe area.
    private static let tabBarHeight: CGFloat = 64
    private static let handleSize = CGSize(width: 44, height: 72)

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
            y: isMiniTop ? insets.top + Self.miniMargin : screen.height - miniCardHeight - insets.bottom - Self.tabBarHeight - Self.miniMargin
        )
        let hiddenX = isMiniLeading ? -miniCardWidth - Self.miniMargin : screen.width + Self.miniMargin

        return ZStack(alignment: .topLeading) {
            card(origin: mini, screen: screen)
                .offset(x: isDocked ? hiddenX : mini.x + dragOffset.width, y: mini.y + dragOffset.height)
            if isDocked {
                handle
                    .offset(
                        // Part of it stays off screen, so it reads as attached to the edge.
                        x: isMiniLeading ? -Layout.chipSpacing : screen.width - Self.handleSize.width + Layout.chipSpacing,
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
            Color.clear.glassEffect(.regular, in: shape)

            MpvVideoView(player: miniPlayerObject, isActive: isShort ? !router.isShortsPageOnScreen : !router.isWatchPageOnScreen)
                .id(isShort)
                .overlay { VideoPoster(player: miniPlayerObject, video: miniVideo) }
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

            CardEdgeProgress(clock: miniPlayerObject.clock, duration: miniPlayerObject.duration, radius: Self.cardRadius)
        }
        .frame(width: miniCardWidth, height: miniCardHeight)
        .matchedTransitionSource(id: Self.zoomSource, in: zoom) { source in
            source.clipShape(.rect(cornerRadius: Self.cardRadius))
        }
    }

    private var handle: some View {
        Button("Show Video", systemImage: isMiniLeading ? "chevron.right" : "chevron.left") {
            isDocked = false
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .frame(width: Self.handleSize.width, height: Self.handleSize.height)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
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

/// The video page. It opens with the system zoom from the floating card, which also
/// gives it the system's swipe down to close.
struct WatchPage: View {
    @EnvironmentObject private var router: Router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsComments = false
    @State private var pullDistance: CGFloat = 0

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
        .ignoresSafeArea(edges: isFullscreen ? .all : [])
        .background(alignment: .top) {
            if isFullscreen {
                Color.black.ignoresSafeArea()
            } else {
                ZStack(alignment: .top) {
                    Color(.systemBackground)
                    AmbientBackdrop(
                        clock: router.player.clock,
                        poster: router.current.map { $0.thumbnailURL ?? "https://i.ytimg.com/vi/\($0.videoId)/hqdefault.jpg" },
                        storyboard: router.storyboard
                    )
                }
                .ignoresSafeArea()
            }
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
    }

    private var video: some View {
        ZStack {
            MpvVideoView(player: router.player, isActive: router.isWatchPageOnScreen)
                .overlay { VideoPoster(player: router.player, video: router.current) }
                .background(.black)
                .allowsHitTesting(false)
            CaptionOverlay(clock: router.player.clock, cues: router.captionCues, isFullscreen: isFullscreen)
                .frame(maxHeight: .infinity, alignment: .bottom)
            PlayerControls(player: router.player, sleepTimer: router.sleepTimer, isFullscreen: isFullscreen)
        }
        .frame(maxWidth: .infinity, maxHeight: isFullscreen ? .infinity : nil)
        .aspectRatio(isFullscreen ? nil : 16 / 9, contentMode: .fit)
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
                onClose()
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { distance.wrappedValue = 0 }
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
/// and fading into the page. The frames come from the storyboard, because reading them from
/// the Metal video layer would cost far more.
private struct AmbientBackdrop: View {
    @ObservedObject var clock: PlayerClock
    let poster: String?
    let storyboard: Storyboard?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: UIImage?

    private static let height: CGFloat = 560
    /// Reaches under the status bar and fills the pull-down overscroll.
    private static let overflow: CGFloat = 300
    /// Seconds between changes of light. A slow pace keeps it calm and easy on the battery.
    private static let refresh = 8.0

    private var moment: Double { (clock.time / Self.refresh).rounded(.down) * Self.refresh }

    var body: some View {
        ZStack {
            if let frame {
                Image(uiImage: frame).resizable().scaledToFill().transition(.opacity).id(frame)
            } else {
                CachedImage(url: poster)
            }
        }
        .frame(height: Self.height + Self.overflow)
        .frame(maxWidth: .infinity)
        .clipped()
        .blur(radius: 50, opaque: true)
        .saturation(1.4)
        .opacity(0.65)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .padding(.top, -Self.overflow)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: poster) { frame = nil }
        .task(id: "\(poster ?? "")|\(moment)|\(storyboard?.urlTemplate ?? "")") { await loadFrame() }
    }

    private func loadFrame() async {
        guard !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled, let storyboard else { return }
        let spot = storyboard.frame(at: moment)
        guard let url = spot.url?.absoluteString else { return }
        var image = ImageStore.image(for: url)
        if image == nil { image = try? await ImageStore.load(url) }
        guard !Task.isCancelled, let sheet = image?.cgImage else { return }
        let size = storyboard.frameSize
        let area = CGRect(x: size.width * CGFloat(spot.column), y: size.height * CGFloat(spot.row), width: size.width, height: size.height)
        guard let cropped = sheet.cropping(to: area) else { return }
        withAnimation(.easeInOut(duration: 1.5)) { frame = UIImage(cgImage: cropped) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0), in: .circle)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.85)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
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
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((_ translation: CGSize, _ predicted: CGSize) -> Void)?
    /// When false the drag is left to whatever sits behind, like the system's swipe to close.
    var isDragEnabled = true

    private static let holdDuration = 0.35
    /// How far ahead a flick counts, in seconds of its speed.
    private static let flickSeconds: CGFloat = 0.2

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
        if onDragChanged != nil {
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
            pan.delegate = coordinator
            view.addGestureRecognizer(pan)
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

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            let move = recognizer.translation(in: nil)
            let speed = recognizer.velocity(in: nil)
            let translation = CGSize(width: move.x, height: move.y)
            switch recognizer.state {
            case .changed:
                parent.onDragChanged?(translation)
            case .ended, .cancelled:
                let predicted = CGSize(
                    width: move.x + speed.x * PlayerTouchSurface.flickSeconds,
                    height: move.y + speed.y * PlayerTouchSurface.flickSeconds
                )
                parent.onDragEnded?(translation, predicted)
            default:
                break
            }
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
                Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                    player.togglePause()
                }
                Button("Close", systemImage: "xmark", action: onClose)
            }
            .labelStyle(MiniGlyphLabelStyle())
            .buttonStyle(.plain)
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
            .frame(width: 40, height: 44)
            .contentShape(.rect)
    }
}

/// The straight part of the card's bottom edge, between its two corners.
private struct CardBottomEdge: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        return path
    }
}

/// Playback progress in a straight line on the card's border. Its own view, so only the line redraws as the time ticks.
private struct CardEdgeProgress: View {
    @ObservedObject var clock: PlayerClock
    let duration: Double
    let radius: CGFloat
    private static let lineWidth: CGFloat = 3

    var body: some View {
        // Half the line's width in from the edge, so its outer side lies exactly on the border.
        let edge = CardBottomEdge(radius: radius)
        ZStack {
            edge.stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
            edge.trim(from: 0, to: min(clock.time / max(duration, 1), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
        }
        .padding(Self.lineWidth / 2)
        .allowsHitTesting(false)
    }
}

/// Woof Music's ProgressBar: a thin track that thickens while scrubbing.
struct ProgressBar: View {
    @Binding var progress: Double
    /// Where chapters start, from 0 to 1. The bar splits at each one.
    var marks: [Double] = []
    /// Shows the bar as thick as while scrubbing, for scrubbing that happens elsewhere.
    var isEmphasized = false
    let onEditingChanged: (Bool) -> Void
    @GestureState private var isScrubbing = false
    @State private var didStartEditing = false

    var body: some View {
        GeometryReader { geometry in
            let isThick = isScrubbing || isEmphasized
            let inset: CGFloat = isThick ? 0 : Layout.chipSpacing
            let trackWidth = max(0, geometry.size.width - inset * 2)
            let height: CGFloat = isThick ? 12 : (marks.isEmpty ? 5 : 7)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3)).frame(height: height)
                Rectangle().fill(.tint).frame(width: trackWidth * min(max(progress, 0), 1), height: height)
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
        AsyncImage(url: frame.url) { image in
            image
                .resizable()
                .frame(width: Self.width * CGFloat(storyboard.columns), height: height * CGFloat(storyboard.rows))
                .offset(x: -Self.width * CGFloat(frame.column), y: -height * CGFloat(frame.row))
                .frame(width: Self.width, height: height, alignment: .topLeading)
        } placeholder: {
            Color.black.opacity(0.4)
        }
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
    let onScrubbing: (Bool) -> Void
    @State private var position = 0.0
    @State private var isEditing = false

    var body: some View {
        let total = max(duration, 1)
        let shownTime = isEditing ? position * total : clock.time
        let chapter = chapters.last { $0.start <= shownTime }
        VStack(spacing: 0) {
            if isEditing, let storyboard {
                StoryboardPreview(storyboard: storyboard, seconds: position * total)
            }
            HStack {
                Text(shownTime.clockText)
                if let chapter {
                    chapterMenu(current: chapter)
                }
                Spacer(minLength: 0)
                Text(duration.clockText)
                RoutePicker().frame(width: 44, height: 44)
                Button(isFullscreen ? "Exit Full Screen" : "Full Screen", systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    Orientation.setFullscreen(!isFullscreen)
                }
                .buttonStyle(PlayerPressStyle())
                .labelStyle(PlayerGlyphLabelStyle(size: 15))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(.leading, Layout.chipSpacing)

            ProgressBar(
                progress: Binding(get: { isEditing ? position : clock.time / total }, set: { position = $0 }),
                marks: chapters.dropFirst().map { $0.start / total },
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
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel("Chapter: \(current.title)")
    }
}

private struct SeekHint {
    let id = UUID()
    let isLeading: Bool
}

private struct PlayerControls: View {
    private static let skipSeconds = 10.0
    private static let exitFullscreenDistance: CGFloat = 60

    @ObservedObject var player: MpvPlayer
    @ObservedObject var sleepTimer: SleepTimer
    let isFullscreen: Bool

    @EnvironmentObject private var router: Router
    @State private var showsControls = true
    @State private var showsSleepTimer = false
    @State private var hideTask: Task<Void, Never>?
    @State private var seekHint: SeekHint?

    private var isLoading: Bool {
        router.loadError == nil && (router.streamSummary == nil || player.isBuffering)
    }

    var body: some View {
        ZStack {
            PlayerTouchSurface(
                onTap: {
                    withAnimation(.easeOut(duration: 0.15)) { showsControls.toggle() }
                    scheduleHide()
                },
                onDoubleTap: { isLeading in
                    player.skip(by: isLeading ? -Self.skipSeconds : Self.skipSeconds)
                    seekHint = SeekHint(isLeading: isLeading)
                },
                onDragChanged: { _ in },
                onDragEnded: { translation, _ in
                    if translation.height > Self.exitFullscreenDistance { Orientation.setFullscreen(false) }
                },
                isDragEnabled: isFullscreen
            )

            if isLoading {
                ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
            }
            if showsControls {
                controls.transition(.opacity)
            }
            if let seekHint {
                Image(systemName: seekHint.isLeading ? "gobackward.10" : "goforward.10")
                    .font(.system(size: 28, weight: .semibold))
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
        .onAppear(perform: scheduleHide)
        .onChange(of: player.isPaused) { scheduleHide() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The handle only shows outside full screen.
                if isFullscreen {
                    Button("Close", systemImage: "chevron.down") { router.isExpanded = false }
                }
                Spacer()
                PictureInPictureButton(model: router.pictureInPicture)
                if sleepTimer.isActive {
                    Button("Sleep Timer", systemImage: "moon.zzz.fill") { showsSleepTimer = true }
                }
                if player.speed != 1 {
                    speedMenu
                }
                captionsMenu
                optionsMenu
            }
            Spacer(minLength: 0)
            if !isLoading {
                HStack(spacing: 24) {
                    Button("Back 10 Seconds", systemImage: "gobackward.10") { skip(-Self.skipSeconds) }
                        .labelStyle(PlayerGlyphLabelStyle(size: 24))
                    Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                        player.togglePause()
                    }
                    .labelStyle(PlayerGlyphLabelStyle(size: 34))
                    Button("Forward 10 Seconds", systemImage: "goforward.10") { skip(Self.skipSeconds) }
                        .labelStyle(PlayerGlyphLabelStyle(size: 24))
                }
            }
            Spacer(minLength: 0)
            PlayerProgress(clock: player.clock, player: player, duration: player.duration, isFullscreen: isFullscreen, storyboard: router.storyboard, chapters: router.details?.chapters ?? []) { scrubbing in
                if scrubbing {
                    hideTask?.cancel()
                } else {
                    scheduleHide()
                }
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
        }
    }

    /// Woof Music's player handle, on the video. It stays behind the buttons in the same row.
    private var closeHandle: some View {
        Button {
            router.isExpanded = false
        } label: {
            Capsule()
                .fill(.white.opacity(0.7))
                .frame(width: 36, height: 5)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .frame(width: 80, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Video")
    }

    private func skip(_ seconds: Double) {
        player.skip(by: seconds)
        scheduleHide()
    }

    /// Woof Music's speed chip: accent filled away from 1x.
    private var speedMenu: some View {
        Menu {
            speedPicker
        } label: {
            Text(player.speed.speedText)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    if player.speed == 1 {
                        Capsule().fill(.white.opacity(0.15))
                    } else {
                        Capsule().fill(.tint)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Playback speed, \(player.speed.speedText)")
    }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
            ForEach(Router.speeds, id: \.self) { speed in
                Text(speed == 1 ? "Normal" : speed.speedText).tag(speed)
            }
        }
    }

    @ViewBuilder
    private var captionsMenu: some View {
        if !router.captions.isEmpty {
            Menu {
                Button("Off") { router.selectCaption(nil) }
                ForEach(router.captions, id: \.languageCode) { track in
                    Button {
                        router.selectCaption(track)
                    } label: {
                        if router.selectedCaption == track.languageCode {
                            Label(track.name ?? track.languageCode ?? "Unknown", systemImage: "checkmark")
                        } else {
                            Text(track.name ?? track.languageCode ?? "Unknown")
                        }
                    }
                }
                translateButton
            } label: {
                Label("Captions", systemImage: router.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill")
            }
        }
    }

    /// YouTube translates any track, so this offers the phone's language when it differs.
    @ViewBuilder
    private var translateButton: some View {
        let language = Locale.current.language.languageCode?.identifier
        if let track = router.captions.first(where: { $0.languageCode == router.selectedCaption }),
           let language, track.languageCode != language,
           let name = Locale.current.localizedString(forLanguageCode: language) {
            Button {
                router.selectCaption(track, translated: !router.isCaptionTranslated)
            } label: {
                if router.isCaptionTranslated {
                    Label("Translate to \(name)", systemImage: "checkmark")
                } else {
                    Label("Translate to \(name)", systemImage: "translate")
                }
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            if router.audioTracks.count > 1 {
                Menu("Audio Track") {
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
            Picker("Quality", selection: Binding(get: { router.maxHeight }, set: { router.changeQuality(to: $0) })) {
                ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
            }
            .pickerStyle(.menu)
            Menu("Speed") { speedPicker }
            Toggle("Autoplay", isOn: $router.autoplay)
            Button(sleepTimer.isActive ? "Sleep Timer · On" : "Sleep Timer…", systemImage: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz") {
                showsSleepTimer = true
            }
            if let summary = router.streamSummary {
                Section(summary) {}
            }
        } label: {
            Label("Options", systemImage: "ellipsis")
        }
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

private struct PictureInPictureButton: View {
    @ObservedObject var model: PictureInPicture

    var body: some View {
        if model.isPossible || model.isActive {
            Button("Picture in Picture", systemImage: model.isActive ? "pip.exit" : "pip.enter", action: model.toggle)
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
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var showsDescription = false
    @State private var showsPlaylists = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            infoHeader
            if let failure = router.loadError ?? router.player.errorText {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let details = router.details {
                descriptionCard(details)
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
        .sheet(isPresented: $showsPlaylists) {
            if let video = router.current {
                PlaylistPickerSheet(video: video)
            }
        }
    }

    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            if let video = router.current {
                Text(video.title)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details = router.details {
                channelRow(details)
                actions(details)
            } else if !router.detailsUnavailable {
                HStack(spacing: Layout.rowSpacing) {
                    ShimmerBlock(width: Layout.thumbSmall, height: Layout.thumbSmall, radius: Layout.thumbSmall / 2)
                    VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                        ShimmerBlock(width: 140, height: 14)
                        ShimmerBlock(width: 90, height: 12)
                    }
                }
                ShimmerBlock(width: 220, height: 38, radius: 19)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func channelLabel(_ details: WatchDetails) -> some View {
        HStack(spacing: Layout.rowSpacing) {
            if details.collaborators.count > 1 {
                AvatarStack(urls: details.collaborators.map(\.avatar), size: Layout.thumbSmall)
            } else {
                Avatar(url: details.channelAvatar, size: Layout.thumbSmall)
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
                                    router.openChannel(creator.channelId)
                                }
                                Button("Subscribe", systemImage: "bell") {
                                    router.run { _ = try await InnerTubeClient.wooftube.subscribe(channelId: creator.channelId) }
                                }
                                Button("Unsubscribe", systemImage: "bell.slash") {
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
                    .buttonStyle(.plain)
                } else {
                    Button {
                        router.openChannel(id)
                    } label: {
                        channelLabel(details)
                    }
                    .buttonStyle(.plain)
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
        return ScrollView(.horizontal, showsIndicators: false) {
            // Spacing 0 keeps the shapes apart instead of letting nearby glass merge.
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Button {
                            setLike(isLiked ? "INDIFFERENT" : "LIKE")
                        } label: {
                            likeLabel(
                                icon: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                                text: (isLiked ? details.likeCountLiked : details.likeCount) ?? "Like",
                                isActive: isLiked
                            )
                        }
                        .accessibilityLabel("Like")
                        Divider().frame(height: 18)
                        Button {
                            setLike(isDisliked ? "INDIFFERENT" : "DISLIKE")
                        } label: {
                            likeLabel(
                                icon: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                text: details.dislikeCount.map { ($0 + (isDisliked ? 1 : 0)).compactText },
                                isActive: isDisliked
                            )
                        }
                        .accessibilityLabel("Dislike")
                    }
                    .glassEffect(.regular, in: .capsule)
                    if let id = router.current?.videoId, let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                        ShareLink(item: url) {
                            HeaderRoundIcon(systemImage: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share")
                        Button {
                            toggleWatchLater(id, isSaved: details.isInWatchLater)
                        } label: {
                            HeaderRoundIcon(
                                systemImage: details.isInWatchLater ? "clock.fill" : "clock",
                                tint: details.isInWatchLater ? settings.accentColor : .primary
                            )
                        }
                        .accessibilityLabel(details.isInWatchLater ? "Remove from Watch Later" : "Save to Watch Later")
                        Button {
                            showsPlaylists = true
                        } label: {
                            HeaderRoundIcon(systemImage: "text.badge.plus")
                        }
                        .accessibilityLabel("Save to Playlist")
                        if let video = router.current {
                            let isSaved = downloads.isDownloaded(id)
                            let isSaving = downloads.active.contains { $0.id == id }
                            Button {
                                router.run { try await downloads.download(video, maxHeight: router.maxHeight) }
                            } label: {
                                if isSaving {
                                    ProgressView()
                                        .frame(width: 38, height: 38)
                                        .glassEffect(.regular, in: .circle)
                                } else {
                                    HeaderRoundIcon(systemImage: isSaved ? "checkmark" : "arrow.down")
                                }
                            }
                            .disabled(isSaved || isSaving)
                            .accessibilityLabel(isSaved ? "Downloaded" : isSaving ? "Downloading" : "Download")
                        }
                    }
                }
                .buttonStyle(ZoomPressStyle(scale: 0.92))
                .sensoryFeedback(.impact(weight: .light), trigger: details.likeStatus)
                .sensoryFeedback(.success, trigger: details.isInWatchLater) { _, saved in saved }
            }
        }
        // Scrolls right up to the screen's edges.
        .contentMargins(.horizontal, Layout.screenPadding, for: .scrollContent)
        .padding(.horizontal, -Layout.screenPadding)
        .scrollClipDisabled()
    }

    private func likeLabel(icon: String, text: String?, isActive: Bool) -> some View {
        HStack(spacing: Layout.rowPadding) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            if let text {
                Text(text).font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        // Reaches 44 pt, using the space around the capsule.
        .contentShape(Rectangle().inset(by: -3))
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
            .materialCard()
        }
        .buttonStyle(.plain)
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
                router.setDetails { $0.isInWatchLater = isSaved }
                router.actionMessage = error.localizedDescription
            }
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
                router.actionMessage = error.localizedDescription
            }
        }
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
                        Avatar(url: comment.avatar, size: 24)
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
        .buttonStyle(.plain)
        .disabled(details == nil)
    }
}

/// What plays next, apart from YouTube's suggestions below. A long playlist stays short until opened.
private struct QueueCard: View {
    @EnvironmentObject private var router: Router
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
                    .buttonStyle(RowPressStyle())
                    .videoMenu(video)
                }
            }
            if router.queue.count > Self.collapsedCount {
                Button(showsAll ? "Show Less" : "Show All") {
                    withAnimation(.snappy) { showsAll.toggle() }
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
    /// Woof Music's round icon, for the channel page's header.
    var isCompact = false
    let onChange: (Bool) -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button {
            toggle()
        } label: {
            if isCompact {
                HeaderRoundIcon(
                    systemImage: isSubscribed ? "person.fill.checkmark" : "person.badge.plus",
                    tint: isSubscribed ? settings.accentColor : .primary
                )
            } else {
                Text(isSubscribed ? "Subscribed" : "Subscribe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSubscribed ? Color.primary : Color.white)
                    .padding(.horizontal, Layout.screenPadding)
                    .frame(height: 38)
                    .background {
                        if isSubscribed {
                            Capsule().fill(Color.primary.opacity(0.1))
                        } else {
                            Capsule().fill(.tint)
                        }
                    }
                    .contentShape(.capsule)
            }
        }
        .buttonStyle(ZoomPressStyle(scale: 0.92))
        .accessibilityLabel(isSubscribed ? "Unsubscribe" : "Subscribe")
        .sensoryFeedback(.selection, trigger: isSubscribed)
    }

    private func toggle() {
        let target = !isSubscribed
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

/// Woof Music's artist page over the channel's banner, then the pinned or latest video,
/// then the channel's tabs as filters.
struct ChannelView: View {
    let channelId: String

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = FeedModel()
    @State private var page: YouTubeChannelPage?
    @State private var isSubscribed = false
    @State private var selectedTab: String?
    @State private var isLoading = true
    @State private var featured: YouTubeVideo?
    @State private var isFeaturedPinned = false
    @State private var avatar: String?

    private static let shownTabs: Set<String> = ["videos", "playlists", "posts", "community"]
    private static let avatarSize: CGFloat = 104

    private var tabs: [YouTubeChannelTab] {
        page?.tabs.filter { tab in
            tab.browseId != nil && Self.tabName(tab).map { Self.shownTabs.contains($0) } == true
        } ?? []
    }

    private var videos: [YouTubeVideo] {
        model.items.compactMap {
            if case .video(let video, _) = $0 { return video }
            return nil
        }
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
            content(topInset: geometry.safeAreaInsets.top)
        }
        .navigationTitle(page?.channel?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    private func content(topInset: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(topInset: topInset)
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
                    LoadingRows(isCompact: true)
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
    }

    private func header(topInset: CGFloat) -> some View {
        let channel = page?.channel
        let banner = page?.bannerURL
        let avatarURL = avatar ?? channel?.thumbnailURL
        return DetailHeaderCard(meta: channel?.handle ?? "Channel", title: channel?.title ?? "", artSize: Self.avatarSize) {
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
            SubscribeButton(channelId: channelId, isSubscribed: isSubscribed, isCompact: true) { isSubscribed = $0 }
            let all = (featured.map { [$0] } ?? []) + videos
            if !all.isEmpty {
                Button { router.playAll(all, shuffled: true) } label: {
                    HeaderRoundIcon(systemImage: "shuffle")
                }
                .accessibilityLabel("Shuffle")
                Button { router.playAll(all) } label: {
                    HeaderRoundIcon(systemImage: "play.fill", primary: settings.accentColor)
                }
                .accessibilityLabel("Play All")
            }
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
        if featured == nil, var latest = videos.first {
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
        page = YouTubeChannelParser.channelPage(in: json)
        avatar = Self.avatarURL(in: json)
        isSubscribed = JSON.first("subscribed", in: json) as? Bool == true || Subscriptions.shared.ids.contains(channelId)
        if let player = JSON.first("channelVideoPlayerRenderer", in: json) as? [String: Any], let id = player["videoId"] as? String {
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
