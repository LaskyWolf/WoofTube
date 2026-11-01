import AVFoundation
import CoreImage
import MPVKit
import SwiftUI

/// mpv's option order comes from Woof Music's PlayerController.
/// mpv calls can block for seconds while a stream opens, so they all run on `queue`.
/// The UI only ever touches the published values, which change on the main thread.
final class MpvPlayer: ObservableObject {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

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
    /// A live stream can't be sought: mpv never reports that such a seek finished.
    @Published var isLiveStream = false
    /// The length the feed gave, for the floating window until mpv knows it.
    var expectedDuration = 0.0
    private(set) var recentLog: [String] = []
    private var loadStarted: Date?

    /// mpv puts its frames here. It's the kind of layer Apple's Picture in Picture window can show.
    let videoLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        return layer
    }()
    /// Called on the main thread when a video plays to its end.
    var onEnded: (() -> Void)?
    private var loadedURL: String?
    private var hasEnded = false

    private let queue = DispatchQueue(label: "com.laskywolf.wooftube.mpv")
    private var mpv: OpaquePointer?
    private var videoEnabled = true
    private var decoderResets = 0
    private var wasPlayingBeforeInterruption = false
    private var observers: [Any] = []

    private static let logLimit = 100
    private static let frameContext = CIContext()
    private static let ticksPerSecond = 4.0
    /// Tries per video before leaving a failed picture alone, so it can't loop forever.
    private static let maxDecoderResets = 3

    init() {
        observeAudioSession()
        queue.async { [weak self] in self?.startMpv() }
    }

    func load(url: String, start: Double = 0) {
        loadedURL = url
        hasEnded = false
        loadStarted = Date()
        errorText = nil
        isBuffering = true
        isPaused = false
        queue.async { [self] in
            decoderResets = 0
            activateAudioSession()
            guard let mpv else { return }
            mpv_set_property_string(mpv, "pause", "no")
            let arguments = start > 0
                ? ["loadfile", url, "replace", "-1", "start=\(start)"]
                : ["loadfile", url, "replace"]
            _ = arguments.withUnsafeCArg { mpv_command(mpv, $0) }
        }
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
        if !paused, hasEnded, let loadedURL {
            load(url: loadedURL)
            return
        }
        isPaused = paused
        setProperty("pause", paused ? "yes" : "no")
    }

    func seek(to seconds: Double) {
        // An invalid time would crash whatever draws it.
        guard seconds.isFinite, !isLiveStream else { return }
        if hasEnded, let loadedURL {
            load(url: loadedURL, start: seconds)
            return
        }
        clock.time = seconds
        isBuffering = true
        command(["seek", String(seconds), "absolute"])
    }

    func skip(by seconds: Double) {
        seek(to: min(max(time + seconds, 0), duration))
    }

    func stop() {
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

    /// The picture showing right now, shrunk to this width. Nil until the video has a frame.
    func currentFrame(width: CGFloat) -> UIImage? {
        guard isVideoReady, let buffer = videoLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = width / max(image.extent.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return Self.frameContext.createCGImage(small, from: small.extent).map { UIImage(cgImage: $0) }
    }

    /// What mpv is doing right now, for the Diagnostics page.
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
        mpv_request_log_messages(mpv, "warn")
        var layerAddress = Int64(Int(bitPattern: Unmanaged.passUnretained(videoLayer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerAddress)
        mpv_set_option_string(mpv, "vo", "avfoundation")
        mpv_set_option_string(mpv, "avfoundation-composite-osd", "yes")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "hwdec-codecs", "all")
        mpv_set_option_string(mpv, "hwdec-software-fallback", "yes")
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
            mpv_set_property_string(mpv, "tls-verify", "yes")
        }
        mpv_set_property_string(mpv, "user-agent", Self.userAgent)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 3, "paused-for-cache", MPV_FORMAT_FLAG)
        self.mpv = mpv

        Thread { [weak self] in
            Self.runEvents(mpv, player: self)
        }.start()
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

    /// A line in Diagnostics, for measuring what can only be measured on the phone.
    func note(_ line: String) {
        addLog(line, level: "NOTICE")
    }

    private func addLog(_ line: String, level: String = "WARNING") {
        FileLog.shared.append("player", level, line)
        recentLog = Array((recentLog + [FileLog.safe(line)]).suffix(Self.logLimit))
    }

    private func publish(_ change: @escaping (MpvPlayer) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { change(self) }
        }
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
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
                guard self?.isVideoReady == true else { return }
                self?.queue.async { self?.activateAudioSession() }
            },
            // iOS can take the video decoder away in the background, which leaves the picture black.
            videoLayer.observe(\.status, options: [.new]) { [weak self] layer, _ in
                if layer.status == .failed { self?.resetDecoder() }
            }
        ]
    }

    private func resetDecoder() {
        queue.async { [self] in
            guard let mpv, decoderResets < Self.maxDecoderResets else { return }
            decoderResets += 1
            publish { $0.addLog("[player] restarted the decoder at \($0.time.clockText)") }
            mpv_set_property_string(mpv, "hwdec", "no")
            mpv_set_property_string(mpv, "hwdec", "videotoolbox")
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = !isPaused && isVideoReady
            if wasPlayingBeforeInterruption { setPaused(true) }
        case .ended:
            restoreAudio()
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            if wasPlayingBeforeInterruption, options?.contains(.shouldResume) == true { setPaused(false) }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    /// Unplugging headphones pauses, like every Apple player. Other route changes rebuild the output.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              isVideoReady else { return }
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
                player?.publish { $0.addLog(line) }
            case MPV_EVENT_PLAYBACK_RESTART:
                player?.publish {
                    if let started = $0.loadStarted {
                        $0.addLog("First frame after \(Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))) s", level: "NOTICE")
                        $0.loadStarted = nil
                    }
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
                        player?.publish {
                            $0.isBuffering = isOn
                            if isOn { $0.addLog("[player] ran out of video at \($0.time.clockText)") }
                        }
                    }
                } else if property.format == MPV_FORMAT_DOUBLE, let value = property.data?.load(as: Double.self), value.isFinite {
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
                    player?.publish {
                        $0.hasEnded = true
                        $0.isPaused = true
                        $0.isBuffering = false
                        $0.onEnded?()
                    }
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
    /// Only one view can hold the video layer. This one takes it when this turns true.
    var isActive = true
    /// Fills the view and crops what's outside, instead of leaving black bars.
    var fills = false

    func makeUIView(context: Context) -> MpvVideoUIView {
        MpvVideoUIView(player: player)
    }

    func updateUIView(_ view: MpvVideoUIView, context: Context) {
        view.fills = fills
        view.isActive = isActive
    }
}

final class MpvVideoUIView: UIView {
    private let player: MpvPlayer
    var fills = false {
        didSet {
            guard fills != oldValue else { return }
            if isActive {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.25)
                player.videoLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
                CATransaction.commit()
            }
            setNeedsLayout()
        }
    }
    var isActive = true {
        didSet {
            if isActive != oldValue { setNeedsLayout() }
        }
    }

    init(player: MpvPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isActive, bounds.width > 0, bounds.height > 0 else { return }
        let videoLayer = player.videoLayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if videoLayer.superlayer !== layer {
            layer.addSublayer(videoLayer)
        }
        videoLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
