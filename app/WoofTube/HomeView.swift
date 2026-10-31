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

    var hasMore: Bool { nextToken != nil }

    /// Every video on the page, including those inside shelves.
    var videos: [YouTubeVideo] {
        items.flatMap { item -> [YouTubeVideo] in
            switch item {
            case .video(let video, _): return [video]
            case .shelf(_, let videos): return videos
            default: return []
            }
        }
    }

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
    /// Shows a + button when set, for the Library's new playlist.
    var onAdd: (() -> Void)?
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            HStack(spacing: Layout.rowSpacing) {
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("New Playlist")
                }
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
    func tabRoot(title: String, onAdd: (() -> Void)? = nil) -> some View {
        safeAreaBar(edge: .top, spacing: 0) {
            TabHeader(title: title, onAdd: onAdd).background(Color(.systemBackground))
        }
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
                Subscriptions.shared.add(model.videos.compactMap(\.channelId))
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
            LoadingRows(isCompact: isCompact)
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
    /// Set on a playlist the user can edit, to offer removing videos.
    var editablePlaylistId: String?
    @EnvironmentObject private var router: Router

    var body: some View {
        ForEach(model.items) { item in
            row(item)
                .task { await model.loadMore(after: item) }
        }
    }

    private func removal(of item: FeedItem, extras: VideoExtras) -> (() -> Void)? {
        guard let playlistId = editablePlaylistId, let setVideoId = extras.setVideoId else { return nil }
        return {
            model.remove(item)
            router.run {
                _ = try await InnerTubeClient.wooftube.editPlaylist(
                    playlistId: playlistId,
                    actions: [["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId]]
                )
            }
        }
    }

    @ViewBuilder
    private func row(_ item: FeedItem) -> some View {
        switch item {
        case .video(let video, let extras):
            VideoButton(video: video, extras: extras, isCompact: isCompact, onRemove: { model.remove(item) }, onRemoveFromPlaylist: removal(of: item, extras: extras))
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
    var extras = VideoExtras()
    var isCompact = false
    var onRemove: (() -> Void)?
    var onRemoveFromPlaylist: (() -> Void)?
    @EnvironmentObject private var router: Router

    var body: some View {
        Group {
            if isCompact {
                Button {
                    router.play(video)
                } label: {
                    CompactVideoRow(video: video, extras: extras)
                }
                .buttonStyle(RowPressStyle())
            } else {
                VideoRow(video: video, extras: extras)
            }
        }
        .videoMenu(video, feedback: extras.feedback, collaborators: extras.collaborators, onRemove: onRemove, onRemoveFromPlaylist: onRemoveFromPlaylist)
    }
}

/// Separate buttons rather than one around the whole row, so the avatar can open the channel.
struct VideoRow: View {
    let video: YouTubeVideo
    var extras = VideoExtras()
    @EnvironmentObject private var router: Router

    private var details: String {
        [video.channelTitle, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Button {
                router.play(video)
            } label: {
                Thumbnail(url: video.thumbnailURL, videoId: video.videoId)
                    .overlay { WatchProgressLine(video: video, extras: extras) }
                    .overlay(alignment: .bottomTrailing) { VideoBadge(video: video, extras: extras) }
                    .overlay(alignment: .topLeading) { NewBadge(video: video, extras: extras) }
                    .clipShape(.rect(cornerRadius: Layout.tileRadius))
            }
            .buttonStyle(RowPressStyle())
            HStack(alignment: .top, spacing: Layout.rowSpacing) {
                avatar
                Button {
                    router.play(video)
                } label: {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                            Text(video.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            VoteLine(videoId: video.videoId)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(RowPressStyle())
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if extras.collaborators.count > 1 {
            Menu {
                ForEach(extras.collaborators) { creator in
                    Button(creator.name, systemImage: "person.crop.circle") {
                        router.openChannel(creator.channelId)
                    }
                }
            } label: {
                AvatarStack(urls: extras.collaborators.map(\.avatar), size: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Creators")
        } else if let url = video.channelAvatarURL {
            if let id = video.channelId {
                Button {
                    router.openChannel(id)
                } label: {
                    Avatar(url: url, size: 36)
                        // Reaches 44 pt, using the gap around the avatar.
                        .contentShape(Circle().inset(by: -4))
                }
                .buttonStyle(ZoomPressStyle())
                .accessibilityLabel("Open \(video.channelTitle ?? "Channel")")
            } else {
                Avatar(url: url, size: 36)
            }
        }
    }
}

/// Marks a video from a channel you follow, published under a day ago and not started yet.
private struct NewBadge: View {
    let video: YouTubeVideo
    let extras: VideoExtras
    var isCompact = false
    @ObservedObject private var subscriptions = Subscriptions.shared

    private var isFromFollowedChannel: Bool {
        video.channelId.map { subscriptions.ids.contains($0) } == true
            || extras.collaborators.contains { subscriptions.ids.contains($0.channelId) }
    }

    var body: some View {
        if video.isRecent, !video.isLive, !extras.isUpcoming, isFromFollowedChannel,
           extras.progress == nil, WatchPositions.progress(of: video) == nil {
            Text("New")
                .font((isCompact ? Font.caption2 : Font.caption).weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, isCompact ? Layout.cardSpacing : Layout.rowPadding)
                .padding(.vertical, 2)
                .background(.tint, in: .rect(cornerRadius: Layout.rowPadding, style: .continuous))
                .padding(isCompact ? Layout.cardSpacing : Layout.rowPadding)
                .allowsHitTesting(false)
        }
    }
}

/// The time on a thumbnail. It stays black, because the accent color marks what you can act on.
private struct VideoBadge: View {
    let video: YouTubeVideo
    let extras: VideoExtras
    var isCompact = false

    private var text: String? {
        if video.isLive { return "LIVE" }
        if extras.isUpcoming { return "UPCOMING" }
        return video.durationSeconds.flatMap { $0 > 0 ? Double($0).clockText : nil }
    }

    var body: some View {
        if let text {
            Text(text)
                .font((isCompact ? Font.caption2 : Font.caption).weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, isCompact ? Layout.cardSpacing : Layout.rowPadding)
                .padding(.vertical, 2)
                .background(video.isLive ? Color.red : Color.black.opacity(0.78), in: .rect(cornerRadius: Layout.rowPadding, style: .continuous))
                .padding(isCompact ? Layout.cardSpacing : Layout.rowPadding)
                .allowsHitTesting(false)
        }
    }
}

/// Likes and dislikes under a video card. Waits a moment, so rows scrolled past don't ask for them.
private struct VoteLine: View {
    let videoId: String
    @AppStorage(DislikeCounts.enabledKey) private var isEnabled = true
    @State private var votes: VoteCounts?

    var body: some View {
        if isEnabled {
            HStack(spacing: Layout.rowPadding) {
                Label(votes?.likes.compactText ?? "–", systemImage: "hand.thumbsup")
                Text("|").foregroundStyle(.tertiary)
                Label(votes?.dislikes.compactText ?? "–", systemImage: "hand.thumbsdown")
            }
            .labelStyle(VoteLabelStyle())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(votes == nil ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(votes.map { "\($0.likes.compactText) likes, \($0.dislikes.compactText) dislikes" } ?? "")
            .task(id: videoId) {
                votes = DislikeCounts.cached(videoId: videoId)
                guard votes == nil else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                votes = await DislikeCounts.votes(videoId: videoId)
            }
        }
    }
}

private struct VoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// How much of the video was watched, along the bottom of its thumbnail.
struct WatchProgressLine: View {
    let video: YouTubeVideo
    let extras: VideoExtras

    var body: some View {
        if let progress = extras.progress ?? WatchPositions.progress(of: video) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(.tint)
                        .frame(width: geometry.size.width * progress, height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Woof Music's playlist row, with a 16:9 cover.
struct CompactVideoRow: View {
    let video: YouTubeVideo
    var extras = VideoExtras()

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            CoverImage(url: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")
                .frame(width: 112, height: 63)
                .overlay { WatchProgressLine(video: video, extras: extras) }
                .overlay(alignment: .bottomTrailing) { VideoBadge(video: video, extras: extras, isCompact: true) }
                .overlay(alignment: .topLeading) { NewBadge(video: video, extras: extras, isCompact: true) }
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
        }
        .contentShape(.rect)
    }
}

/// The shape of the feed while it loads, so the page doesn't jump when the videos arrive.
struct LoadingRows: View {
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? Layout.rowSpacing : Layout.rowSpacing * 2) {
            ForEach(0..<(isCompact ? 8 : 4), id: \.self) { _ in
                if isCompact {
                    HStack(spacing: Layout.rowSpacing) {
                        ShimmerBlock(width: 112, height: 63, radius: Layout.cardRadius)
                        lines
                    }
                } else {
                    VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                        ShimmerFill(radius: Layout.tileRadius).aspectRatio(16 / 9, contentMode: .fit)
                        HStack(alignment: .top, spacing: Layout.rowSpacing) {
                            ShimmerBlock(width: 36, height: 36, radius: 18)
                            lines
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.rowSpacing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .shimmerClock()
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            ShimmerBlock(width: isCompact ? 170 : 240, height: 14)
            ShimmerBlock(width: 110, height: 12)
        }
    }
}

struct Thumbnail: View {
    let url: String?
    let videoId: String
    var aspect: CGFloat = 16 / 9

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { CachedImage(url: url ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg") }
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
    @State private var isLiked: Bool?
    @State private var votedChoice: String?

    private var showsLiked: Bool { isLiked ?? post.isLiked }

    private func perform(_ action: String) {
        router.run { _ = try await YouTubeAPI.post("comment/perform_comment_action", body: ["actions": [action]]) }
    }

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
            ForEach(post.pollChoices, id: \.title) { choice in
                let isVoted = votedChoice == choice.title || (votedChoice == nil && choice.isSelected)
                Button {
                    guard let action = choice.action else { return }
                    votedChoice = choice.title
                    perform(action)
                } label: {
                    HStack {
                        Text(choice.title).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if isVoted {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .font(.subheadline)
                    .padding(Layout.rowSpacing)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Layout.tileRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: Layout.screenPadding) {
                if let likes = post.likes {
                    Button {
                        guard let action = showsLiked ? post.unlikeAction : post.likeAction else { return }
                        isLiked = !showsLiked
                        perform(action)
                    } label: {
                        Label(likes, systemImage: showsLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
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
            .overlay { CachedImage(url: url) }
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
        HStack(spacing: Layout.menuRowSpacing) {
            Avatar(url: channel.thumbnailURL, size: Layout.artSmall)
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                Text(channel.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subscribers = channel.subscriberCountText {
                    Text(subscribers)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct Avatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        CachedImage(url: url)
        .frame(width: size, height: size)
        .background {
            Color(.secondarySystemFill)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
        }
        .clipShape(.circle)
    }
}
