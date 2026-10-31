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

struct VideoMenuItems: View {
    let video: YouTubeVideo
    var feedback: [FeedbackAction] = []
    var collaborators: [Collaborator] = []
    var onRemove: (() -> Void)?
    var onRemoveFromPlaylist: (() -> Void)?
    let router: Router
    @Binding var showsPlaylists: Bool

    var body: some View {
        ControlGroup {
            Button("Like", systemImage: "hand.thumbsup") {
                DownloadStore.shared.downloadIfLikesSave(video, maxHeight: router.maxHeight)
                router.run { _ = try await InnerTubeClient.wooftube.like(videoId: video.videoId) }
            }
            Button("Save to Playlist", systemImage: "text.badge.plus") { showsPlaylists = true }
            if let url = URL(string: "https://www.youtube.com/watch?v=\(video.videoId)") {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .controlGroupStyle(.compactMenu)

        Section {
            Button("Play Next", systemImage: "text.insert") { router.playNext(video) }
            Button("Add to Queue", systemImage: "list.bullet") { router.addToQueue(video) }
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
                    router.run { try await DownloadStore.shared.download(video, maxHeight: router.maxHeight) }
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
                Menu("Go To", systemImage: "arrow.right.circle") {
                    ForEach(collaborators) { creator in
                        Button(creator.name, systemImage: "person.crop.circle") {
                            router.openChannel(creator.channelId)
                        }
                    }
                }
            } else if let channelId = video.channelId {
                Menu("Go To", systemImage: "arrow.right.circle") {
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

struct PlaylistPickerSheet: View {
    let video: YouTubeVideo
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistOption] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List(playlists) { playlist in
                Button {
                    toggle(playlist)
                } label: {
                    HStack {
                        Text(playlist.title).foregroundStyle(.primary)
                        Spacer()
                        if playlist.containsVideo {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
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
            .navigationTitle("Save to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            playlists = await PlaylistActions.options(for: video.videoId)
            if playlists.isEmpty, let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation") {
                playlists = YouTubeFeedParser.playlists(in: json).map {
                    PlaylistOption(id: $0.playlistId, title: $0.title, containsVideo: false)
                }
            }
            isLoading = false
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
