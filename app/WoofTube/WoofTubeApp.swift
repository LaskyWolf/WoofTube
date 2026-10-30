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
            Group {
                if session.isSignedIn {
                    RootTabs()
                } else {
                    SignInView()
                }
            }
            .environmentObject(session)
            .environmentObject(router)
            .environmentObject(settings)
            .tint(settings.accentColor)
            .preferredColorScheme(settings.themeMode.colorScheme)
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

enum AppTab: Hashable {
    case home, library, subs, search
}

struct RootTabs: View {
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home

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
        .overlay { PlayerOverlay() }
        .sheet(item: $router.channelRoute) { route in
            NavigationStack {
                ChannelView(channelId: route.id)
                    .toolbar {
                        Button("Close", systemImage: "xmark") { router.channelRoute = nil }
                    }
            }
        }
        .alert("That Didn't Work", isPresented: Binding(get: { router.actionMessage != nil }, set: { if !$0 { router.actionMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.actionMessage ?? "")
        }
        // Metal may not draw in the background. Otherwise the video is always on screen.
        .onChange(of: scenePhase) { router.player.setVideoEnabled(scenePhase != .background) }
    }
}
