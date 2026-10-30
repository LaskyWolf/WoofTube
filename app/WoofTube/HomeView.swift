import SwiftUI
import SwiftyTube

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @State private var videos: [YouTubeVideo] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List(videos, id: \.videoId) { video in
                NavigationLink(value: video) {
                    VideoRow(video: video)
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay { placeholder }
            .navigationTitle("Home")
            .navigationDestination(for: YouTubeVideo.self) { PlayerScreen(video: $0) }
            .toolbar {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await session.signOut() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if videos.isEmpty {
            if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Videos", systemImage: "play.rectangle")
                } description: {
                    Text(errorText ?? "YouTube returned an empty Home feed. Pull down to try again.")
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let json = try await InnerTubeClient.wooftube.browse(browseId: YouTubeFeeds.home)
            videos = YouTubeFeedParser.videos(in: json).filter { !$0.isShort }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct VideoRow: View {
    let video: YouTubeVideo

    private var details: String {
        [video.channelTitle, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.secondarySystemFill)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))

            Text(video.title)
                .font(.headline)
                .lineLimit(2)
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }
}
