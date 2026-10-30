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

/// Loads a feed and its next pages for every list in the app.
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
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
            items = FeedParser.items(in: json)
            if !keepChips { chips = Self.parseChips(json) }
            nextToken = YouTubeFeedParser.continuation(in: json)
            if case .search(let query) = source { nextQuery = query } else { nextQuery = nil }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func loadMore(after item: FeedItem) async {
        guard item.id == items.last?.id, !isLoading, let token = nextToken else { return }
        isLoading = true
        defer { isLoading = false }
        nextToken = nil
        let tube = InnerTubeClient.wooftube
        guard let json = try? await (nextQuery != nil
            ? tube.search(query: nextQuery ?? "", continuation: token)
            : tube.browse(continuation: token)) else { return }
        let known = Set(items.map(\.id))
        items += FeedParser.items(in: json).filter { !known.contains($0.id) }
        nextToken = YouTubeFeedParser.continuation(in: json)
    }

    func remove(_ item: FeedItem) {
        items.removeAll { $0.id == item.id }
    }

    /// The chip YouTube marks as selected is "All", which is simply the page itself.
    private static func parseChips(_ json: [String: Any]) -> [FeedChip] {
        guard let bar = JSON.first("feedFilterChipBarRenderer", in: json) as? [String: Any],
              let contents = bar["contents"] as? [[String: Any]] else { return [] }
        return contents.compactMap { item in
            guard let chip = item["chipCloudChipRenderer"] as? [String: Any],
                  chip["isSelected"] as? Bool != true,
                  let title = JSON.text(chip["text"]) else { return nil }
            return FeedChip(title: title, token: JSON.string("token", in: chip["navigationEndpoint"]))
        }
    }
}

enum HeaderRoute: Hashable {
    case notifications, settings
}

/// Woof Music's TabHeaderView: the title, then the bell and the profile on one line.
struct TabHeader: View {
    let title: String
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle.bold())
            Spacer()
            HStack(spacing: 2) {
                NavigationLink(value: HeaderRoute.notifications) {
                    Image(systemName: "bell")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .topTrailing) { badge }
                        .contentShape(.rect)
                }
                .accessibilityLabel(session.unseenNotifications > 0 ? "Notifications, \(session.unseenNotifications) unread" : "Notifications")

                NavigationLink(value: HeaderRoute.settings) {
                    Avatar(url: session.account?.thumbnailUrl, size: 28)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Settings")
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, Layout.screenPadding)
        .padding(.trailing, Layout.chipSpacing)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var badge: some View {
        if session.unseenNotifications > 0 {
            Text(session.unseenNotifications > 9 ? "9+" : "\(session.unseenNotifications)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(.tint, in: .capsule)
                .offset(x: -2, y: 4)
        }
    }
}

extension View {
    /// For the first screen of a tab, which shows TabHeader instead of a navigation bar.
    func tabRoot() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HeaderRoute.self) { route in
                switch route {
                case .notifications: NotificationsView()
                case .settings: SettingsView()
                }
            }
    }
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var model = FeedModel()
    @State private var selectedChip: String?

    var body: some View {
        NavigationStack {
            FeedContent(model: model, retry: { await reload() }) {
                TabHeader(title: "Home")
                if !model.chips.isEmpty {
                    chipBar
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
            .tabRoot()
            .task {
                await session.refreshUnseenNotifications()
                if model.items.isEmpty { await model.load(.browse(YouTubeFeeds.home)) }
            }
        }
    }

    private func reload() async {
        selectedChip = nil
        await model.load(.browse(YouTubeFeeds.home))
    }

    /// Spacing and colours from Woof Music's FilterChipBar. Tapping the selected chip clears it.
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Layout.chipSpacing) {
                ForEach(model.chips) { chip in
                    let isSelected = selectedChip == chip.title
                    Button {
                        selectedChip = isSelected ? nil : chip.title
                        Task {
                            if !isSelected, let token = chip.token {
                                await model.load(.continuation(token), keepChips: true)
                            } else {
                                await model.load(.browse(YouTubeFeeds.home), keepChips: true)
                            }
                        }
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, Layout.screenPadding)
                            .padding(.vertical, Layout.chipSpacing)
                            .background {
                                if isSelected {
                                    Capsule().fill(.tint)
                                } else {
                                    Capsule().fill(Color(.systemGray5))
                                }
                            }
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

struct SubsView: View {
    @StateObject private var model = FeedModel()

    var body: some View {
        NavigationStack {
            FeedContent(model: model, retry: { await model.load(.browse(YouTubeFeeds.subscriptions)) }) {
                TabHeader(title: "Subs")
            }
            .tabRoot()
            .task {
                if model.items.isEmpty { await model.load(.browse(YouTubeFeeds.subscriptions)) }
            }
        }
    }
}

/// A list that loads itself from one source.
struct FeedList: View {
    let source: FeedSource
    @StateObject private var model = FeedModel()

    var body: some View {
        FeedContent(model: model, retry: { await model.load(source) }) { EmptyView() }
            .task(id: source) {
                if model.items.isEmpty { await model.load(source) }
            }
    }
}

struct FeedContent<Header: View>: View {
    @ObservedObject var model: FeedModel
    let retry: () async -> Void
    @ViewBuilder let header: () -> Header

    var body: some View {
        List {
            header()
            if model.items.isEmpty {
                emptyState
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            ForEach(model.items) { item in
                row(item)
                    .listRowSeparator(.hidden)
                    .task { await model.loadMore(after: item) }
            }
        }
        .listStyle(.plain)
        .refreshable { await retry() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            LoadingRows()
        } else {
            ContentUnavailableView {
                Label(model.errorText == nil ? "Nothing Here" : "Couldn't Load", systemImage: "play.rectangle")
            } description: {
                Text(model.errorText ?? "YouTube returned nothing here.")
            } actions: {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.glass)
            }
            .padding(.vertical, 48)
        }
    }

    @ViewBuilder
    private func row(_ item: FeedItem) -> some View {
        switch item {
        case .video(let video, let feedback):
            VideoButton(video: video, feedback: feedback) { model.remove(item) }
                .listRowInsets(Layout.rowInsets)
        case .shorts(let title, let videos):
            ShortsShelf(title: title, videos: videos)
                .listRowInsets(EdgeInsets())
        case .shelf(let title, let videos):
            VideoShelf(title: title, videos: videos)
                .listRowInsets(EdgeInsets())
        case .post(let post):
            PostRow(post: post)
                .listRowInsets(Layout.rowInsets)
        case .playlist(let playlist):
            NavigationLink {
                FeedList(source: .browse(YouTubeFeeds.playlistBrowseId(playlist.playlistId)))
                    .navigationTitle(playlist.title)
            } label: {
                PlaylistRow(playlist: playlist)
            }
            .listRowInsets(Layout.rowInsets)
        case .channel(let channel):
            if let id = channel.channelId {
                NavigationLink {
                    ChannelView(channelId: id)
                } label: {
                    ChannelRow(channel: channel)
                }
                .listRowInsets(Layout.rowInsets)
            }
        }
    }
}

struct VideoButton: View {
    let video: YouTubeVideo
    var feedback: [FeedbackAction] = []
    var onRemove: (() -> Void)?
    @EnvironmentObject private var router: Router

    var body: some View {
        Button {
            router.play(video)
        } label: {
            VideoRow(video: video)
        }
        .buttonStyle(RowPressStyle())
        .videoMenu(video, feedback: feedback, onRemove: onRemove)
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
            Thumbnail(url: video.thumbnailURL, videoId: video.videoId)
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
                Spacer(minLength: 0)
                if video.isLive {
                    Text("LIVE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                } else if let seconds = video.durationSeconds, seconds > 0 {
                    Text(Double(seconds).clockText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
        }
        .padding(Layout.screenPadding)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

struct Thumbnail: View {
    let url: String?
    let videoId: String
    var aspect: CGFloat = 16 / 9
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if redactionReasons.isEmpty {
                    AsyncImage(url: URL(string: url ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
            }
            .clipShape(.rect(cornerRadius: Layout.tileRadius))
    }
}

private struct ShelfTitle: View {
    let title: String?

    var body: some View {
        if let title {
            Text(title)
                .font(.headline)
                .padding(.horizontal, Layout.screenPadding)
        }
    }
}

private struct ShortsShelf: View {
    let title: String?
    let videos: [YouTubeVideo]
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ShelfTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(videos, id: \.videoId) { video in
                        Button {
                            router.play(video)
                        } label: {
                            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                Thumbnail(url: video.thumbnailURL, videoId: video.videoId, aspect: 9 / 16)
                                Text(video.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(width: 150)
                            .contentShape(.rect)
                        }
                        .buttonStyle(RowPressStyle())
                        .videoMenu(video)
                    }
                }
                .padding(.horizontal, Layout.screenPadding)
            }
        }
        .padding(.vertical, Layout.rowSpacing)
    }
}

private struct VideoShelf: View {
    let title: String?
    let videos: [YouTubeVideo]

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ShelfTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(videos, id: \.videoId) { video in
                        VideoButton(video: video).frame(width: 280)
                    }
                }
                .padding(.horizontal, Layout.screenPadding)
            }
        }
        .padding(.vertical, Layout.rowSpacing)
    }
}

private struct PostRow: View {
    let post: CommunityPost
    @EnvironmentObject private var router: Router
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Button {
                if let id = post.channelId { router.openChannel(id) }
            } label: {
                HStack(spacing: Layout.rowSpacing) {
                    Avatar(url: post.authorAvatar, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let time = post.time {
                            Text(time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if !post.text.isEmpty {
                Text(post.text)
                    .font(.subheadline)
                    .lineLimit(isExpanded ? nil : 5)
                    .onTapGesture { isExpanded.toggle() }
            }
            images
            if let video = post.video {
                VideoButton(video: video)
            }
            ForEach(post.pollChoices, id: \.self) { choice in
                Text(choice)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Layout.rowSpacing)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Layout.tileRadius))
            }
            HStack(spacing: Layout.screenPadding) {
                if let likes = post.likes {
                    Label(likes, systemImage: "hand.thumbsup")
                }
                if let comments = post.comments {
                    Label(comments, systemImage: "bubble.left")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.tileRadius))
    }

    @ViewBuilder
    private var images: some View {
        if post.images.count == 1, let image = post.images.first {
            postImage(image)
        } else if post.images.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Layout.chipSpacing) {
                    ForEach(post.images, id: \.self) { image in
                        postImage(image).frame(width: 240)
                    }
                }
            }
        }
    }

    private func postImage(_ url: String) -> some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: url)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .clipShape(.rect(cornerRadius: Layout.tileRadius))
    }
}

private struct PlaylistRow: View {
    let playlist: YouTubePlaylist

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            AsyncImage(url: playlist.thumbnailURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.secondarySystemFill)
            }
            .frame(width: 96, height: 54)
            .clipShape(.rect(cornerRadius: Layout.thumbRadius))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let count = playlist.videoCountText {
                    Text(count).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
