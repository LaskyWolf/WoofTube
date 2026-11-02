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

/// The app is portrait, like Apple Music. Only the open video page can rotate.
enum Orientation {
    private(set) static var mask = UIInterfaceOrientationMask.portrait

    static func videoPageChanged(isOpen: Bool) {
        apply(isOpen ? .allButUpsideDown : .portrait, request: isOpen ? nil : .portrait)
    }

    /// Holds the requested orientation, so the sensor can't undo the button straight away.
    static func setFullscreen(_ isFullscreen: Bool) {
        // The device and the interface name their landscape sides the opposite way round.
        let side: UIInterfaceOrientationMask = UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
        apply(isFullscreen ? .landscape : .portrait, request: isFullscreen ? side : .portrait)
        unlockIfHeldUpright()
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
