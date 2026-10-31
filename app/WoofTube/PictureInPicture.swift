import AVKit
import Combine
import SwiftUI

/// Apple's floating window, showing the frames mpv already puts on the player's layer.
/// The window asks here for the playback state, and its buttons act on the same player.
final class PictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    /// iOS allows it once the layer is on screen and has a frame.
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    var onFailure: ((String) -> Void)?
    var onRestore: (() -> Void)?
    /// Opens the window when the app leaves the screen. iOS allows this for one player at a time.
    var startsAutomatically = false {
        didSet { controller?.canStartPictureInPictureAutomaticallyFromInline = startsAutomatically }
    }

    private let player: MpvPlayer
    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var didRestore = false
    private var possibleObservation: NSKeyValueObservation?
    private var subscriptions: Set<AnyCancellable> = []

    /// The window's clock runs on its own, so it's only corrected when it drifts this many seconds.
    private static let allowedDrift = 0.5

    init(player: MpvPlayer) {
        self.player = player
        super.init()
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0)
            player.videoLayer.controlTimebase = timebase
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: player.videoLayer, playbackDelegate: self))
        controller.delegate = self
        controller.requiresLinearPlayback = false
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let isPossible = controller.isPictureInPicturePossible
            DispatchQueue.main.async { self?.isPossible = isPossible }
        }
        observePlayer()
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            controller?.startPictureInPicture()
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    private func observePlayer() {
        player.$isPaused.combineLatest(player.$speed)
            .sink { [weak self] isPaused, speed in
                guard let self, let timebase else { return }
                CMTimebaseSetRate(timebase, rate: isPaused ? 0 : speed)
                refreshWindow()
            }
            .store(in: &subscriptions)
        player.$duration
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshWindow() } }
            .store(in: &subscriptions)
        player.clock.$time
            .sink { [weak self] time in
                guard let self, let timebase, abs(CMTimebaseGetTime(timebase).seconds - time) > Self.allowedDrift else { return }
                CMTimebaseSetTime(timebase, time: CMTime(seconds: time, preferredTimescale: 1000))
                refreshWindow()
            }
            .store(in: &subscriptions)
    }

    private func refreshWindow() {
        if isActive { controller?.invalidatePlaybackState() }
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        didRestore = false
        isActive = true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        onFailure?(error.localizedDescription)
    }

    /// The window's button that returns to the app.
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        didRestore = true
        onRestore?()
        completionHandler(true)
    }

    /// Closing the window from another app means stop, so the video doesn't carry on unseen.
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        let state = UIApplication.shared.applicationState
        if !didRestore, state != .active { player.setPaused(true) }
        player.setVideoEnabled(state != .background)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        player.setPaused(!playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let duration = player.duration > 0 ? CMTime(seconds: player.duration, preferredTimescale: 1000) : .positiveInfinity
        return CMTimeRange(start: .zero, duration: duration)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        player.isPaused
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        player.skip(by: skipInterval.seconds)
        completionHandler()
    }
}
