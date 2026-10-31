import AVKit
import SwiftUI
import SwiftyTube

struct PictureInPictureError: LocalizedError {
    let errorDescription: String?
}

/// Apple's floating window only shows its own players, and mpv draws with Metal. So AVPlayer takes
/// over while the window is open, on the HLS stream YouTube gives its iOS client, and hands the
/// position back to mpv when it closes.
// ponytail: starts from the player's button only. Starting by itself when the app leaves the screen
// needs AVPlayer already playing alongside mpv. The window also closes when the video ends.
final class PictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isActive = false
    /// Where the video got to and whether it should keep playing.
    var onStop: ((_ time: Double, _ keepsPlaying: Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onRestore: (() -> Void)?

    private var player: AVPlayer?
    private var layer: AVPlayerLayer?
    private var controller: AVPictureInPictureController?
    private var endObserver: Any?
    private var didRestore = false

    private static let loadPolls = 100
    private static let pollDelay = Duration.milliseconds(100)

    /// `onReady` runs just before AVPlayer makes sound, to silence mpv.
    @MainActor
    func start(videoId: String, at time: Double, onReady: () -> Void) async throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw PictureInPictureError(errorDescription: "This iPhone doesn't support Picture in Picture.")
        }
        isLoading = true
        defer { isLoading = false }
        let response: PlayerResponse = try await InnerTubeClient.wooftube.playerResponse(
            videoId: videoId,
            client: .iOS,
            options: PlayerRequestOptions(signatureTimestamp: nil)
        )
        guard let manifest = response.streamingData?.hlsManifestUrl, let url = URL(string: manifest),
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            throw PictureInPictureError(errorDescription: "YouTube has no stream for Picture in Picture on this video.")
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // The window itself holds the layer, because a full screen page removes the views behind it.
        let layer = AVPlayerLayer(player: player)
        layer.frame = window.bounds
        window.layer.insertSublayer(layer, at: 0)
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            layer.removeFromSuperlayer()
            throw PictureInPictureError(errorDescription: "Picture in Picture couldn't start.")
        }
        controller.delegate = self
        self.player = player
        self.layer = layer
        self.controller = controller
        didRestore = false

        for _ in 0..<Self.loadPolls where item.status != .failed {
            if item.status == .readyToPlay, controller.isPictureInPicturePossible { break }
            try? await Task.sleep(for: Self.pollDelay)
        }
        guard item.status == .readyToPlay, controller.isPictureInPicturePossible else {
            cleanUp()
            throw PictureInPictureError(errorDescription: "The stream for Picture in Picture didn't load.")
        }
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        onReady()
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.stop()
        }
        player.play()
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func togglePause() {
        setPaused(player?.rate != 0)
    }

    func setPaused(_ paused: Bool) {
        if paused {
            player?.pause()
        } else {
            player?.play()
        }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func cleanUp() {
        player?.pause()
        layer?.removeFromSuperlayer()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        layer = nil
        controller = nil
        isActive = false
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let time = player?.currentTime().seconds ?? 0
        cleanUp()
        onStop?(time, true)
        onFailure?(error.localizedDescription)
    }

    /// The window's button that returns to the app.
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        didRestore = true
        onRestore?()
        completionHandler(true)
    }

    /// Closing the window from another app means stop, so mpv doesn't carry on in the background.
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let time = player?.currentTime().seconds ?? 0
        let isPlaying = player?.rate != 0
        let keepsPlaying = isPlaying && (didRestore || UIApplication.shared.applicationState == .active)
        cleanUp()
        onStop?(time, keepsPlaying)
    }
}
