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

/// Woof Music's TabHeaderView: the title, then 36 pt buttons 12 pt apart.
struct TabHeader: View {
    let title: String
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            HStack(spacing: Layout.rowSpacing) {
                NavigationLink(value: HeaderRoute.notifications) {
                    Image(systemName: "bell")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .overlay(alignment: .topTrailing) { badge }
                        .contentShape(.rect)
                }
                .accessibilityLabel(session.unseenNotifications > 0 ? "Notifications, \(session.unseenNotifications) unread" : "Notifications")

                NavigationLink(value: HeaderRoute.settings) {
                    Avatar(url: session.account?.thumbnailUrl, size: 28)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Settings")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
    }

    @ViewBuilder
    private var badge: some View {
        if session.unseenNotifications > 0 {
            Text(session.unseenNotifications > 9 ? "9+" : "\(session.unseenNotifications)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(.tint, in: .capsule)
                .offset(x: 2, y: -2)
        }
    }
}

extension View {
    /// For the first screen of a tab, which shows TabHeader instead of a navigation bar.
    func tabRoot(title: String) -> some View {
        safeAreaBar(edge: .top, spacing: 0) { TabHeader(title: title) }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HeaderRoute.self) { route in
                switch route {
                case .notifications: NotificationsView()
                case .settings: SettingsView()
                }
            }
    }
}

/// Woof Music's FilterChipBar.
struct FilterChips: View {
    let titles: [String]
    let selected: String?
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Layout.chipSpacing) {
                ForEach(titles, id: \.self) { title in
                    Button {
                        onTap(title)
                    } label: {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(selected == title ? Color.white : Color.primary)
                            .padding(.horizontal, Layout.screenPadding)
                            .padding(.vertical, Layout.rowPadding)
                            .frame(minHeight: Layout.controlHeight)
                            .background {
                                if selected == title {
                                    Capsule().fill(.tint)
                                } else {
                                    Capsule().fill(Color(.systemGray5))
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(ZoomPressStyle())
                }
            }
            .padding(.horizontal, Layout.screenPadding)
            .padding(.vertical, Layout.chipSpacing)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var model = FeedModel()
    @State private var selectedChip: String?

    var body: some View {
        NavigationStack {
            FeedContent(model: model, retry: { await reload() }) {
                if !model.chips.isEmpty {
                    FilterChips(titles: model.chips.map(\.title), selected: selectedChip, onTap: tapChip)
                }
            }
            .tabRoot(title: "Home")
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

    /// Tapping the selected chip clears it.
    private func tapChip(_ title: String) {
        let isSelected = selectedChip == title
        selectedChip = isSelected ? nil : title
        let token = model.chips.first { $0.title == title }?.token
        Task {
            if !isSelected, let token {
                await model.load(.continuation(token), keepChips: true)
            } else {
                await model.load(.browse(YouTubeFeeds.home), keepChips: true)
            }
        }
    }
}

struct SubsView: View {
    @StateObject private var model = FeedModel()

    var body: some View {
        NavigationStack {
            FeedContent(model: model, retry: { await model.load(.browse(YouTubeFeeds.subscriptions)) }) {
                EmptyView()
            }
            .tabRoot(title: "Subs")
            .task {
                if model.items.isEmpty { await model.load(.browse(YouTubeFeeds.subscriptions)) }
            }
        }
    }
}

/// A list that loads itself from one source.
struct FeedList: View {
    let source: FeedSource
    var isCompact = false
    @StateObject private var model = FeedModel()

    var body: some View {
        FeedContent(model: model, retry: { await model.load(source) }, isCompact: isCompact) { EmptyView() }
            .toolbar(.visible, for: .navigationBar)
            .task(id: source) {
                if model.items.isEmpty { await model.load(source) }
            }
    }
}

/// A ScrollView like Woof Music's pages: a List row fires every link inside it at once.
struct FeedContent<Header: View>: View {
    @ObservedObject var model: FeedModel
    let retry: () async -> Void
    var isCompact = false
    @ViewBuilder let header: () -> Header

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header()
                if model.items.isEmpty {
                    emptyState
                }
                FeedRows(model: model, isCompact: isCompact)
            }
        }
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
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 48)
        }
    }
}

struct FeedRows: View {
    @ObservedObject var model: FeedModel
    var isCompact = false
    @EnvironmentObject private var router: Router

    var body: some View {
        ForEach(model.items) { item in
            row(item)
                .task { await model.loadMore(after: item) }
        }
    }

    @ViewBuilder
    private func row(_ item: FeedItem) -> some View {
        switch item {
        case .video(let video, let feedback, let collaborators):
            VideoButton(video: video, feedback: feedback, collaborators: collaborators, isCompact: isCompact) { model.remove(item) }
                .padding(.horizontal, Layout.screenPadding)
                .padding(.vertical, isCompact ? Layout.rowPadding : Layout.rowSpacing)
        case .shorts(let title, let videos):
            ShortsShelf(title: title ?? "Shorts", videos: videos)
        case .shelf(let title, let videos):
            VideoShelf(title: title, videos: videos)
        case .post(let post):
            PostRow(post: post)
                .padding(.horizontal, Layout.screenPadding)
                .padding(.vertical, Layout.rowSpacing)
        case .playlist(let playlist):
            NavigationLink {
                PlaylistPage(title: playlist.title, playlistId: playlist.playlistId)
            } label: {
                MediaListRow(url: playlist.thumbnailURL, title: playlist.title, subtitle: playlist.videoCountText)
            }
            .buttonStyle(RowPressStyle())
            .padding(.horizontal, Layout.screenPadding)
        case .channel(let channel):
            if let id = channel.channelId {
                Button {
                    router.openChannel(id)
                } label: {
                    ChannelRow(channel: channel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(RowPressStyle())
                .padding(.horizontal, Layout.screenPadding)
                .padding(.vertical, Layout.rowPadding)
            }
        }
    }
}

struct VideoButton: View {
    let video: YouTubeVideo
    var feedback: [FeedbackAction] = []
    var collaborators: [Collaborator] = []
    var isCompact = false
    var onRemove: (() -> Void)?
    @EnvironmentObject private var router: Router

    var body: some View {
        Button {
            router.play(video)
        } label: {
            if isCompact {
                CompactVideoRow(video: video)
            } else {
                VideoRow(video: video, collaborators: collaborators)
            }
        }
        .buttonStyle(RowPressStyle())
        .videoMenu(video, feedback: feedback, collaborators: collaborators, onRemove: onRemove)
    }
}

struct VideoRow: View {
    let video: YouTubeVideo
    var collaborators: [Collaborator] = []

    private var details: String {
        [video.channelTitle, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Thumbnail(url: video.thumbnailURL, videoId: video.videoId)
            HStack(alignment: .top, spacing: Layout.rowSpacing) {
                if collaborators.count > 1 {
                    AvatarStack(urls: collaborators.map(\.avatar), size: 36)
                } else if let avatar = video.channelAvatarURL {
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

/// Woof Music's playlist row, with a 16:9 cover.
struct CompactVideoRow: View {
    let video: YouTubeVideo

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            CoverImage(url: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")
                .frame(width: 112, height: 63)
                .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let channel = video.channelTitle {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let seconds = video.durationSeconds, seconds > 0 {
                Text(Double(seconds).clockText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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

private struct ShortsShelf: View {
    let title: String
    let videos: [YouTubeVideo]
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(videos, id: \.videoId) { video in
                        Button {
                            router.openShorts(videos, start: video)
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
        .padding(.bottom, Layout.sectionGap)
    }
}

private struct VideoShelf: View {
    let title: String?
    let videos: [YouTubeVideo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SectionTitle(title: title)
            }
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

/// Overlapping avatars for a video with several creators.
struct AvatarStack: View {
    let urls: [String?]
    let size: CGFloat
    private static let maxShown = 3

    var body: some View {
        HStack(spacing: -size * 0.45) {
            ForEach(Array(urls.prefix(Self.maxShown).enumerated()), id: \.offset) { _, url in
                Avatar(url: url, size: size)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
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
