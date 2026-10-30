import SwiftUI
import SwiftyTube

struct YouView: View {
    @State private var account: AccountInfo?

    var body: some View {
        NavigationStack {
            List {
                if let account {
                    Section {
                        HStack(spacing: 12) {
                            Avatar(url: account.thumbnailUrl, size: 56)
                            VStack(alignment: .leading) {
                                Text(account.name).font(.headline)
                                if let handle = account.channelHandle {
                                    Text(handle).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    link("History", icon: "clock.arrow.circlepath", source: .browse(YouTubeFeeds.history))
                    link("Watch Later", icon: "clock", source: .browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.watchLaterPlaylistId)))
                    link("Liked Videos", icon: "hand.thumbsup", source: .browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.likedVideosPlaylistId)))
                    NavigationLink {
                        PlaylistsView()
                    } label: {
                        Label("Playlists", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .navigationTitle("You")
            .toolbar {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            .task { account = try? await InnerTubeClient.wooftube.accountInfo() }
        }
    }

    private func link(_ title: String, icon: String, source: FeedSource) -> some View {
        NavigationLink {
            FeedList(source: source).navigationTitle(title)
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

struct PlaylistsView: View {
    @State private var playlists: [YouTubePlaylist] = []
    @State private var isLoading = true

    var body: some View {
        List(playlists, id: \.playlistId) { playlist in
            NavigationLink {
                FeedList(source: .browse(YouTubeFeeds.playlistBrowseId(playlist.playlistId)))
                    .navigationTitle(playlist.title)
            } label: {
                VStack(alignment: .leading) {
                    Text(playlist.title).font(.headline)
                    if let count = playlist.videoCountText {
                        Text(count).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if playlists.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Playlists", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("Playlists")
        .task {
            let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
            playlists = json.map { YouTubeFeedParser.playlists(in: $0) } ?? []
            isLoading = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: Router

    var body: some View {
        Form {
            Picker("Maximum Quality", selection: $router.maxHeight) {
                ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
            }
            NavigationLink("Diagnostics") {
                DiagnosticsView(player: router.player, stream: router.streamSummary)
            }
            Button("Sign Out", role: .destructive) {
                router.close()
                Task { await session.signOut() }
            }
        }
        .navigationTitle("Settings")
    }
}

/// Shows what the player is doing, because a phone has no console to read.
struct DiagnosticsView: View {
    @ObservedObject var player: MpvPlayer
    let stream: String?
    @State private var state = ""

    private var report: String {
        ([stream ?? "No stream", state] + player.recentLog).joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            Text(report)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.screenPadding)
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ShareLink(item: report)
        }
        .task { state = await player.diagnostics() }
    }
}
