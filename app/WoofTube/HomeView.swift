import SwiftUI
import SwiftyTube

enum FeedSource: Hashable {
    case browse(String, params: String? = nil)
    case search(String)
    case continuation(String)

    func fetch() async throws -> [String: Any] {
        let tube = InnerTubeClient.wooftube
        switch self {
        case .browse(let id, let params):
            return try await tube.browse(browseId: id, params: params)
        case .search(let query):
            return try await tube.search(query: query)
        case .continuation(let token):
            return try await tube.browse(continuation: token)
        }
    }
}

struct FeedChip: Identifiable, Hashable {
    let title: String
    let token: String?
    var id: String { title }
}

/// Loads a feed and its next pages for every list of videos in the app.
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var videos: [YouTubeVideo] = []
    @Published private(set) var channels: [YouTubeChannel] = []
    @Published private(set) var chips: [FeedChip] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    private var nextToken: String?
    private var nextQuery: String?

    func load(_ source: FeedSource, keepChips: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let json = try await source.fetch()
            videos = YouTubeFeedParser.videos(in: json).filter { !$0.isShort }
            channels = YouTubeFeedParser.channels(in: json)
            if !keepChips { chips = Self.parseChips(json) }
            nextToken = YouTubeFeedParser.continuation(in: json)
            if case .search(let query) = source { nextQuery = query } else { nextQuery = nil }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func loadMore(after video: YouTubeVideo) async {
        guard video.videoId == videos.last?.videoId, !isLoading, let token = nextToken else { return }
        isLoading = true
        defer { isLoading = false }
        nextToken = nil
        let tube = InnerTubeClient.wooftube
        guard let json = try? await (nextQuery != nil
            ? tube.search(query: nextQuery ?? "", continuation: token)
            : tube.browse(continuation: token)) else { return }
        let known = Set(videos.map(\.videoId))
        videos += YouTubeFeedParser.videos(in: json).filter { !$0.isShort && !known.contains($0.videoId) }
        nextToken = YouTubeFeedParser.continuation(in: json)
    }

    private static func parseChips(_ json: [String: Any]) -> [FeedChip] {
        guard let bar = JSON.first("feedFilterChipBarRenderer", in: json) as? [String: Any],
              let contents = bar["contents"] as? [[String: Any]] else { return [] }
        return contents.compactMap { item in
            guard let chip = item["chipCloudChipRenderer"] as? [String: Any],
                  let title = JSON.text(chip["text"]) else { return nil }
            return FeedChip(title: title, token: JSON.string("token", in: chip["navigationEndpoint"]))
        }
    }
}

struct HomeView: View {
    @StateObject private var model = FeedModel()
    @State private var selectedChip: String?

    var body: some View {
        NavigationStack {
            FeedContent(model: model, retry: { await model.load(.browse(YouTubeFeeds.home)) }) {
                if !model.chips.isEmpty {
                    chipBar
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Home")
            .toolbar {
                NavigationLink {
                    NotificationsView()
                } label: {
                    Label("Notifications", systemImage: "bell")
                }
            }
            .task {
                if model.videos.isEmpty { await model.load(.browse(YouTubeFeeds.home)) }
            }
        }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Layout.chipSpacing) {
                ForEach(model.chips) { chip in
                    let isSelected = selectedChip == chip.title || (selectedChip == nil && chip.id == model.chips.first?.id)
                    Button {
                        selectedChip = chip.title
                        Task {
                            if let token = chip.token {
                                await model.load(.continuation(token), keepChips: true)
                            } else {
                                await model.load(.browse(YouTubeFeeds.home), keepChips: true)
                            }
                        }
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                            .padding(.horizontal, Layout.screenPadding)
                            .padding(.vertical, Layout.chipSpacing)
                            .background(isSelected ? Color.primary : Color(.secondarySystemFill), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(RowPressStyle())
                }
            }
            .padding(.horizontal, Layout.screenPadding)
            .padding(.vertical, Layout.chipSpacing)
        }
        .sensoryFeedback(.selection, trigger: selectedChip)
    }
}

/// A list of videos that loads itself from one source.
struct FeedList: View {
    let source: FeedSource
    @StateObject private var model = FeedModel()

    var body: some View {
        FeedContent(model: model, retry: { await model.load(source) }) { EmptyView() }
            .task(id: source) {
                if model.videos.isEmpty { await model.load(source) }
            }
    }
}

struct FeedContent<Header: View>: View {
    @ObservedObject var model: FeedModel
    let retry: () async -> Void
    @ViewBuilder let header: () -> Header
    @EnvironmentObject private var router: Router

    var body: some View {
        List {
            header()
            ForEach(model.channels, id: \.title) { channel in
                if let id = channel.channelId {
                    NavigationLink {
                        ChannelView(channelId: id)
                    } label: {
                        ChannelRow(channel: channel)
                    }
                }
            }
            ForEach(model.videos, id: \.videoId) { video in
                Button {
                    router.play(video)
                } label: {
                    VideoRow(video: video)
                }
                .buttonStyle(RowPressStyle())
                .listRowInsets(Layout.rowInsets)
                .listRowSeparator(.hidden)
                .task { await model.loadMore(after: video) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.videos.isEmpty, model.channels.isEmpty {
                if model.isLoading {
                    LoadingRows()
                } else {
                    ContentUnavailableView {
                        Label(model.errorText == nil ? "No Videos" : "Couldn't Load", systemImage: "play.rectangle")
                    } description: {
                        Text(model.errorText ?? "YouTube returned nothing here.")
                    } actions: {
                        Button("Try Again") { Task { await retry() } }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
        .refreshable { await retry() }
    }
}

struct VideoRow: View {
    let video: YouTubeVideo

    private var details: String {
        [video.channelTitle, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Thumbnail(video: video)
            HStack(alignment: .top, spacing: Layout.rowSpacing) {
                if let avatar = video.channelAvatarURL {
                    Avatar(url: avatar, size: 36)
                }
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    Text(video.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
    }
}

/// The shape of the feed while it loads, so the page doesn't jump when the videos arrive.
struct LoadingRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
            ForEach(0..<4, id: \.self) { index in
                VideoRow(video: YouTubeVideo(videoId: "loading\(index)", title: "Loading a video title that fills the line", channelTitle: "Channel name", viewCountText: "views"))
            }
            Spacer(minLength: 0)
        }
        .padding(Layout.screenPadding)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(Color(.systemBackground))
    }
}

struct Thumbnail: View {
    let video: YouTubeVideo
    @Environment(\.playerNamespace) private var playerNamespace
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if redactionReasons.isEmpty {
                    AsyncImage(url: URL(string: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let seconds = video.durationSeconds, seconds > 0 {
                    Text(Double(seconds).clockText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: .capsule)
                        .padding(Layout.chipSpacing)
                }
            }
            .clipShape(.rect(cornerRadius: Layout.tileRadius))
            .zoomSource(id: video.videoId, in: playerNamespace)
    }
}

struct ChannelRow: View {
    let channel: YouTubeChannel

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            Avatar(url: channel.thumbnailURL, size: 48)
            VStack(alignment: .leading) {
                Text(channel.title).font(.headline)
                if let subscribers = channel.subscriberCountText {
                    Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Avatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(.secondarySystemFill)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}
