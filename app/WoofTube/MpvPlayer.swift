import AVFoundation
import Libmpv
import Metal
import SwiftUI

/// One mpv instance per player screen. mpv's option order comes from Woof Music's
/// PlayerController. Events arrive on a background thread and are published on main.
final class MpvPlayer: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var errorText: String?

    let videoLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.framebufferOnly = true
        layer.contentsGravity = .resizeAspect
        return layer
    }()

    private var mpv: OpaquePointer?
    private var pendingURL: String?
    private var hasSurface = false

    init() {
        guard let mpv = mpv_create() else {
            errorText = "mpv could not start"
            return
        }
        setenv("MVK_CONFIG_LOG_LEVEL", "1", 1)
        mpv_set_option_string(mpv, "vo", "null")
        mpv_set_option_string(mpv, "vid", "no")
        mpv_set_option_string(mpv, "force-window", "no")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "120")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "200M")

        let status = mpv_initialize(mpv)
        guard status >= 0 else {
            errorText = "mpv could not start: \(String(cString: mpv_error_string(status)))"
            mpv_destroy(mpv)
            return
        }

        if let certificates = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            mpv_set_property_string(mpv, "tls-ca-file", certificates)
        }
        mpv_set_property_string(mpv, "user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
        mpv_set_property_string(mpv, "vo", "gpu-next")
        mpv_set_property_string(mpv, "gpu-api", "vulkan")
        mpv_set_property_string(mpv, "gpu-context", "moltenvk")
        var window = unsafeBitCast(videoLayer, to: Int64.self)
        mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &window)
        mpv_set_property_string(mpv, "vid", "auto")

        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG)
        self.mpv = mpv

        let layer = videoLayer
        Thread { [weak self] in
            Self.runEvents(mpv, player: self)
            mpv_terminate_destroy(mpv)
            // mpv draws into the layer until it is destroyed.
            withExtendedLifetime(layer) {}
        }.start()
    }

    /// Starts once the video view has a real size, because mpv sizes its surface from the layer.
    func load(url: String) {
        pendingURL = url
        startIfReady()
    }

    func surfaceDidResize() {
        hasSurface = true
        startIfReady()
    }

    func togglePause() {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "pause", isPaused ? "no" : "yes")
    }

    func seek(to seconds: Double) {
        command(["seek", String(seconds), "absolute"])
    }

    func stop() {
        command(["quit"])
        mpv = nil
    }

    private func startIfReady() {
        guard hasSurface, let url = pendingURL else { return }
        pendingURL = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        command(["loadfile", url, "replace"])
    }

    private func command(_ arguments: [String]) {
        guard let mpv else { return }
        _ = arguments.withUnsafeCArg { mpv_command(mpv, $0) }
    }

    private static func runEvents(_ mpv: OpaquePointer, player: MpvPlayer?) {
        weak var player = player
        var lastSecond = -1
        while true {
            guard let event = mpv_wait_event(mpv, 1) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.pointee.data?.load(as: mpv_event_property.self),
                      let namePointer = property.name else { continue }
                let name = String(cString: namePointer)
                if name == "pause", property.format == MPV_FORMAT_FLAG {
                    let paused = property.data?.load(as: Int32.self) != 0
                    DispatchQueue.main.async { player?.isPaused = paused }
                } else if property.format == MPV_FORMAT_DOUBLE, let value = property.data?.load(as: Double.self) {
                    if name == "duration" {
                        DispatchQueue.main.async { player?.duration = value }
                    } else if Int(value) != lastSecond {
                        lastSecond = Int(value)
                        DispatchQueue.main.async { player?.time = value }
                    }
                }
            case MPV_EVENT_END_FILE:
                guard let end = event.pointee.data?.load(as: mpv_event_end_file.self),
                      end.reason == MPV_END_FILE_REASON_ERROR else { continue }
                let message = String(cString: mpv_error_string(end.error))
                DispatchQueue.main.async { player?.errorText = "Playback failed: \(message)" }
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
        layer.addSublayer(player.videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = traitCollection.displayScale
        player.videoLayer.frame = bounds
        player.videoLayer.contentsScale = scale
        player.videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        player.surfaceDidResize()
    }
}
