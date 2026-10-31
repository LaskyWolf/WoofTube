import SwiftUI

/// Values from Woof Music's DesignTokens and FilterChipBar.
enum Layout {
    static let screenPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 4
    static let chipSpacing: CGFloat = 8
    static let rowPadding: CGFloat = 6
    static let thumbRadius: CGFloat = 4
    static let tileRadius: CGFloat = 12
    static let thumbSmall: CGFloat = 40
    /// A channel's picture: large on its own page, medium in the Library, small everywhere else.
    static let avatarSmall: CGFloat = 36
    static let avatarMedium: CGFloat = 60
    static let avatarLarge: CGFloat = 104
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

/// Rows shrink slightly under the finger, so a tap always shows a response.
struct RowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The app is portrait, like Apple Music. Only the open video page can rotate.
enum Orientation {
    private(set) static var mask = UIInterfaceOrientationMask.portrait

    static func videoPageChanged(isOpen: Bool) {
        apply(isOpen ? .allButUpsideDown : .portrait, request: isOpen ? nil : .portrait)
    }

    /// Holds the requested orientation, so the sensor can't undo the button straight away.
    static func setFullscreen(_ isFullscreen: Bool) {
        apply(isFullscreen ? .landscape : .portrait, request: isFullscreen ? .landscapeRight : .portrait)
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
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}
