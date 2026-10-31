import SwiftUI
import SwiftyTube

extension InnerTubeClient {
    static let wooftube = InnerTubeClient(config: .youtube)
}

@main
struct WoofTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @StateObject private var router = Router()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            AppearanceRoot {
                if session.isSignedIn {
                    RootTabs()
                } else {
                    SignInView()
                }
            }
            .environmentObject(session)
            .environmentObject(router)
            .environmentObject(settings)
            .task {
                await InnerTubeClient.wooftube.updateLocale(YouTubeLocale(
                    gl: Locale.current.region?.identifier ?? "US",
                    hl: Locale.current.language.languageCode?.identifier ?? "en"
                ))
                await session.restore()
            }
            .alert("Session Expired", isPresented: $session.isExpired) {
                Button("Sign In Again") { Task { await session.signOut() } }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Google no longer accepts this sign-in. Your feeds won't be personal until you sign in again.")
            }
        }
    }
}

/// A view, so a new accent or theme applies straight away. The window's tint
/// colours what UIKit draws for SwiftUI, such as the icons in menus and alerts.
private struct AppearanceRoot<Content: View>: View {
    @ViewBuilder let content: Content
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        content
            .tint(settings.accentColor)
            .preferredColorScheme(settings.themeMode.colorScheme)
            .onAppear(perform: applyWindowTint)
            .onChange(of: settings.accentName) { applyWindowTint() }
    }

    private func applyWindowTint() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.tintColor = UIColor(settings.accentColor) }
        }
    }
}

extension View {
    /// Shorts, channels and errors. Only the top screen can present them, so the
    /// tabs and the video page each attach these and the tabs stand down while it's open.
    func routerPresentations(_ router: Router, isActive: Bool) -> some View {
        fullScreenCover(item: Binding(get: { isActive ? router.shortsRoute : nil }, set: { router.shortsRoute = $0 })) { route in
            ShortsView(route: route, player: router.shortsPlayer)
        }
        .sheet(item: Binding(get: { isActive ? router.channelRoute : nil }, set: { router.channelRoute = $0 })) { route in
            NavigationStack {
                ChannelView(channelId: route.id)
                    .toolbar {
                        Button("Close", systemImage: "xmark") { router.channelRoute = nil }
                    }
            }
        }
        .alert("That Didn't Work", isPresented: Binding(get: { isActive && router.actionMessage != nil }, set: { if !$0 { router.actionMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.actionMessage ?? "")
        }
    }
}

enum AppTab: Hashable {
    case home, library, subs, search
}

struct RootTabs: View {
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home
    /// Links the floating card and the video page for the zoom, as Woof Music does for its player.
    @Namespace private var playerZoom

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView()
            }
            Tab("Library", systemImage: "play.square.stack", value: AppTab.library) {
                LibraryView()
            }
            Tab("Subs", systemImage: "rectangle.stack.badge.play", value: AppTab.subs) {
                SubsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchScreen()
            }
        }
        .tabBarMinimizeBehavior(.never)
        .overlay { PlayerOverlay(zoom: playerZoom) }
        .fullScreenCover(isPresented: $router.isExpanded) {
            WatchPage()
                .navigationTransition(.zoom(sourceID: PlayerOverlay.zoomSource, in: playerZoom))
                .onAppear { router.isWatchPageOnScreen = true }
                .onDisappear { router.isWatchPageOnScreen = false }
        }
        .routerPresentations(router, isActive: !router.isExpanded)
        .task { await Subscriptions.shared.load() }
        // Metal may not draw in the background. Otherwise the video is always on screen.
        .onChange(of: scenePhase) { router.player.setVideoEnabled(scenePhase != .background) }
    }
}
