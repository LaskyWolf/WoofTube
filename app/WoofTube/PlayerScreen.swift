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
    @State private var showsComments = false

    private static let miniSize = CGSize(width: 192, height: 108)
    /// The title, pause and close strip under the mini video.
    private static let miniStripHeight: CGFloat = 44
    /// The card's material shows this far around the video.
    private static let miniInset = Layout.rowPadding
    private static var miniCardWidth: CGFloat { miniSize.width + miniInset * 2 }
    private static var miniCardHeight: CGFloat { miniInset + miniSize.height + miniStripHeight }
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
            x: isMiniLeading ? Self.miniMargin : screen.width - Self.miniCardWidth - Self.miniMargin,
            y: isMiniTop ? insets.top + Self.miniMargin : screen.height - Self.miniCardHeight - insets.bottom - Self.tabBarHeight - Self.miniMargin
        )
        // 0 is the full video page, 1 is the miniplayer.
        let progress = router.isExpanded ? min(max(dragOffset.height, 0) / (screen.height * 0.6), 1) : 1
        let miniVideo = CGPoint(x: mini.x + Self.miniInset, y: mini.y + Self.miniInset)
        let origin = router.isExpanded
            ? CGPoint(x: expanded.x + (miniVideo.x - expanded.x) * progress, y: expanded.y + (miniVideo.y - expanded.y) * progress)
            : CGPoint(x: miniVideo.x + dragOffset.width, y: miniVideo.y + dragOffset.height)
        let width = videoSize.width + (Self.miniSize.width - videoSize.width) * progress
        let scale = width / videoSize.width
        // The video's corners follow the card's, so the material stays the same width around them.
        let radius = progress * Layout.tileRadius / scale

        return ZStack(alignment: .topLeading) {
            page(topInset: insets.top, bottomInset: insets.bottom, videoHeight: videoSize.height, progress: progress)

            if !router.isExpanded {
                RoundedRectangle(cornerRadius: Layout.tileRadius + Self.miniInset, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                    .frame(width: Self.miniCardWidth, height: Self.miniCardHeight)
                    .offset(x: origin.x - Self.miniInset, y: origin.y - Self.miniInset)
            }

            MpvVideoView(player: router.player)
                .overlay { VideoPoster(player: router.player, video: router.current) }
                .frame(width: videoSize.width, height: videoSize.height)
                .background(.black)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)

            if router.isExpanded {
                PlayerControls(
                    player: router.player,
                    sleepTimer: router.sleepTimer,
                    isFullscreen: isFullscreen,
                    onDragChanged: { translation in
                        if !isFullscreen { dragOffset = translation }
                    },
                    onDragEnded: finishPageDrag
                )
                .frame(width: videoSize.width, height: videoSize.height)
                .background(alignment: .bottom) {
                    CaptionOverlay(clock: router.player.clock, cues: router.captionCues, isFullscreen: isFullscreen)
                }
                .opacity(1 - progress * 4)
                .offset(x: expanded.x, y: expanded.y)
            } else {
                MiniControls(
                    player: router.player,
                    videoAreaHeight: Self.miniInset + Self.miniSize.height,
                    onDragChanged: { value in dragOffset = value.translation },
                    onDragEnded: { value in finishMiniDrag(value, origin: mini, screen: screen) }
                )
                .frame(width: Self.miniCardWidth, height: Self.miniCardHeight)
                .offset(x: origin.x - Self.miniInset, y: origin.y - Self.miniInset)
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

    private func finishPageDrag(translation: CGSize, predicted: CGSize) {
        if isFullscreen {
            if translation.height > Self.exitFullscreenDistance {
                Orientation.setFullscreen(false)
            }
            return
        }
        if max(translation.height, predicted.height) > Self.collapseDistance {
            router.isExpanded = false
        }
        withAnimation(.snappy) { dragOffset = .zero }
    }

    /// Snaps to the corner the flick is heading for.
    private func finishMiniDrag(_ value: DragGesture.Value, origin: CGPoint, screen: CGSize) {
        let endX = origin.x + value.predictedEndTranslation.width + Self.miniCardWidth / 2
        let endY = origin.y + value.predictedEndTranslation.height + Self.miniCardHeight / 2
        withAnimation(.snappy) {
            isMiniLeading = endX < screen.width / 2
            isMiniTop = endY < screen.height / 2
            dragOffset = .zero
        }
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

/// Shown while the video is held down at double speed.
struct BoostPill: View {
    var body: some View {
        Label("2x", systemImage: "forward.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, Layout.rowSpacing)
            .padding(.vertical, Layout.rowPadding)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(.top, Layout.chipSpacing)
            .allowsHitTesting(false)
    }
}

/// UIKit gesture recognizers, because they settle tap, hold and drag on one view reliably.
struct PlayerTouchSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onBoost: (Bool) -> Void
    /// True for the leading half of the video.
    var onDoubleTap: ((Bool) -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((_ translation: CGSize, _ predicted: CGSize) -> Void)?

    private static let holdDuration = 0.35
    /// How far ahead a flick counts, in seconds of its speed.
    private static let flickSeconds: CGFloat = 0.2

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = Self.holdDuration
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        view.addGestureRecognizer(tap)
        if onDoubleTap != nil {
            let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }
        view.addGestureRecognizer(hold)
        if onDragChanged != nil {
            view.addGestureRecognizer(UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:))))
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: PlayerTouchSurface

        init(parent: PlayerTouchSurface) {
            self.parent = parent
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
            case .began: parent.onBoost(true)
            case .ended, .cancelled, .failed: parent.onBoost(false)
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
    let videoAreaHeight: CGFloat
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    @EnvironmentObject private var router: Router

    private static let shape = RoundedRectangle(cornerRadius: Layout.tileRadius + Layout.rowPadding, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: videoAreaHeight)
            HStack(spacing: 0) {
                Text(router.current?.title ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.leading, Layout.rowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                    player.togglePause()
                }
                Button("Close", systemImage: "xmark") { router.close() }
            }
            .labelStyle(MiniGlyphLabelStyle())
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                ProgressLine(clock: player.clock, duration: player.duration)
                    .clipShape(.capsule)
                    .padding([.horizontal, .bottom], Layout.rowPadding)
            }
        }
        .contentShape(Self.shape)
        .onTapGesture { router.isExpanded = true }
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged(onDragChanged)
                .onEnded(onDragEnded)
        )
        .clipShape(Self.shape)
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

/// Woof Music's bottom progress line. Its own view, so only the line redraws as playback advances.
private struct ProgressLine: View {
    @ObservedObject var clock: PlayerClock
    let duration: Double

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.tint)
                .frame(width: geometry.size.width * min(clock.time / max(duration, 1), 1), height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// Woof Music's ProgressBar: a thin track that thickens while scrubbing.
struct ProgressBar: View {
    @Binding var progress: Double
    let onEditingChanged: (Bool) -> Void
    @GestureState private var isScrubbing = false
    @State private var didStartEditing = false

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = isScrubbing ? 0 : Layout.chipSpacing
            let trackWidth = max(0, geometry.size.width - inset * 2)
            let height: CGFloat = isScrubbing ? 12 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: height)
                Capsule().fill(.tint).frame(width: trackWidth * min(max(progress, 0), 1), height: height)
            }
            .padding(.horizontal, inset)
            .animation(.easeInOut(duration: 0.2), value: isScrubbing)
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
    let onScrubbing: (Bool) -> Void
    @State private var position = 0.0
    @State private var isEditing = false

    var body: some View {
        let total = max(duration, 1)
        VStack(spacing: 0) {
            if isEditing, let storyboard {
                StoryboardPreview(storyboard: storyboard, seconds: position * total)
            }
            HStack {
                Text((isEditing ? position * total : clock.time).clockText)
                Spacer()
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
}

private struct SeekHint {
    let id = UUID()
    let isLeading: Bool
}

private struct PlayerControls: View {
    private static let skipSeconds = 10.0

    @ObservedObject var player: MpvPlayer
    @ObservedObject var sleepTimer: SleepTimer
    let isFullscreen: Bool
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (_ translation: CGSize, _ predicted: CGSize) -> Void

    @EnvironmentObject private var router: Router
    @State private var showsControls = true
    @State private var isBoosting = false
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
                onBoost: { boosting in
                    isBoosting = boosting
                    player.setBoosted(boosting)
                },
                onDoubleTap: { isLeading in
                    player.skip(by: isLeading ? -Self.skipSeconds : Self.skipSeconds)
                    seekHint = SeekHint(isLeading: isLeading)
                },
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )

            if isLoading {
                ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
            }
            if showsControls, !isBoosting {
                controls.transition(.opacity)
            }
            if isBoosting {
                BoostPill().frame(maxHeight: .infinity, alignment: .top)
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
                Button("Close", systemImage: "chevron.down") { router.isExpanded = false }
                Spacer()
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
            PlayerProgress(clock: player.clock, player: player, duration: player.duration, isFullscreen: isFullscreen, storyboard: router.storyboard) { scrubbing in
                if scrubbing {
                    hideTask?.cancel()
                } else {
                    scheduleHide()
                }
            }
        }
        .padding(.horizontal, Layout.cardSpacing)
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
                if !details.chapters.isEmpty {
                    chapters(details.chapters)
                }
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
            } else if !router.detailsUnavailable {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
        .padding(Layout.screenPadding)
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
                            router.run { try await PlaylistActions.add(id, to: YouTubeFeeds.watchLaterPlaylistId) }
                        } label: {
                            HeaderRoundIcon(systemImage: "clock")
                        }
                        .accessibilityLabel("Save to Watch Later")
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
            }
        }
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
        .contentShape(.rect)
    }

    private func chapters(_ chapters: [Chapter]) -> some View {
        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            Text("Chapters").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(chapters, id: \.self) { chapter in
                        Button {
                            router.player.seek(to: chapter.start)
                        } label: {
                            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                CoverImage(url: chapter.thumbnail)
                                    .frame(width: 160, height: 90)
                                    .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
                                Text(chapter.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(chapter.start.clockText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 160, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(RowPressStyle())
                    }
                }
            }
        }
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
        Button {
            toggle()
        } label: {
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
        .buttonStyle(ZoomPressStyle(scale: 0.92))
        .sensoryFeedback(.selection, trigger: isSubscribed)
    }

    private func toggle() {
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
}

/// Woof Music's artist page: header card over the blurred avatar, then the channel's tabs as filters.
struct ChannelView: View {
    let channelId: String

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = FeedModel()
    @State private var page: YouTubeChannelPage?
    @State private var isSubscribed = false
    @State private var selectedTab: String?
    @State private var isLoading = true

    private var tabs: [YouTubeChannelTab] {
        page?.tabs.filter { $0.browseId != nil && $0.params != nil } ?? []
    }

    private var videos: [YouTubeVideo] {
        model.items.compactMap {
            if case .video(let video, _) = $0 { return video }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if tabs.count > 1 {
                    FilterChips(titles: tabs.map(\.title), selected: selectedTab, onTap: select)
                }
                if model.items.isEmpty, model.isLoading || isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 48)
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
        .navigationTitle(page?.channel?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }

    private var header: some View {
        let channel = page?.channel
        return DetailHeaderCard(meta: channel?.handle ?? "Channel", title: channel?.title ?? "") {
            CoverImage(url: channel?.thumbnailURL).clipShape(.circle)
        } secondary: {
            if let subscribers = channel?.subscriberCountText {
                Text(subscribers)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } buttons: {
            SubscribeButton(channelId: channelId, isSubscribed: isSubscribed) { isSubscribed = $0 }
            if !videos.isEmpty {
                Button { router.playAll(videos, shuffled: true) } label: {
                    HeaderRoundIcon(systemImage: "shuffle")
                }
                .accessibilityLabel("Shuffle")
                Button { router.playAll(videos) } label: {
                    HeaderRoundIcon(systemImage: "play.fill", primary: settings.accentColor)
                }
                .accessibilityLabel("Play All")
            }
        }
        .padding(.vertical, Layout.screenPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: channel?.thumbnailURL)
        }
    }

    private func select(_ title: String) {
        guard let tab = tabs.first(where: { $0.title == title }), let id = tab.browseId else { return }
        selectedTab = title
        Task { await model.load(.browse(id, params: tab.params), keepChips: true) }
    }

    /// Opens on Videos, because a channel's Home tab repeats the other tabs in rows.
    private func load() async {
        defer { isLoading = false }
        guard page == nil, let json = try? await InnerTubeClient.wooftube.browse(browseId: channelId) else { return }
        page = YouTubeChannelParser.channelPage(in: json)
        isSubscribed = JSON.first("subscribed", in: json) as? Bool ?? false
        if let tab = tabs.first(where: { $0.title.localizedCaseInsensitiveContains("video") }) ?? tabs.first {
            select(tab.title)
        }
    }
}
