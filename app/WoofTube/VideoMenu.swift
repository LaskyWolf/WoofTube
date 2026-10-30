import SwiftUI
import SwiftyTube

extension View {
    /// The long press menu. Same layout as Woof Music: actions row, queue, then the rest.
    func videoMenu(_ video: YouTubeVideo, feedback: [FeedbackAction] = [], onRemove: (() -> Void)? = nil) -> some View {
        modifier(VideoMenuModifier(video: video, feedback: feedback, onRemove: onRemove))
    }
}

private struct VideoMenuModifier: ViewModifier {
    let video: YouTubeVideo
    let feedback: [FeedbackAction]
    let onRemove: (() -> Void)?
    @EnvironmentObject private var router: Router
    @State private var showsPlaylists = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                VideoMenuItems(video: video, feedback: feedback, onRemove: onRemove, router: router, showsPlaylists: $showsPlaylists)
            }
            .sheet(isPresented: $showsPlaylists) {
                PlaylistPickerSheet(video: video)
            }
    }
}

struct VideoMenuItems: View {
    let video: YouTubeVideo
    var feedback: [FeedbackAction] = []
    var onRemove: (() -> Void)?
    let router: Router
    @Binding var showsPlaylists: Bool

    var body: some View {
        ControlGroup {
            Button("Like", systemImage: "hand.thumbsup") {
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
            if let channelId = video.channelId {
                Menu("Go To", systemImage: "arrow.right.circle") {
                    Button(video.channelTitle ?? "Channel", systemImage: "person.crop.circle") {
                        router.openChannel(channelId)
                    }
                }
            }
        }
    }
}

enum PlaylistActions {
    static func add(_ videoId: String, to playlistId: String) async throws {
        _ = try await InnerTubeClient.wooftube.editPlaylist(
            playlistId: playlistId,
            actions: [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]]
        )
    }
}

struct PlaylistPickerSheet: View {
    let video: YouTubeVideo
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [YouTubePlaylist] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List(playlists, id: \.playlistId) { playlist in
                Button(playlist.title) {
                    router.run { try await PlaylistActions.add(video.videoId, to: playlist.playlistId) }
                    dismiss()
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
            let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
            playlists = json.map { YouTubeFeedParser.playlists(in: $0) } ?? []
            isLoading = false
        }
    }
}
