import SwiftUI
import SwiftyTube

struct LibraryView: View {
    @State private var playlists: [YouTubePlaylist] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MenuCard {
                        NavigationLink {
                            FeedList(source: .browse(YouTubeFeeds.history), isCompact: true)
                                .navigationTitle("History")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            MenuRowLabel(icon: "clock.arrow.circlepath", title: "History")
                        }
                        Divider()
                        NavigationLink {
                            PlaylistPage(title: "Watch Later", playlistId: YouTubeFeeds.watchLaterPlaylistId)
                        } label: {
                            MenuRowLabel(icon: "clock", title: "Watch Later")
                        }
                        Divider()
                        NavigationLink {
                            PlaylistPage(title: "Liked Videos", playlistId: YouTubeFeeds.likedVideosPlaylistId)
                        } label: {
                            MenuRowLabel(icon: "hand.thumbsup", title: "Liked Videos")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.top, Layout.chipSpacing)
                    .padding(.bottom, Layout.sectionGap)

                    if !playlists.isEmpty {
                        SectionTitle(title: "Playlists")
                        LazyVStack(spacing: 0) {
                            ForEach(playlists, id: \.playlistId) { playlist in
                                NavigationLink {
                                    PlaylistPage(title: playlist.title, playlistId: playlist.playlistId)
                                } label: {
                                    MediaListRow(url: playlist.thumbnailURL, title: playlist.title, subtitle: playlist.videoCountText)
                                }
                                .buttonStyle(RowPressStyle())
                                .padding(.horizontal, Layout.screenPadding)
                            }
                        }
                    }
                }
            }
            .tabRoot(title: "Library")
            .task {
                let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
                playlists = json.map { YouTubeFeedParser.playlists(in: $0) } ?? []
            }
        }
    }
}

/// Woof Music's playlist page: header card over the blurred cover, then compact rows.
struct PlaylistPage: View {
    let title: String
    let playlistId: String

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = FeedModel()

    private var videos: [YouTubeVideo] {
        model.items.compactMap {
            if case .video(let video, _, _) = $0 { return video }
            return nil
        }
    }

    private var meta: String {
        guard !videos.isEmpty else { return "Playlist" }
        let total = videos.compactMap(\.durationSeconds).reduce(0, +)
        let count = "\(videos.count) \(videos.count == 1 ? "video" : "videos")"
        return total > 0 ? count + " · " + Double(total).clockText : count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if videos.isEmpty, !model.isLoading {
                    ContentUnavailableView {
                        Label(model.errorText == nil ? "No Videos" : "Couldn't Load", systemImage: "play.rectangle")
                    } description: {
                        if let errorText = model.errorText { Text(errorText) }
                    }
                }
                FeedRows(model: model, isCompact: true)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await load() }
        .task {
            if model.items.isEmpty { await load() }
        }
    }

    private func load() async {
        await model.load(.browse(YouTubeFeeds.playlistBrowseId(playlistId)))
    }

    private var header: some View {
        DetailHeaderCard(meta: meta, title: title) {
            CoverImage(url: videos.first?.thumbnailURL)
                .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
        } secondary: {
            EmptyView()
        } buttons: {
            if !videos.isEmpty {
                Button { router.playAll(videos, shuffled: true) } label: {
                    HeaderRoundIcon(systemImage: "shuffle")
                }
                .accessibilityLabel("Shuffle")
                Button { router.playAll(videos) } label: {
                    HeaderRoundIcon(systemImage: "play.fill", primary: settings.accentColor)
                }
                .accessibilityLabel("Play All")
            }
        }
        .padding(.vertical, Layout.screenPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: videos.first?.thumbnailURL)
        }
    }
}
