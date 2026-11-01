import SwiftUI
import SwiftyTube

extension InnerTubeClient {
    static let wooftube = InnerTubeClient(config: .youtube)
}

@main
struct WoofTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @State private var router = Router()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            AppearanceRoot {
                if session.isSignedIn {
                    // A new identity resets every tab's feeds when the account changes.
                    RootTabs().id(session.generation)
                } else if session.isRestoring {
                    Color(.systemBackground).ignoresSafeArea()
                } else {
                    SignInView()
                }
            }
            .environmentObject(session)
            .environment(router)
            .environmentObject(settings)
            .task {
                SwiftyTubeLog.handler = { message, level in
                    if level == .error { FileLog.shared.append("swiftytube", "ERROR", message) }
                }
                await InnerTubeClient.wooftube.updateLocale(YouTubeLocale(
                    gl: Locale.current.region?.identifier ?? "US",
                    hl: Locale.current.language.languageCode?.identifier ?? "en"
                ))
                await session.restore()
                #if DEBUG
                await StreamCache.selfCheck()
                CoverTint.selfCheck()
                GlyphScript.selfCheck()
                WatchSegments.selfCheck()
                WatchedChannels.selfCheck()
                YouTubeAPI.selfCheck()
                SponsorBlock.selfCheck()
                LockupDetails.selfCheck()
                DiagnosticsSection.selfCheck()
                CommentsPage.selfCheck()
                VideoFlavor.selfCheck()
                #endif
            }
            .alert("Session Expired", isPresented: $session.isExpired) {
                Button("Sign In Again") {
                    router.close()
                    Task { await session.signOut() }
                }
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
    /// Channels and errors. Only the top screen can present them, so the
    /// tabs and the video page each attach these and the tabs stand down while it's open.
    func routerPresentations(_ router: Router, isActive: Bool) -> some View {
        sheet(item: Binding(get: { isActive ? router.channelRoute : nil }, set: { router.channelRoute = $0 })) { route in
            NavigationStack {
                ChannelView(channelId: route.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { router.channelRoute = nil }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
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

/// The pages a tab opens from code.
struct TabDestinations: ViewModifier {
    let tab: AppTab
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: HeaderRoute.self) { route in
                Group {
                    switch route {
                    case .notifications: NotificationsView()
                    case .settings: SettingsView()
                    }
                }
            }
            .navigationDestination(item: Binding(get: { router.channelPage?.tab == tab ? router.channelPage : nil }, set: { router.channelPage = $0 })) { route in
                ChannelView(channelId: route.id)
                    .id(route.id)
            }
    }
}

struct RootTabs: View {
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    /// Links the floating card and the video page for the zoom, as Woof Music does for its player.
    @Namespace private var playerZoom

    var body: some View {
        TabView(selection: Bindable(router).selectedTab) {
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
        // Selecting Search activates it, and its X goes back to the previous tab.
        .tabViewSearchActivation(.searchTabSelection)
        .environment(\.videoZoomSpace, playerZoom)
        .overlay { PlayerOverlay(zoom: playerZoom) }
        .fullScreenCover(isPresented: Bindable(router).isExpanded) {
            WatchPage()
                .navigationTransition(.zoom(sourceID: router.zoomSource, in: playerZoom))
                .presentationBackground(.clear)
                .onAppear { router.isWatchPageOnScreen = true }
                .onDisappear { router.isWatchPageOnScreen = false }
        }
        .fullScreenCover(item: Bindable(router).shortsRoute) { route in
            ShortsView(model: route.model)
                .navigationTransition(.zoom(sourceID: router.zoomSource, in: playerZoom))
                .presentationBackground(.clear)
                .onAppear { router.isShortsPageOnScreen = true }
                .onDisappear { router.isShortsPageOnScreen = false }
        }
        .routerPresentations(router, isActive: !router.isExpanded)
        .task { await Subscriptions.shared.load() }
        .onChange(of: scenePhase) {
            router.sceneChanged(isBackground: scenePhase == .background)
            if scenePhase == .active { router.sceneBecameActive() }
        }
    }
}
