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
    case home, subscriptions, shorts, you, search
}

struct RootTabs: View {
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home
    @Namespace private var playerNamespace

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView()
            }
            Tab("Subscriptions", systemImage: "rectangle.stack.badge.play", value: AppTab.subscriptions) {
                NavigationStack {
                    FeedList(source: .browse(YouTubeFeeds.subscriptions))
                        .navigationTitle("Subscriptions")
                }
            }
            Tab("Shorts", systemImage: "play.square.stack", value: AppTab.shorts) {
                ShortsView(isActive: tab == .shorts)
            }
            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchScreen()
            }
        }
        .modifier(MiniPlayerAccessory(isEnabled: router.current != nil))
        .environment(\.playerNamespace, playerNamespace)
        .fullScreenCover(isPresented: $router.isExpanded) {
            // The zoom transition also gives the system's swipe down to close.
            WatchView()
                .navigationTransition(.zoom(sourceID: router.zoomSourceID, in: playerNamespace))
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .shorts { router.close() }
        }
        .onChange(of: router.isExpanded) { updateVideoOutput() }
        .onChange(of: scenePhase) { updateVideoOutput() }
    }

    /// Nothing can see the video here, and Metal may not draw in the background.
    private func updateVideoOutput() {
        router.player.setVideoEnabled(router.isExpanded && scenePhase != .background)
    }
}

/// `isEnabled` is new in iOS 26.1. On 26.0 the accessory bar always shows, with nothing inside it.
private struct MiniPlayerAccessory: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) { MiniPlayer() }
        } else {
            content.tabViewBottomAccessory { MiniPlayer() }
        }
    }
}

private struct MiniPlayer: View {
    private static let zoomID = "miniPlayer"

    @EnvironmentObject private var router: Router
    @Environment(\.playerNamespace) private var playerNamespace

    var body: some View {
        if let video = router.current {
            HStack(spacing: Layout.chipSpacing) {
                Button {
                    router.zoomSourceID = Self.zoomID
                    router.isExpanded = true
                } label: {
                    HStack(spacing: Layout.rowSpacing) {
                        AsyncImage(url: URL(string: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color(.secondarySystemFill)
                        }
                        .frame(width: 48, height: 28)
                        .clipShape(.rect(cornerRadius: Layout.thumbRadius))
                        .zoomSource(id: Self.zoomID, in: playerNamespace)

                        Text(video.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                MiniPlayPause(player: router.player)

                Button("Close", systemImage: "xmark") { router.close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .padding(.leading, Layout.screenPadding)
            .padding(.trailing, Layout.chipSpacing)
        }
    }
}

private struct MiniPlayPause: View {
    @ObservedObject var player: MpvPlayer

    var body: some View {
        Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
            player.togglePause()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
}
