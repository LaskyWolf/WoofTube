import SwiftUI
import SwiftyTube

extension View {
    /// The long press menu. Same layout as Woof Music: actions row, queue, then the rest.
    func videoMenu(_ video: YouTubeVideo, feedback: [FeedbackAction] = [], collaborators: [Collaborator] = [], onRemove: (() -> Void)? = nil, onRemoveFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(VideoMenuModifier(video: video, feedback: feedback, collaborators: collaborators, onRemove: onRemove, onRemoveFromPlaylist: onRemoveFromPlaylist))
    }
}

private struct VideoMenuModifier: ViewModifier {
    let video: YouTubeVideo
    let feedback: [FeedbackAction]
    let collaborators: [Collaborator]
    let onRemove: (() -> Void)?
    let onRemoveFromPlaylist: (() -> Void)?
    @EnvironmentObject private var router: Router
    @State private var showsPlaylists = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                VideoMenuItems(video: video, feedback: feedback, collaborators: collaborators, onRemove: onRemove, onRemoveFromPlaylist: onRemoveFromPlaylist, router: router, showsPlaylists: $showsPlaylists)
            }
            .sheet(isPresented: $showsPlaylists) {
                PlaylistPickerSheet(video: video)
            }
    }
}

extension EnvironmentValues {
    /// The playlist a row belongs to, for downloading its neighbours.
    @Entry var playlistVideos: [YouTubeVideo] = []
}

struct VideoMenuItems: View {
    let video: YouTubeVideo
    var feedback: [FeedbackAction] = []
    var collaborators: [Collaborator] = []
    var onRemove: (() -> Void)?
    var onRemoveFromPlaylist: (() -> Void)?
    let router: Router
    @Binding var showsPlaylists: Bool
    @Environment(\.playlistVideos) private var playlistVideos

    var body: some View {
        ControlGroup {
            Button("Like", systemImage: "hand.thumbsup") {
                router.run { _ = try await InnerTubeClient.wooftube.like(videoId: video.videoId) }
            }
            Button("Add to Playlist", systemImage: "text.badge.plus") { showsPlaylists = true }
            if let url = URL(string: "https://www.youtube.com/watch?v=\(video.videoId)") {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .controlGroupStyle(.compactMenu)

        Section {
            Button("Play Next", systemImage: "text.insert") { router.playNext(video) }
            Button("Add to Queue", systemImage: "text.append") { router.addToQueue(video) }
        }

        Section {
            Button("Save to Watch Later", systemImage: "clock") {
                router.run { try await PlaylistActions.add(video.videoId, to: YouTubeFeeds.watchLaterPlaylistId) }
            }
            if let item = DownloadStore.shared.items.first(where: { $0.id == video.videoId }) {
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    DownloadStore.shared.delete(item)
                }
            } else {
                Button("Download", systemImage: "arrow.down.to.line") {
                    router.run { try await DownloadStore.shared.download(video, from: playlistVideos, maxHeight: router.maxHeight) }
                }
            }
            if let onRemoveFromPlaylist {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive, action: onRemoveFromPlaylist)
            }
            if !feedback.isEmpty {
                Menu("More", systemImage: "ellipsis.circle") {
                    ForEach(feedback, id: \.token) { action in
                        Button(action.title) {
                            onRemove?()
                            router.run {
                                _ = try await YouTubeAPI.post("feedback", body: ["feedbackTokens": [action.token]])
                            }
                        }
                    }
                }
            }
            if collaborators.count > 1 {
                Menu("Go To", systemImage: "arrow.forward.circle") {
                    ForEach(collaborators) { creator in
                        Button(creator.name, systemImage: "person.crop.circle") {
                            router.openChannel(creator.channelId)
                        }
                    }
                }
            } else if let channelId = video.channelId {
                Menu("Go To", systemImage: "arrow.forward.circle") {
                    Button(video.channelTitle ?? "Channel", systemImage: "person.crop.circle") {
                        router.openChannel(channelId)
                    }
                }
            }
        }
    }
}

struct PlaylistOption: Identifiable {
    let id: String
    let title: String
    var thumbnail: String?
    var count: String?
    var containsVideo: Bool
}

enum PlaylistActions {
    static func add(_ videoId: String, to playlistId: String) async throws {
        _ = try await InnerTubeClient.wooftube.editPlaylist(
            playlistId: playlistId,
            actions: [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]]
        )
    }

    static func remove(_ videoId: String, from playlistId: String) async throws {
        _ = try await InnerTubeClient.wooftube.editPlaylist(
            playlistId: playlistId,
            actions: [["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": videoId]]
        )
    }

    /// Your playlists, Watch Later included, and whether each one has this video.
    static func options(for videoId: String) async -> [PlaylistOption] {
        guard let json = try? await YouTubeAPI.post("playlist/get_add_to_playlist", body: ["videoIds": [videoId], "excludeWatchLater": false]),
              let rows = JSON.first("playlists", in: json) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let option = row["playlistAddToOptionRenderer"] as? [String: Any],
                  let id = option["playlistId"] as? String,
                  let title = JSON.text(option["title"]) else { return nil }
            return PlaylistOption(id: id, title: title, containsVideo: option["containsSelectedVideos"] as? String == "ALL")
        }
    }
}

/// Woof Music's Add to Playlist sheet. Tapping a playlist again takes the video out.
struct PlaylistPickerSheet: View {
    let video: YouTubeVideo
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistOption] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    LoadingMediaRows(isCircular: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if playlists.isEmpty {
                    ContentUnavailableView("No Playlists", systemImage: "list.bullet.rectangle", description: Text("Create one to start collecting videos."))
                } else {
                    List(playlists) { playlist in
                        Button {
                            toggle(playlist)
                        } label: {
                            HStack(spacing: Layout.rowSpacing) {
                                MediaListRow(url: playlist.thumbnail, title: playlist.title, subtitle: playlist.count)
                                if playlist.containsVideo {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .accessibilityAddTraits(playlist.containsVideo ? .isSelected : [])
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: Layout.screenPadding, bottom: 0, trailing: Layout.screenPadding))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Playlist", systemImage: "plus") {
                        newTitle = ""
                        isCreating = true
                    }
                }
            }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Playlist Name", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createAndAdd() }
            } message: {
                Text("Adds “\(video.title)” once created.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    /// YouTube says which playlists have the video, and the Library page has their covers.
    private func load() async {
        let options = await PlaylistActions.options(for: video.videoId)
        let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
        let library = json.map { YouTubeFeedParser.playlists(in: $0) } ?? []
        if options.isEmpty {
            playlists = library.map { PlaylistOption(id: $0.playlistId, title: $0.title, thumbnail: $0.thumbnailURL, count: $0.videoCountText, containsVideo: false) }
        } else {
            playlists = options.map { option in
                var option = option
                let match = library.first { $0.playlistId == option.id }
                option.thumbnail = match?.thumbnailURL
                option.count = match?.videoCountText
                return option
            }
        }
        isLoading = false
    }

    private func createAndAdd() {
        let title = newTitle
        router.run {
            let json = try await InnerTubeClient.wooftube.createPlaylist(title: title)
            guard let id = JSON.string("playlistId", in: json) else { return }
            try await PlaylistActions.add(video.videoId, to: id)
            playlists.insert(PlaylistOption(id: id, title: title, count: "1 video", containsVideo: true), at: 0)
        }
    }

    private func toggle(_ playlist: PlaylistOption) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let target = !playlist.containsVideo
        playlists[index].containsVideo = target
        router.run {
            if target {
                try await PlaylistActions.add(video.videoId, to: playlist.id)
            } else {
                try await PlaylistActions.remove(video.videoId, from: playlist.id)
            }
            if playlist.id == YouTubeFeeds.watchLaterPlaylistId, router.current?.videoId == video.videoId {
                router.setDetails { $0.isInWatchLater = target }
            }
        }
    }
}
