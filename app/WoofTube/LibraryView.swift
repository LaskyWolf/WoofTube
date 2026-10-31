import SwiftUI
import SwiftyTube

struct LibraryView: View {
    @EnvironmentObject private var router: Router
    @State private var playlists: [YouTubePlaylist] = []
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var playlistToDelete: YouTubePlaylist?

    private func loadPlaylists() async {
        let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
        playlists = json.map { YouTubeFeedParser.playlists(in: $0) } ?? []
    }

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
                        Divider()
                        NavigationLink {
                            FeedList(source: .browse("FEchannels"), isCompact: true)
                                .navigationTitle("Channels")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            MenuRowLabel(icon: "person.2", title: "Channels")
                        }
                        Divider()
                        NavigationLink {
                            DownloadsView()
                        } label: {
                            MenuRowLabel(icon: "arrow.down.circle", title: "Downloads")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.top, Layout.chipSpacing)
                    .padding(.bottom, Layout.sectionGap)

                    HStack {
                        SectionTitle(title: "Playlists")
                        Spacer()
                        Button("New Playlist", systemImage: "plus") {
                            newTitle = ""
                            isCreating = true
                        }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.trailing, Layout.chipSpacing)
                    }
                    if !playlists.isEmpty {
                        LazyVStack(spacing: 0) {
                            ForEach(playlists, id: \.playlistId) { playlist in
                                NavigationLink {
                                    PlaylistPage(title: playlist.title, playlistId: playlist.playlistId)
                                } label: {
                                    MediaListRow(url: playlist.thumbnailURL, title: playlist.title, subtitle: playlist.videoCountText)
                                }
                                .buttonStyle(RowPressStyle())
                                .padding(.horizontal, Layout.screenPadding)
                                .contextMenu {
                                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                        playlistToDelete = playlist
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .tabRoot(title: "Library")
            .task { await loadPlaylists() }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let title = newTitle
                    router.run {
                        _ = try await InnerTubeClient.wooftube.createPlaylist(title: title)
                        await loadPlaylists()
                    }
                }
            }
            .confirmationDialog(
                "Delete \"\(playlistToDelete?.title ?? "")\"?",
                isPresented: Binding(get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let id = playlistToDelete?.playlistId else { return }
                    router.run {
                        _ = try await InnerTubeClient.wooftube.deletePlaylist(playlistId: id)
                        await loadPlaylists()
                    }
                }
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
    @State private var newTitle: String?
    @State private var isRenaming = false
    @State private var draftTitle = ""

    private var shownTitle: String { newTitle ?? title }
    /// Liked Videos follows your likes, so it can't be edited like a playlist.
    private var allowsRemoving: Bool { playlistId != YouTubeFeeds.likedVideosPlaylistId }
    private var allowsRenaming: Bool { allowsRemoving && playlistId != YouTubeFeeds.watchLaterPlaylistId }

    private var videos: [YouTubeVideo] {
        model.items.compactMap {
            if case .video(let video, _) = $0 { return video }
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
                FeedRows(model: model, isCompact: true, editablePlaylistId: allowsRemoving ? playlistId : nil)
            }
        }
        .toolbar {
            if allowsRenaming {
                Menu("Options", systemImage: "ellipsis") {
                    Button("Rename", systemImage: "pencil") {
                        draftTitle = shownTitle
                        isRenaming = true
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = draftTitle
                newTitle = name
                router.run {
                    _ = try await InnerTubeClient.wooftube.editPlaylist(
                        playlistId: playlistId,
                        actions: [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": name]]
                    )
                }
            }
        }
        .navigationTitle(shownTitle)
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
        DetailHeaderCard(meta: meta, title: shownTitle) {
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
