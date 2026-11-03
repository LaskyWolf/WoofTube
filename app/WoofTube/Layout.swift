import CoreMotion
import SwiftUI

/// Values from Woof Music's DesignTokens and FilterChipBar.
enum Layout {
    static let screenPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 4
    static let chipSpacing: CGFloat = 8
    static let rowPadding: CGFloat = 6
    static let tileRadius: CGFloat = 12
    /// A channel's picture: large on its own page, medium in the Library, small everywhere else.
    static let avatarSmall: CGFloat = 36
    static let avatarMedium: CGFloat = 60
    static let avatarLarge: CGFloat = 104
    /// Woof Music's medium art, for the channel card on top of search results.
    static let artMedium: CGFloat = 115
    static let cardRadius: CGFloat = 8
    static let sheetRadius: CGFloat = 16
    static let menuRowSpacing: CGFloat = 14
    static let sectionGap: CGFloat = 16
    static let artSmall: CGFloat = 60
    static let artLarge: CGFloat = 160
    /// Height of the row under each tab title.
    static let controlHeight: CGFloat = 40
    static let rowInsets = EdgeInsets(top: rowPadding * 2, leading: screenPadding, bottom: rowPadding * 2, trailing: screenPadding)
}

/// The app turns with the phone. Full screen holds landscape until the phone is upright again.
enum Orientation {
    private(set) static var mask = UIInterfaceOrientationMask.allButUpsideDown

    private static let motion = CMMotionManager()
    private static let tiltCheck: TimeInterval = 0.5
    /// Share of gravity along one edge that counts as the phone being turned that way.
    private static let tiltThreshold = 0.7

    static func videoPageChanged(isOpen: Bool) {
        if !isOpen { motion.stopAccelerometerUpdates() }
        apply(.allButUpsideDown, request: nil)
    }

    /// Holds the requested orientation, so the sensor can't undo the button straight away.
    static func setFullscreen(_ isFullscreen: Bool) {
        if isFullscreen {
            followTilt()
        } else {
            motion.stopAccelerometerUpdates()
            apply(.portrait, request: .portrait)
            unlockIfHeldUpright()
        }
    }

    /// Rotation lock stops iOS from turning the screen, so full screen reads the tilt itself:
    /// first to pick the side, then every half second to follow the phone or leave when it's upright.
    private static func followTilt() {
        guard motion.isAccelerometerAvailable else {
            apply(.landscape, request: .landscapeRight)
            return
        }
        var side: UIInterfaceOrientationMask?
        motion.accelerometerUpdateInterval = tiltCheck
        motion.startAccelerometerUpdates(to: .main) { data, _ in
            guard let gravity = data?.acceleration else { return }
            let tilt = Self.side(x: gravity.x, y: gravity.y)
            if side == nil {
                // Flat on a table says nothing, so it takes the usual side.
                side = tilt == .portrait || tilt == nil ? .landscapeRight : tilt
                apply(.landscape, request: side)
            } else if tilt == .portrait {
                motion.stopAccelerometerUpdates()
                apply(.allButUpsideDown, request: .portrait)
            } else if let tilt, tilt != side {
                side = tilt
                apply(.landscape, request: tilt)
            }
        }
    }

    /// Gravity in the phone's own axes: y is -1 when upright, x is +1 when its right edge points down.
    static func side(x: Double, y: Double) -> UIInterfaceOrientationMask? {
        if y < -tiltThreshold { return .portrait }
        // The right edge down is the interface's landscapeRight: the home side faces right.
        if x > tiltThreshold { return .landscapeRight }
        if x < -tiltThreshold { return .landscapeLeft }
        return nil
    }

    static func selfCheck() {
        assert(side(x: 0, y: -1) == .portrait)
        assert(side(x: 0.95, y: -0.1) == .landscapeRight)
        assert(side(x: -0.95, y: 0.1) == .landscapeLeft)
        assert(side(x: 0.1, y: -0.2) == nil)
    }

    /// After leaving full screen, rotation comes back once the phone is held upright.
    static func unlockIfHeldUpright() {
        if mask == .portrait, UIDevice.current.orientation.isPortrait {
            apply(.allButUpsideDown, request: nil)
        }
    }

    private static func apply(_ newMask: UIInterfaceOrientationMask, request: UIInterfaceOrientationMask?) {
        mask = newMask
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var controller = scene?.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        if let request {
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: request))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        _ = DownloadStore.shared
        CrashReports.shared.start()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadStore.shared.backgroundCompletion = completionHandler
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}
