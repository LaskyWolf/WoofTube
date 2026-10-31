import AVFoundation
import Libmpv
import Metal
import SwiftUI

/// mpv's option order comes from Woof Music's PlayerController.
/// mpv calls can block for seconds while a stream opens, so they all run on `queue`.
/// The UI only ever touches the published values, which change on the main thread.
final class MpvPlayer: ObservableObject {
    /// The playback position, apart from the player: only the views that show it redraw as it ticks.
    let clock = PlayerClock()
    var time: Double { clock.time }
    @Published private(set) var speed = 1.0
    /// False until the new video draws its first frame. The layer keeps the old frame until then.
    @Published private(set) var isVideoReady = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = false
    @Published private(set) var errorText: String?
    @Published private(set) var recentLog: [String] = []

    let videoLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.framebufferOnly = true
        return layer
    }()
    /// The shape of the surface mpv draws on. It never changes after mpv starts,
    /// so rotating only moves the layer and doesn't restart the video output.
    let surfaceAspect: CGFloat
    /// Called on the main thread when a video plays to its end.
    var onEnded: (() -> Void)?

    private let queue = DispatchQueue(label: "com.laskywolf.wooftube.mpv")
    private var mpv: OpaquePointer?
    private var pendingLoad: (url: String, start: Double)?
    private var hasSurface = false
    private var videoEnabled = true
    private var wasPlayingBeforeInterruption = false
    private var observers: [Any] = []

    private static let logLimit = 100
    private static let ticksPerSecond = 4.0

    init(surfaceAspect: CGFloat = 16 / 9) {
        self.surfaceAspect = surfaceAspect
        observeAudioSession()
        queue.async { [weak self] in self?.startMpv() }
    }

    /// Starts once the video view has a size, because mpv sizes its surface from the layer.
    func load(url: String, start: Double = 0) {
        errorText = nil
        isBuffering = true
        pendingLoad = (url, start)
        startIfReady()
    }

    func surfaceIsReady() {
        guard !hasSurface else { return }
        hasSurface = true
        queue.async { [weak self] in self?.startVideoOutput() }
        startIfReady()
    }

    /// Off while nothing shows the video, such as in the background or the mini player.
    func setVideoEnabled(_ enabled: Bool) {
        guard enabled != videoEnabled else { return }
        videoEnabled = enabled
        setProperty("vid", enabled ? "auto" : "no")
    }

    func togglePause() {
        setPaused(!isPaused)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        setProperty("pause", paused ? "yes" : "no")
    }

    func seek(to seconds: Double) {
        clock.time = seconds
        isBuffering = true
        command(["seek", String(seconds), "absolute"])
    }

    func skip(by seconds: Double) {
        seek(to: min(max(time + seconds, 0), duration))
    }

    func stop() {
        pendingLoad = nil
        clock.time = 0
        duration = 0
        isBuffering = false
        command(["stop"])
    }

    /// Silences the old video as soon as the next one is picked.
    func prepareForNewVideo() {
        stop()
        isVideoReady = false
        isBuffering = true
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        setProperty("speed", String(speed))
    }

    /// Doubles the speed while the video is held down, without changing the chosen speed.
    func setBoosted(_ boosted: Bool) {
        setProperty("speed", String(boosted ? 2 : speed))
    }

    /// What mpv is doing right now, for the Diagnostics screen in Settings.
    func diagnostics() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let lines = ["aid", "ao", "audio-codec-name", "audio-params/format", "mute", "volume", "hwdec-current", "video-params/h", "demuxer-cache-duration", "paused-for-cache"].map { name -> String in
                    guard let mpv, let value = mpv_get_property_string(mpv, name) else { return "\(name): none" }
                    defer { mpv_free(value) }
                    return "\(name): \(String(cString: value))"
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    private func startMpv() {
        guard let mpv = mpv_create() else {
            publish { $0.errorText = "mpv could not start" }
            return
        }
        setenv("MVK_CONFIG_LOG_LEVEL", "1", 1)
        mpv_request_log_messages(mpv, "warn")
        mpv_set_option_string(mpv, "vo", "null")
        mpv_set_option_string(mpv, "vid", "no")
        mpv_set_option_string(mpv, "force-window", "no")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "audio-exclusive", "yes")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "120")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "200M")

        let status = mpv_initialize(mpv)
        guard status >= 0 else {
            let message = String(cString: mpv_error_string(status))
            publish { $0.errorText = "mpv could not start: \(message)" }
            mpv_destroy(mpv)
            return
        }

        if let certificates = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            mpv_set_property_string(mpv, "tls-ca-file", certificates)
        }
        mpv_set_property_string(mpv, "user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 3, "paused-for-cache", MPV_FORMAT_FLAG)
        self.mpv = mpv

        Thread { [weak self] in
            Self.runEvents(mpv, player: self)
        }.start()
    }

    private func startVideoOutput() {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "vo", "null")
        mpv_set_property_string(mpv, "vo", "gpu-next")
        mpv_set_property_string(mpv, "gpu-api", "vulkan")
        mpv_set_property_string(mpv, "gpu-context", "moltenvk")
        var window = unsafeBitCast(videoLayer, to: Int64.self)
        mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &window)
        if videoEnabled {
            mpv_set_property_string(mpv, "vid", "auto")
        }
    }

    private func startIfReady() {
        guard hasSurface, let load = pendingLoad else { return }
        pendingLoad = nil
        isPaused = false
        queue.async { [self] in
            activateAudioSession()
            guard let mpv else { return }
            mpv_set_property_string(mpv, "pause", "no")
            let arguments = load.start > 0
                ? ["loadfile", load.url, "replace", "-1", "start=\(load.start)"]
                : ["loadfile", load.url, "replace"]
            _ = arguments.withUnsafeCArg { mpv_command(mpv, $0) }
        }
    }

    func setProperty(_ name: String, _ value: String) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, name, value)
        }
    }

    private func command(_ arguments: [String]) {
        queue.async { [self] in
            guard let mpv else { return }
            _ = arguments.withUnsafeCArg { mpv_command(mpv, $0) }
        }
    }

    private func publish(_ change: @escaping (MpvPlayer) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { change(self) }
        }
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
    }

    /// A call, Siri or another app takes the audio away. Without this, mpv keeps
    /// playing into a dead audio output and the video runs on in silence.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                self?.handleInterruption(note)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                self?.restoreAudio()
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                self?.handleRouteChange(note)
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.queue.async { self?.activateAudioSession() }
            }
        ]
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = !isPaused && duration > 0
            if wasPlayingBeforeInterruption { setPaused(true) }
        case .ended:
            restoreAudio()
            if wasPlayingBeforeInterruption { setPaused(false) }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    /// Unplugging headphones pauses, like every Apple player. Other route changes rebuild the output.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              duration > 0 else { return }
        switch reason {
        case .oldDeviceUnavailable:
            setPaused(true)
            restoreAudio()
        case .newDeviceAvailable:
            restoreAudio()
        default:
            break
        }
    }

    private func restoreAudio() {
        queue.async { [self] in activateAudioSession() }
        command(["ao-reload"])
    }

    // MARK: - Events

    private static func runEvents(_ mpv: OpaquePointer, player: MpvPlayer?) {
        weak var player = player
        var lastTick = -1
        while true {
            guard let event = mpv_wait_event(mpv, 1) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_LOG_MESSAGE:
                guard let message = event.pointee.data?.load(as: mpv_event_log_message.self),
                      let text = message.text, let prefix = message.prefix else { continue }
                let line = "[\(String(cString: prefix))] \(String(cString: text))".trimmingCharacters(in: .whitespacesAndNewlines)
                player?.publish { $0.recentLog = Array(($0.recentLog + [line]).suffix(logLimit)) }
            case MPV_EVENT_PLAYBACK_RESTART:
                player?.publish {
                    $0.isBuffering = false
                    $0.isVideoReady = true
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.pointee.data?.load(as: mpv_event_property.self),
                      let namePointer = property.name else { continue }
                let name = String(cString: namePointer)
                if property.format == MPV_FORMAT_FLAG {
                    let isOn = property.data?.load(as: Int32.self) != 0
                    if name == "pause" {
                        player?.publish { $0.isPaused = isOn }
                    } else {
                        player?.publish { $0.isBuffering = isOn }
                    }
                } else if property.format == MPV_FORMAT_DOUBLE, let value = property.data?.load(as: Double.self) {
                    if name == "duration" {
                        player?.publish { $0.duration = value }
                    } else if Int(value * ticksPerSecond) != lastTick {
                        lastTick = Int(value * ticksPerSecond)
                        player?.publish { $0.clock.time = value }
                    }
                }
            case MPV_EVENT_END_FILE:
                guard let end = event.pointee.data?.load(as: mpv_event_end_file.self) else { continue }
                if end.reason == MPV_END_FILE_REASON_EOF {
                    player?.publish { $0.onEnded?() }
                }
                guard end.reason == MPV_END_FILE_REASON_ERROR else { continue }
                let message = String(cString: mpv_error_string(end.error))
                player?.publish {
                    $0.errorText = "Playback failed: \(message)"
                    $0.isBuffering = false
                }
            default:
                break
            }
        }
    }
}

extension Array where Element == String {
    func withUnsafeCArg<T>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> T) -> T {
        let cstrings = map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        var pointers = cstrings.map { UnsafePointer($0) } + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }
}

final class PlayerClock: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
}

struct MpvVideoView: UIViewRepresentable {
    let player: MpvPlayer

    func makeUIView(context: Context) -> MpvVideoUIView {
        MpvVideoUIView(player: player)
    }

    func updateUIView(_ view: MpvVideoUIView, context: Context) {}
}

final class MpvVideoUIView: UIView {
    private let player: MpvPlayer

    init(player: MpvPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The drawable keeps the screen's full resolution, and `contentsScale` keeps
    /// bounds × scale equal to it, so MoltenVK never sees a size change.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let aspect = player.surfaceAspect
        let videoLayer = player.videoLayer
        let longSide = max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height)
        let drawable = aspect >= 1
            ? CGSize(width: longSide, height: longSide / aspect)
            : CGSize(width: longSide * aspect, height: longSide)
        let frame = AVMakeRect(aspectRatio: drawable, insideRect: bounds)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if videoLayer.superlayer !== layer {
            layer.addSublayer(videoLayer)
        }
        videoLayer.frame = frame
        videoLayer.contentsScale = drawable.width / frame.width
        if videoLayer.drawableSize != drawable {
            videoLayer.drawableSize = drawable
        }
        CATransaction.commit()
        player.surfaceIsReady()
    }
}
