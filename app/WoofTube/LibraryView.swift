import SwiftUI
import SwiftyTube

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                TabHeader(title: "Library")
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
            .tabRoot()
        }
    }

    private func link(_ title: String, icon: String, source: FeedSource) -> some View {
        NavigationLink {
            FeedList(source: source)
                .navigationTitle(title)
                .toolbar(.visible, for: .navigationBar)
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
