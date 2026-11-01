import SwiftUI
import SwiftyTube

enum FeedSource: Hashable {
    case browse(String, params: String? = nil)
    case search(String, params: String? = nil)
    /// A search inside one page, such as a channel or the watch history.
    case scoped(browseId: String, params: String? = nil, query: String)
    case continuation(String)

    func fetch() async throws -> [String: Any] {
        let tube = InnerTubeClient.wooftube
        switch self {
        case .browse(let id, let params):
            return try await tube.browse(browseId: id, params: params)
        case .search(let query, let params):
            return try await tube.search(query: query, params: params)
        case .scoped(let browseId, let params, let query):
            var body: [String: Any] = ["browseId": browseId, "query": query]
            if let params { body["params"] = params }
            return try await YouTubeAPI.post("browse", body: body)
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
@Observable
final class FeedModel {
    private(set) var items: [FeedItem] = []
    private(set) var chips: [FeedChip] = []
    private(set) var isLoading = false
    /// A filter was picked and its videos are on the way, so the old ones give way to the loading rows.
    private(set) var isSwitching = false
    /// False while only the saved Home rows are showing.
    private(set) var didLoadFresh = false
    /// Each `load` gets a number, so an older answer knows it's too late.
    private var loadGeneration = 0
    private(set) var errorText: String?
    private var nextToken: String?
    private var nextQuery: String?
    private(set) var isHome = false
    /// Home keeps asking for pages until this many rows are new to the person.
    private static let freshRowsWanted = 8
    private static let pagesToSkip = 3

    var hasMore: Bool { nextToken != nil }
    var isSearch: Bool { nextQuery != nil }

    /// The same in page order, with Shorts too.
    var videosAndShorts: [YouTubeVideo] {
        items.flatMap { item -> [YouTubeVideo] in
            switch item {
            case .video(let video, _): return [video]
            case .shelf(_, let videos), .shorts(_, let videos): return videos
            default: return []
            }
        }
    }

    /// History videos the person stopped partway through, by YouTube's count or this phone's.
    var unfinished: [(video: YouTubeVideo, extras: VideoExtras)] {
        items.compactMap { item in
            guard case .video(let video, let extras) = item,
                  let progress = extras.progress ?? WatchPositions.progress(of: video),
                  progress > 0, progress < WatchPositions.finishedFraction else { return nil }
            return (video, extras)
        }
    }

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
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
                isSwitching = false
            }
        }
        do {
            let json = try await source.fetch()
            var page = await offMain { FeedParser.items(in: json) }
            guard generation == loadGeneration else { return }
            isHome = source == .browse(YouTubeFeeds.home)
            if isHome {
                let file = SavedHome.file
                await offMain { SavedHome.write(json, to: file) }
            }
            if !keepChips { chips = Self.parseChips(json) }
            nextToken = YouTubeFeedParser.continuation(in: json)
            if isHome {
                page = await freshHomeRows(from: page)
                guard generation == loadGeneration else { return }
            }
            if items.isEmpty {
                withAnimation(.easeOut(duration: 0.25)) { items = page }
            } else {
                withTransaction(\.disablesAnimations, true) { items = page }
            }
            if case .search(let query, _) = source { nextQuery = query } else { nextQuery = nil }
            errorText = nil
            didLoadFresh = true
        } catch {
            guard generation == loadGeneration else { return }
            errorText = error.localizedDescription
            if isSwitching { items = [] }
        }
    }

    func loadMore(after item: FeedItem) async {
        guard item.id == items.last?.id, !isLoading, nextToken != nil else { return }
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        let tube = InnerTubeClient.wooftube
        // A page of Home can hold only seen videos, and an empty result would stop the scrolling.
        for _ in 0...Self.pagesToSkip {
            guard let token = nextToken else { return }
            nextToken = nil
            guard let json = try? await (nextQuery != nil
                ? tube.search(query: nextQuery ?? "", continuation: token)
                : tube.browse(continuation: token)) else {
                if generation == loadGeneration { nextToken = token }
                return
            }
            guard generation == loadGeneration else { return }
            let known = Set(items.map(\.id))
            let page = await offMain { FeedParser.items(in: json) }
            let added = (isHome ? SeenVideos.removing(from: page) : page).filter { !known.contains($0.id) }
            items += added
            nextToken = YouTubeFeedParser.continuation(in: json)
            if !added.isEmpty { return }
        }
    }

    /// Real rows straight away. The next pages wait for the new answer, because these addresses may have expired.
    func showSavedHome() async {
        isLoading = true
        defer { isLoading = false }
        let file = SavedHome.file
        guard let json = await offMain({ SavedHome.read(file) }) else { return }
        let page = await offMain { FeedParser.items(in: json) }
        guard items.isEmpty else { return }
        isHome = true
        chips = Self.parseChips(json)
        let fresh = SeenVideos.removing(from: page)
        items = fresh.isEmpty ? page : fresh
    }

    /// Falls back to the page as it came, rather than showing nothing to someone who has seen it all.
    private func freshHomeRows(from page: [FeedItem]) async -> [FeedItem] {
        var fresh = SeenVideos.removing(from: page)
        var skipped = 0
        while fresh.count < Self.freshRowsWanted, skipped < Self.pagesToSkip, let token = nextToken,
              let json = try? await InnerTubeClient.wooftube.browse(continuation: token) {
            skipped += 1
            let more = await offMain { FeedParser.items(in: json) }
            nextToken = YouTubeFeedParser.continuation(in: json)
            let known = Set(fresh.map(\.id))
            fresh += SeenVideos.removing(from: more).filter { !known.contains($0.id) }
        }
        return fresh.isEmpty ? page : fresh
    }

    func beginSwitching() {
        isSwitching = true
    }

    func remove(_ item: FeedItem) {
        items.removeAll { $0.id == item.id }
    }

    /// The newest posts from these channels. YouTube has no feed of them, so this reads each channel's tab.
    func loadPosts(ofChannels ids: [String]) async {
        struct Page: @unchecked Sendable { let json: [String: Any]? }
        isLoading = true
        defer { isLoading = false }
        var pages: [Page] = []
        for start in stride(from: 0, to: ids.count, by: Self.postRequestsAtOnce) {
            let group = ids[start..<min(start + Self.postRequestsAtOnce, ids.count)]
            pages += await withTaskGroup(of: Page.self) { tasks in
                for id in group {
                    tasks.addTask { Page(json: try? await FeedSource.browse(id, params: Self.postsTab).fetch()) }
                }
                return await tasks.reduce(into: [Page]()) { $0.append($1) }
            }
        }
        let perChannel = Self.postsPerChannel
        let found = await offMain { [pages] in pages.compactMap(\.json).flatMap { FeedParser.items(in: $0).prefix(perChannel) } }
        items = found
            .filter { if case .post = $0 { return true } else { return false } }
            .sorted { Self.age(of: $0) < Self.age(of: $1) }
        nextToken = nil
        errorText = nil
    }

    private static let postsTab = "EgVwb3N0c_IGBAoCSgA%3D"
    private static let postRequestsAtOnce = 6
    private static let postsPerChannel = 3

    private static func age(of item: FeedItem) -> Int {
        guard case .post(let post) = item else { return .max }
        return secondsAgo(post.time ?? "")
    }

    /// Reads YouTube's "3 hours ago". Text it can't read sorts last.
    static func secondsAgo(_ text: String) -> Int {
        let units = [("second", 1), ("minute", 60), ("hour", 3600), ("day", 86400), ("week", 604800), ("month", 2592000), ("year", 31536000)]
        let words = text.lowercased().split(separator: " ")
        guard let count = words.compactMap({ Int($0) }).first,
              let unit = units.first(where: { unit in words.contains { $0.hasPrefix(unit.0) } }) else { return .max }
        return count * unit.1
    }

    /// Every page of a playlist.
    static func allVideos(ofPlaylist playlistId: String) async -> [YouTubeVideo] {
        let model = FeedModel()
        await model.load(.browse(YouTubeFeeds.playlistBrowseId(playlistId)))
        while model.hasMore, let last = model.items.last {
            await model.loadMore(after: last)
        }
        return model.videos
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
    @State private var addTaps = 0
    let title: String
    /// Shows a + button when set, for the Library's new playlist.
    var onAdd: (() -> Void)?
    /// Shows the Incognito button when set, for Search.
    var incognito: Binding<Bool>?
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            // The targets are 44 pt, so a small gap keeps the icons as far apart as they look.
            HStack(spacing: Layout.cardSpacing) {
                if let onAdd {
                    Button {
                        addTaps += 1
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .glyphMotion(.plusTurn, trigger: addTaps)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("New Playlist")
                }
                if let incognito {
                    Button { incognito.wrappedValue.toggle() } label: {
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .foregroundStyle(incognito.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .glyphMotion(incognito.wrappedValue ? .glassesOn : .glassesOff, trigger: incognito.wrappedValue)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel(incognito.wrappedValue ? "Turn Off Incognito" : "Turn On Incognito")
                    .sensoryFeedback(.selection, trigger: incognito.wrappedValue)
                }
                NavigationLink(value: HeaderRoute.notifications) {
                    Image(systemName: "bell")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .glyphMotion(session.unseenNotifications > 0 ? .bellRing : nil, trigger: session.unseenNotifications)
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .topTrailing) { badge }
                        .contentShape(.rect)
                }
                .accessibilityLabel(session.unseenNotifications > 0 ? "Notifications, \(session.unseenNotifications) unread" : "Notifications")

                NavigationLink(value: HeaderRoute.settings) {
                    Avatar(url: session.account?.thumbnailUrl, size: 28)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .frame(width: 44, height: 44)
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
                .offset(x: -2, y: 2)
        }
    }
}

extension View {
    /// For the first screen of a tab, which shows TabHeader instead of a navigation bar.
    func tabRoot(title: String, tab: AppTab, onAdd: (() -> Void)? = nil, incognito: Binding<Bool>? = nil) -> some View {
        safeAreaBar(edge: .top, spacing: 0) {
            TabHeader(title: title, onAdd: onAdd, incognito: incognito).background(Color(.systemBackground))
        }
            .toolbar(.hidden, for: .navigationBar)
            .modifier(TabDestinations(tab: tab))
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
            .animation(.smooth(duration: 0.25), value: selected)
            .padding(.horizontal, Layout.screenPadding)
            .padding(.vertical, Layout.chipSpacing)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @State private var model = FeedModel()
    @State private var history = FeedModel()
    @State private var selectedChip: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            FeedContent(model: model, retry: { await reload() }, loading: .home) {
                if !model.chips.isEmpty {
                    FilterChips(titles: model.chips.map(\.title), selected: selectedChip, onTap: tapChip)
                } else if model.isLoading {
                    LoadingChips()
                }
                KeepWatchingCard(history: history)
            }
            .tabRoot(title: "Home", tab: .home)
            // Separate tasks, so each part of the page appears as soon as its own answer arrives.
            .task { await session.refreshUnseenNotifications() }
            .task {
                guard !model.didLoadFresh else { return }
                if model.items.isEmpty { await model.showSavedHome() }
                await model.load(.browse(YouTubeFeeds.home))
            }
            .task { if history.items.isEmpty { await history.load(.browse(YouTubeFeeds.history)) } }
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await history.load(.browse(YouTubeFeeds.history)) } }
            }
        }
    }

    private func reload() async {
        selectedChip = nil
        async let feed: Void = model.load(.browse(YouTubeFeeds.home))
        async let watched: Void = history.load(.browse(YouTubeFeeds.history))
        _ = await (feed, watched)
    }

    /// Tapping the selected chip clears it.
    private func tapChip(_ title: String) {
        let isSelected = selectedChip == title
        selectedChip = isSelected ? nil : title
        let token = model.chips.first { $0.title == title }?.token
        model.beginSwitching()
        Task {
            if !isSelected, let token {
                await model.load(.continuation(token), keepChips: true)
            } else {
                await model.load(.browse(YouTubeFeeds.home), keepChips: true)
            }
        }
    }
}

/// Resumes the latest unfinished video. The small covers swap into the large slot.
private struct KeepWatchingCard: View {
    let history: FeedModel
    @Environment(Router.self) private var router
    @State private var selectedId: String?

    private static let shown = 8
    private static let thumbWidth: CGFloat = 144
    private static let smallThumbWidth: CGFloat = 78
    private static let playSize: CGFloat = 44
    private static let radius: CGFloat = 18

    private var videos: [(video: YouTubeVideo, extras: VideoExtras)] {
        Array(history.unfinished.prefix(Self.shown))
    }

    var body: some View {
        Group {
            if history.items.isEmpty, history.isLoading {
                loading
            } else if let main = videos.first(where: { $0.video.videoId == selectedId }) ?? videos.first {
                card(main: main)
            }
        }
        .onChange(of: router.current?.videoId) { _, videoId in
            if videoId == nil { Task { await history.load(.browse(YouTubeFeeds.history)) } }
        }
    }

    private func card(main: (video: YouTubeVideo, extras: VideoExtras)) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Text("Keep Watching").font(.headline)
            Button { resume(main) } label: {
                HStack(spacing: Layout.rowSpacing) {
                    thumb(main).frame(width: Self.thumbWidth)
                    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        Text(main.video.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(timeLeft(main))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: Self.playSize, height: Self.playSize)
                        .background(.tint, in: .circle)
                }
                .contentShape(.rect)
            }
            .buttonStyle(RowPressStyle())
            .accessibilityLabel("Resume \(main.video.title), \(timeLeft(main))")
            .videoMenu(main.video)

            let others = videos.filter { $0.video.videoId != main.video.videoId }
            if !others.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Layout.chipSpacing) {
                        ForEach(others, id: \.video.videoId) { entry in
                            Button {
                                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy) { selectedId = entry.video.videoId }
                            } label: {
                                thumb(entry).frame(width: Self.smallThumbWidth)
                            }
                            .buttonStyle(RowPressStyle())
                            .accessibilityLabel("Show \(entry.video.title)")
                        }
                    }
                }
            }
        }
        .padding(Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Self.radius, style: .continuous))
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.chipSpacing)
        .padding(.bottom, Layout.sectionGap)
    }

    private func thumb(_ entry: (video: YouTubeVideo, extras: VideoExtras)) -> some View {
        Thumbnail(url: entry.video.thumbnailURL, videoId: entry.video.videoId)
            .overlay { WatchProgressLine(video: entry.video, extras: entry.extras) }
            .clipShape(.rect(cornerRadius: Layout.tileRadius))
            .videoZoomSource(entry.video.videoId)
    }

    private func timeLeft(_ entry: (video: YouTubeVideo, extras: VideoExtras)) -> String {
        guard let duration = entry.video.durationSeconds,
              let progress = entry.extras.progress ?? WatchPositions.progress(of: entry.video) else { return "Continue" }
        return "\(max(1, Int((1 - progress) * Double(duration) / 60))) min left"
    }

    private func resume(_ entry: (video: YouTubeVideo, extras: VideoExtras)) {
        if let duration = entry.video.durationSeconds, let progress = entry.extras.progress {
            WatchPositions.seed(videoId: entry.video.videoId, time: progress * Double(duration))
        }
        router.play(entry.video)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ShimmerBlock(width: 120, height: 22)
            HStack(spacing: Layout.rowSpacing) {
                ShimmerFill(radius: Layout.tileRadius)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: Self.thumbWidth)
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    LoadingLine(height: 14)
                    LoadingLine(height: 14, shortBy: 20)
                    LoadingLine(height: 11, shortBy: 40)
                }
                ShimmerBlock(width: Self.playSize, height: Self.playSize, radius: Self.playSize / 2)
            }
            HStack(spacing: Layout.chipSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    ShimmerFill(radius: Layout.tileRadius)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(width: Self.smallThumbWidth)
                }
            }
        }
        .padding(Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Self.radius, style: .continuous))
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.chipSpacing)
        .padding(.bottom, Layout.sectionGap)
        .shimmerClock()
        .accessibilityHidden(true)
    }
}

/// The shape of the filter row while Home loads.
private struct LoadingChips: View {
    var body: some View {
        HStack(spacing: Layout.chipSpacing) {
            ForEach([56, 84, 70, 92], id: \.self) { width in
                ShimmerBlock(width: CGFloat(width), height: Layout.controlHeight, radius: Layout.controlHeight / 2)
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
        .shimmerClock()
        .accessibilityHidden(true)
    }
}

struct SubsView: View {
    private enum Filter: String, CaseIterable {
        case new = "New"
        case notSeenLately = "Not Seen Lately"
        case videos = "Videos"
        case shorts = "Shorts"
        case posts = "Posts"
    }

    @State private var model = FeedModel()
    @State private var posts = FeedModel()
    private var subscriptions: Subscriptions { .shared }
    @State private var filter: Filter?
    @State private var newVideos: [YouTubeVideo] = []
    @State private var didAddHistory = false
    @Environment(Router.self) private var router

    /// A filter can leave a page empty, so it looks a little further before giving up.
    private static let pagesToSearch = 3
    // ponytail: only this many channels get their posts read, one request each. Raise it if posts go missing.
    private static let channelsWithPosts = 30
    private static let newVideosShown = 12

    /// YouTube's Most relevant: the first shelf of videos on this page, whatever the language calls it.
    /// The New Videos card shows it, so it doesn't appear twice.
    private var relevantShelf: FeedItem? {
        model.items.first { if case .shelf = $0 { return true } else { return false } }
    }

    private var relevantVideos: [YouTubeVideo] {
        if case .shelf(_, let videos)? = relevantShelf { return videos }
        return []
    }

    private var keeps: ((FeedItem) -> Bool)? {
        let relevantId = relevantShelf?.id
        switch filter {
        case .new:
            return {
                if case .video(let video, _) = $0 { return video.isNew } else { return false }
            }
        case .notSeenLately:
            return {
                if case .video(let video, _) = $0, let id = video.channelId { return WatchedChannels.isStale(id) }
                return false
            }
        case .videos:
            return {
                guard $0.id != relevantId else { return false }
                switch $0 {
                case .video, .shelf: return true
                default: return false
                }
            }
        case .shorts:
            return { if case .shorts = $0 { return true } else { return false } }
        case nil:
            return { $0.id != relevantId }
        case .posts:
            return nil
        }
    }

    private var loadingKind: LoadingKind {
        switch filter {
        case .shorts: .shorts
        case .posts: .posts
        case .new, .notSeenLately, .videos, nil: .videos
        }
    }

    var body: some View {
        NavigationStack {
            FeedContent(model: filter == .posts ? posts : model, retry: reload, keeps: keeps, loading: loadingKind) {
                FilterChips(titles: Filter.allCases.map(\.rawValue), selected: filter?.rawValue) { title in
                    let tapped = Filter(rawValue: title)
                    filter = filter == tapped ? nil : tapped
                }
                if filter == nil || filter == .videos {
                    if !newVideos.isEmpty {
                        NewVideosCard(videos: newVideos)
                    } else if model.items.isEmpty, model.isLoading {
                        LoadingNewVideos()
                    }
                }
            }
            .tabRoot(title: "Subs", tab: .subs)
            .onChange(of: model.videos.count) { refreshNewVideos() }
            .onChange(of: router.current?.videoId) { refreshNewVideos() }
            .onAppear { refreshNewVideos() }
            .task {
                if model.items.isEmpty { await model.load(.browse(YouTubeFeeds.subscriptions)) }
                Subscriptions.shared.add(model.videos.compactMap(\.channelId))
            }
            .task(id: filter) {
                if filter == .notSeenLately, !didAddHistory {
                    await WatchedChannels.addHistory()
                    didAddHistory = true
                }
                if filter == .posts {
                    if posts.items.isEmpty { await loadPosts() }
                } else if let keeps {
                    for _ in 0..<Self.pagesToSearch where !model.items.contains(where: keeps) {
                        guard let last = model.items.last else { break }
                        await model.loadMore(after: last)
                    }
                }
            }
        }
    }

    private func refreshNewVideos() {
        var known = Set<String>()
        // YouTube's own choice first, then whatever else came out today.
        let fresh = (relevantVideos + model.videos.filter(\.isRecent)).filter {
            !$0.isLive && !SeenVideos.contains($0.videoId) && known.insert($0.videoId).inserted
        }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .default) { newVideos = Array(fresh.prefix(Self.newVideosShown)) }
    }

    private func reload() async {
        if filter == .posts {
            await loadPosts()
        } else {
            await model.load(.browse(YouTubeFeeds.subscriptions))
        }
    }

    /// Channels that uploaded lately come first, because the list has a limit.
    private func loadPosts() async {
        var seen = Set<String>()
        let recent = model.videos.compactMap(\.channelId)
        let ids = (recent + subscriptions.channels.compactMap(\.channelId)).filter { seen.insert($0).inserted }
        await posts.loadPosts(ofChannels: Array(ids.prefix(Self.channelsWithPosts)))
    }
}

/// A list with a search field for one page: the whole list until something is searched, if it has one.
struct ScopedSearchPage: View {
    let title: String
    let prompt: String
    let browseId: String
    var params: String?
    /// The watch history lists everything. A channel starts empty, as its own page already lists it.
    var listsWithoutQuery = false
    @State private var model = FeedModel()
    @State private var text = ""
    @State private var submitted = ""

    private var source: FeedSource {
        submitted.isEmpty ? .browse(browseId) : .scoped(browseId: browseId, params: params, query: submitted)
    }

    var body: some View {
        Group {
            if submitted.isEmpty, !listsWithoutQuery {
                ContentUnavailableView(prompt, systemImage: "magnifyingglass")
            } else {
                FeedContent(model: model, retry: { await model.load(source) }, isCompact: true) { EmptyView() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        .task(id: text) {
            // Waits for a pause in typing, because each change cancels this task.
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            if !Task.isCancelled { submitted = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .task(id: submitted) {
            if !submitted.isEmpty || listsWithoutQuery { await model.load(source) }
        }
    }
}

/// A ScrollView like Woof Music's pages: a List row fires every link inside it at once.
struct FeedContent<Header: View>: View {
    let model: FeedModel
    let retry: () async -> Void
    var isCompact = false
    /// Leaves out what a filter doesn't want.
    var keeps: ((FeedItem) -> Bool)?
    /// What the loading rows look like, when it isn't simply a list of videos.
    var loading: LoadingKind?
    @ViewBuilder let header: () -> Header

    private var loadingKind: LoadingKind { loading ?? (isCompact ? .compact : .videos) }

    /// Woof Music's filters: loading rows at once, then the new rows fade up into place.
    private var shownIds: [String] {
        (keeps.map { model.items.filter($0) } ?? model.items).map(\.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header()
                if model.isSwitching {
                    LoadingRows(kind: loadingKind).transition(.opacity)
                } else {
                    if shownIds.isEmpty {
                        emptyState
                    }
                    FeedRows(model: model, isCompact: isCompact, keeps: keeps)
                }
            }
            .animation(.smooth(duration: 0.4), value: shownIds)
            .animation(.smooth(duration: 0.3), value: model.isSwitching)
        }
        .refreshable { await retry() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            LoadingRows(kind: loadingKind)
        } else {
            ContentUnavailableView {
                if model.errorText != nil {
                    Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                } else if model.isSearch {
                    Label("No Results", systemImage: "magnifyingglass")
                } else {
                    Label("Nothing Here", systemImage: "play.rectangle")
                }
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
    let model: FeedModel
    var isCompact = false
    /// Set on a playlist the user can edit, to offer removing videos.
    var editablePlaylistId: String?
    /// Set on a playlist, so a tapped video carries on with the ones after it.
    var playlistTitle: String?
    var keeps: ((FeedItem) -> Bool)?
    @Environment(Router.self) private var router
    @State private var pendingRemoval: PendingRemoval?

    private struct PendingRemoval {
        let item: FeedItem
        let extras: VideoExtras
    }

    var body: some View {
        let shown = keeps.map { model.items.filter($0) } ?? model.items
        ForEach(shown) { item in
            row(item)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 24)), removal: .opacity))
                .onScrollVisibilityChange(threshold: 0.6) { isVisible in
                    if isVisible, model.isHome { SeenVideos.mark(item) }
                }
                .task {
                    // The next page follows the last row shown, which a filter can move up.
                    if item.id == shown.last?.id, let last = model.items.last { await model.loadMore(after: last) }
                }
        }
        .confirmationDialog(
            "Remove from this playlist?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button("Remove from Playlist", role: .destructive) { remove(removal) }
        }
    }

    private func removal(of item: FeedItem, extras: VideoExtras) -> (() -> Void)? {
        guard editablePlaylistId != nil, extras.setVideoId != nil else { return nil }
        return { pendingRemoval = PendingRemoval(item: item, extras: extras) }
    }

    private func remove(_ removal: PendingRemoval) {
        guard let playlistId = editablePlaylistId, let setVideoId = removal.extras.setVideoId else { return }
        do {
            model.remove(removal.item)
            router.run {
                _ = try await InnerTubeClient.wooftube.editPlaylist(
                    playlistId: playlistId,
                    actions: [["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId]]
                )
            }
        }
    }

    private func playAction(for video: YouTubeVideo) -> (() -> Void)? {
        guard let playlistTitle else { return nil }
        return { router.playPlaylist(video, title: playlistTitle, model: model) }
    }

    @ViewBuilder
    private func row(_ item: FeedItem) -> some View {
        switch item {
        case .video(let video, let extras):
            VideoButton(video: video, extras: extras, isCompact: isCompact, onRemove: { model.remove(item) }, onRemoveFromPlaylist: removal(of: item, extras: extras), onPlay: playAction(for: video))
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
            ZoomLink {
                PlaylistPage(title: playlist.title, playlistId: playlist.playlistId)
            } label: {
                MediaListRow(url: playlist.thumbnailURL, title: playlist.title, subtitle: playlist.videoCountText)
            }
            .buttonStyle(RowPressStyle())
            .padding(.horizontal, Layout.screenPadding)
        case .channel(let channel):
            if let id = channel.channelId {
                Button {
                    router.openChannelPage(id)
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
    var isNarrow = false
    var onRemove: (() -> Void)?
    var onRemoveFromPlaylist: (() -> Void)?
    var onPlay: (() -> Void)?
    @Environment(Router.self) private var router

    private func play() {
        if let onPlay {
            onPlay()
        } else {
            router.play(video)
        }
    }

    var body: some View {
        Group {
            if isCompact {
                Button(action: play) {
                    CompactVideoRow(video: video, extras: extras)
                }
                .buttonStyle(RowPressStyle())
            } else {
                VideoRow(video: video, extras: extras, isNarrow: isNarrow, onPlay: play)
            }
        }
        .videoMenu(video, feedback: extras.feedback, collaborators: extras.collaborators, onRemove: onRemove, onRemoveFromPlaylist: onRemoveFromPlaylist)
    }
}

/// Separate buttons rather than one around the whole row, so the avatar can open the channel.
struct VideoRow: View {
    let video: YouTubeVideo
    var extras = VideoExtras()
    var isNarrow = false
    let onPlay: () -> Void
    @Environment(Router.self) private var router

    private var details: String {
        [video.channelTitle, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var hasAvatar: Bool {
        extras.collaborators.count > 1 || video.channelAvatarURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onPlay) {
                Thumbnail(url: video.thumbnailURL, videoId: video.videoId, showsDownload: false)
                    .fadesAtBottom()
                    .overlay { WatchProgressLine(video: video, extras: extras) }
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 0) {
                            DownloadedBadge(videoId: video.videoId)
                            VideoBadge(video: video, extras: extras)
                        }
                    }
                    .overlay(alignment: .topLeading) { NewBadge(video: video, extras: extras) }
                    .clipShape(.rect(cornerRadius: Layout.tileRadius))
                    .videoZoomSource(video.videoId)
            }
            .buttonStyle(RowPressStyle())
            HStack(alignment: .top, spacing: Layout.chipSpacing) {
                avatar
                Button(action: onPlay) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                            Text(video.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2, reservesSpace: isNarrow)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: Layout.chipSpacing) {
                                Text(details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if !isNarrow { VoteLine(videoId: video.videoId).fixedSize() }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(RowPressStyle())
                .padding(.top, hasAvatar ? ShortCard.avatarSize / 2 + Layout.cardSpacing : 0)
            }
            .padding(.horizontal, Layout.rowPadding)
            .padding(.top, hasAvatar ? -ShortCard.avatarSize / 2 : Layout.chipSpacing)
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
                AvatarStack(urls: extras.collaborators.map(\.avatar), size: ShortCard.avatarSize)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Creators")
        } else if let url = video.channelAvatarURL {
            if let id = video.channelId {
                Button {
                    router.openChannel(id)
                } label: {
                    Avatar(url: url, size: ShortCard.avatarSize)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                }
                .buttonStyle(ZoomPressStyle())
                .accessibilityLabel("Open \(video.channelTitle ?? "Channel")")
            } else {
                Avatar(url: url, size: ShortCard.avatarSize)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
            }
        }
    }
}

/// Marks a video from a channel you follow, published under a day ago and not started yet.
private struct NewBadge: View {
    let video: YouTubeVideo
    let extras: VideoExtras
    var isCompact = false
    private var subscriptions: Subscriptions { .shared }

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
                .background(video.isLive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.78)), in: .rect(cornerRadius: Layout.rowPadding, style: .continuous))
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
            CoverImage(url: video.cover, maxPixels: 336)
                .frame(width: 112, height: 63)
                .overlay { WatchProgressLine(video: video, extras: extras) }
                .overlay(alignment: .bottomTrailing) { VideoBadge(video: video, extras: extras, isCompact: true) }
                .overlay(alignment: .topLeading) { NewBadge(video: video, extras: extras, isCompact: true) }
                .downloadBadge(video.videoId)
                .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
                .videoZoomSource(video.videoId)
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

/// What a feed is about to show.
enum LoadingKind {
    case videos, compact, home, shorts, posts
}

/// The shape of the feed while it loads, so the page doesn't jump when the videos arrive.
struct LoadingRows: View {
    var kind = LoadingKind.videos

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .videos:
                ForEach(0..<4, id: \.self) { _ in videoRow }
            case .compact:
                ForEach(0..<8, id: \.self) { _ in compactRow }
            case .home:
                videoRow
                shortsShelf
                videoRow
            case .shorts:
                shortsShelf
                shortsShelf
            case .posts:
                ForEach(0..<3, id: \.self) { _ in postCard }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .shimmerClock()
    }

    private var videoRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShimmerFill(radius: Layout.tileRadius).aspectRatio(16 / 9, contentMode: .fit)
            HStack(alignment: .top, spacing: Layout.chipSpacing) {
                ShimmerBlock(width: ShortCard.avatarSize, height: ShortCard.avatarSize, radius: ShortCard.avatarSize / 2)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    LoadingLine(height: 15)
                    LoadingLine(height: 15, shortBy: 90)
                    LoadingLine(height: 11, shortBy: 150)
                }
                .padding(.top, ShortCard.avatarSize / 2 + Layout.cardSpacing)
            }
            .padding(.horizontal, Layout.rowPadding)
            .padding(.top, -ShortCard.avatarSize / 2)
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.rowSpacing)
    }

    private var compactRow: some View {
        HStack(spacing: Layout.rowSpacing) {
            ShimmerBlock(width: 112, height: 63, radius: Layout.cardRadius)
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                LoadingLine(height: 14)
                LoadingLine(height: 14, shortBy: 50)
                LoadingLine(height: 11, shortBy: 110)
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.rowPadding)
    }

    private var shortsShelf: some View {
        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            ShimmerBlock(width: 90, height: 25)
                .padding(.horizontal, Layout.screenPadding)
                .padding(.top, Layout.chipSpacing)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(0..<3, id: \.self) { _ in shortCard }
                }
                .padding(.horizontal, Layout.screenPadding)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, Layout.sectionGap)
    }

    private var shortCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShimmerFill(radius: Layout.tileRadius).aspectRatio(ShortCard.coverAspect, contentMode: .fit)
            HStack(spacing: Layout.chipSpacing) {
                ShimmerBlock(width: ShortCard.avatarSize, height: ShortCard.avatarSize, radius: ShortCard.avatarSize / 2)
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    LoadingLine(height: 11)
                    LoadingLine(height: 11, shortBy: 30)
                }
            }
            .padding(.horizontal, Layout.rowPadding)
            .padding(.top, -ShortCard.avatarSize / 2)
        }
        .frame(width: ShortCard.width)
    }

    private var postCard: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack(spacing: Layout.rowSpacing) {
                ShimmerBlock(width: Layout.avatarSmall, height: Layout.avatarSmall, radius: Layout.avatarSmall / 2)
                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                    ShimmerBlock(width: 120, height: 14)
                    ShimmerBlock(width: 70, height: 11)
                }
            }
            LoadingLine(height: 14)
            LoadingLine(height: 14)
            LoadingLine(height: 14, shortBy: 120)
        }
        .padding(Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.tileRadius))
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.rowSpacing)
    }
}

/// A line of text that follows the width it's given, whatever the phone.
struct LoadingLine: View {
    let height: CGFloat
    var shortBy: CGFloat = 0

    var body: some View {
        ShimmerFill(radius: 4)
            .frame(height: height)
            .padding(.trailing, shortBy)
    }
}

/// Rows of an avatar and text, for comments and notifications.
struct LoadingTextRows: View {
    var showsThumbnail = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing + Layout.rowPadding) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(alignment: .top, spacing: showsThumbnail ? Layout.chipSpacing : Layout.rowSpacing) {
                    ShimmerBlock(width: Layout.avatarSmall, height: Layout.avatarSmall, radius: Layout.avatarSmall / 2)
                    VStack(alignment: .leading, spacing: Layout.rowPadding) {
                        LoadingLine(height: 12, shortBy: 80)
                        LoadingLine(height: 14)
                        LoadingLine(height: 14, shortBy: 40)
                    }
                    if showsThumbnail {
                        ShimmerFill(radius: Layout.tileRadius)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(width: 112)
                    }
                }
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .shimmerClock()
    }
}

struct Thumbnail: View {
    let url: String?
    let videoId: String
    var aspect: CGFloat = 16 / 9
    var showsDownload = true

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { CachedImage(url: url ?? YouTubeVideo.cover(of: videoId)) }
            .overlay(alignment: .topTrailing) {
                if showsDownload { DownloadedBadge(videoId: videoId) }
            }
            .clipShape(.rect(cornerRadius: Layout.tileRadius))
    }
}

private struct ShortsShelf: View {
    let title: String
    let videos: [YouTubeVideo]
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(videos, id: \.videoId) { video in
                        Button {
                            router.openShorts(videos, start: video)
                        } label: {
                            ShortCard(video: video)
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

/// The avatar and title straddle the cover's lower edge, and the cover fades into the page behind them.
private struct ShortCard: View {
    let video: YouTubeVideo
    @State private var avatar: String?

    static let width: CGFloat = 158
    static let coverAspect: CGFloat = 158 / 250
    static let avatarSize: CGFloat = 44
    static let fadeHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(url: video.thumbnailURL, videoId: video.videoId, aspect: Self.coverAspect)
                .fadesAtBottom()
                .clipShape(.rect(cornerRadius: Layout.tileRadius))
                .videoZoomSource(video.videoId)
            HStack(spacing: Layout.chipSpacing) {
                Avatar(url: avatar ?? video.channelAvatarURL, size: Self.avatarSize)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                Text(video.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Self.avatarSize)
            .padding(.horizontal, Layout.rowPadding)
            .padding(.top, -Self.avatarSize / 2)
        }
        .frame(width: Self.width)
        .contentShape(.rect)
        .task {
            if video.channelAvatarURL == nil { avatar = await ShortAvatars.url(of: video.videoId) }
        }
    }
}

private extension View {
    /// See-through at the bottom edge, so it blends into any background, such as the player's.
    func fadesAtBottom() -> some View {
        mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: ShortCard.fadeHeight)
            }
        }
    }
}

/// Today's videos from followed channels, in a row that scrolls sideways.
private struct NewVideosCard: View {
    let videos: [YouTubeVideo]

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack {
                Text("New Videos").font(.headline)
                Spacer()
                Text("\(videos.count) new")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Layout.chipSpacing)
                    .padding(.vertical, 3)
                    .background(.tint, in: .capsule)
            }
            .padding(.horizontal, Layout.rowSpacing)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Layout.chipSpacing) {
                    ForEach(videos, id: \.videoId) { NewVideoRibbon(video: $0) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Layout.rowSpacing)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.vertical, Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.sheetRadius + 2, style: .continuous))
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.chipSpacing)
        .padding(.bottom, Layout.sectionGap)
    }
}

/// The shape of `NewVideosCard` while the page loads.
private struct LoadingNewVideos: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack {
                ShimmerBlock(width: 100, height: 22)
                Spacer()
                ShimmerBlock(width: 50, height: 22, radius: 11)
            }
            .padding(.horizontal, Layout.rowSpacing)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Layout.chipSpacing) {
                    ForEach(0..<3, id: \.self) { _ in ribbon }
                }
                .padding(.horizontal, Layout.rowSpacing)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.sheetRadius + 2, style: .continuous))
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.chipSpacing)
        .padding(.bottom, Layout.sectionGap)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .shimmerClock()
    }

    private var ribbon: some View {
        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                ShimmerFill(radius: Layout.cardRadius)
                    .frame(height: (NewVideoRibbon.width - Layout.rowPadding * 2) * 9 / 16)
                HStack(spacing: Layout.chipSpacing) {
                    ShimmerBlock(width: NewVideoRibbon.avatarSize, height: NewVideoRibbon.avatarSize, radius: NewVideoRibbon.avatarSize / 2)
                    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        LoadingLine(height: 11)
                        LoadingLine(height: 11, shortBy: 20)
                    }
                }
                .padding(.top, -NewVideoRibbon.avatarSize / 2)
            }
            LoadingLine(height: 10, shortBy: 50)
        }
        .padding(Layout.rowPadding)
        .frame(width: NewVideoRibbon.width)
        .background(Color(.systemGray6), in: .rect(cornerRadius: Layout.tileRadius + 2, style: .continuous))
    }
}

/// A small upright card in the colour of the video's own cover. Like a Short card,
/// the avatar and title straddle the cover's lower edge, and the cover fades into the card.
private struct NewVideoRibbon: View {
    let video: YouTubeVideo
    @Environment(Router.self) private var router
    @State private var tint: Color?
    @State private var avatar: String?

    static let width: CGFloat = 148
    static let avatarSize: CGFloat = 32
    private static let fadeHeight: CGFloat = 34

    private var cover: String { video.cover }
    private var cardColor: Color { tint ?? Color(.systemGray3) }

    var body: some View {
        Button {
            SeenVideos.mark(video.videoId)
            router.play(video)
        } label: {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                VStack(alignment: .leading, spacing: 0) {
                    CoverImage(url: cover, maxPixels: 408)
                    .downloadBadge(video.videoId)
                        .frame(height: (Self.width - Layout.rowPadding * 2) * 9 / 16)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.clear, cardColor], startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.fadeHeight)
                        }
                        .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
                        .videoZoomSource(video.videoId)
                    HStack(spacing: Layout.chipSpacing) {
                        Avatar(url: avatar ?? video.channelAvatarURL, size: Self.avatarSize)
                            .overlay(Circle().stroke(cardColor, lineWidth: 2))
                        Text(video.title)
                            .font(.caption.weight(.bold))
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, -Self.avatarSize / 2)
                }
                Text(video.publishedTimeText ?? video.channelTitle ?? "")
                    .font(.caption2)
                    .opacity(0.85)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
            .foregroundStyle(.white)
            .padding(Layout.rowPadding)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .background(cardColor, in: .rect(cornerRadius: Layout.tileRadius + 2, style: .continuous))
            .animation(.easeOut(duration: 0.3), value: tint)
        }
        .buttonStyle(ZoomPressStyle())
        .videoMenu(video)
        .task {
            tint = await CoverTint.color(of: cover)
            if video.channelAvatarURL == nil { avatar = await ShortAvatars.url(of: video.videoId) }
        }
    }
}

/// A cover's average colour, made strong enough to be noticed and dark enough for white text.
@MainActor
enum CoverTint {
    private static let samplePixels = 16

    static func color(of url: String) async -> Color? {
        var image = ImageStore.image(for: url, maxPixels: samplePixels)
        if image == nil { image = try? await ImageStore.load(url, maxPixels: samplePixels) }
        guard let cover = image?.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Void? = pixel.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cover, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard drawn != nil else { return nil }
        let strong = vivid(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
        return Color(hue: strong.hue, saturation: strong.saturation, brightness: strong.brightness)
    }

    nonisolated static func vivid(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return (hue, min(saturation * 1.6 + 0.15, 0.85), min(max(brightness, 0.38), 0.55))
    }

    nonisolated static func selfCheck() {
        assert(vivid(red: 1, green: 1, blue: 1).brightness == 0.55)
        assert(vivid(red: 0, green: 0, blue: 0).brightness == 0.38)
        assert(vivid(red: 0.5, green: 0.4, blue: 0.4).saturation > 0.3)
    }
}

/// YouTube's Shorts shelves name no creator, so each card asks once, when it comes into view.
@MainActor
private enum ShortAvatars {
    private static var known: [String: String] = [:]

    static func url(of videoId: String) async -> String? {
        if let url = known[videoId] { return url }
        guard let json = try? await InnerTubeClient.wooftube.next(videoId: videoId),
              let url = await offMain({ WatchDetails(json: json, videoId: videoId).channelAvatar }) else { return nil }
        known[videoId] = url
        return url
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
                        VideoButton(video: video, isNarrow: true).frame(width: 280)
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
    @Environment(Router.self) private var router
    @State private var isExpanded = false
    @State private var isLiked: Bool?
    /// The choice picked here. It stays nil until the first tap, then `post` no longer decides.
    @State private var pickedChoice: String??

    private var showsLiked: Bool { isLiked ?? post.isLiked }
    private var shownChoice: String? {
        pickedChoice ?? post.pollChoices.first(where: \.isSelected)?.title
    }

    /// YouTube counts in words past a thousand, so only an exact number can follow the tap.
    private var shownLikes: String {
        guard let likes = post.likes, let count = Int(likes), showsLiked != post.isLiked else { return post.likes ?? "" }
        return String(count + (showsLiked ? 1 : -1))
    }

    /// Shows the change at once and takes it back if YouTube refuses.
    private func perform(_ action: String?, change: () -> Void, undo: @escaping () -> Void) {
        guard let action else {
            router.actionMessage = "YouTube didn't offer this action for the post."
            return
        }
        change()
        Task {
            do {
                _ = try await YouTubeAPI.post("comment/perform_comment_action", body: ["actions": [action]])
            } catch {
                undo()
                router.actionMessage = error.localizedDescription
            }
        }
    }

    private func vote(_ choice: PollChoice) {
        let previous = pickedChoice
        let isVoted = shownChoice == choice.title
        perform(isVoted ? choice.deselectAction : choice.selectAction) {
            pickedChoice = .some(isVoted ? nil : choice.title)
        } undo: {
            pickedChoice = previous
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Button {
                if let id = post.channelId { router.openChannel(id) }
            } label: {
                HStack(spacing: Layout.rowSpacing) {
                    Avatar(url: post.authorAvatar, size: Layout.avatarSmall)
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
                VideoButton(video: video, isCompact: true)
            }
            ForEach(post.pollChoices, id: \.title) { choice in
                let isVoted = shownChoice == choice.title
                let hasVote = shownChoice != nil
                Button {
                    vote(choice)
                } label: {
                    HStack {
                        Text(choice.title).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if isVoted {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                        if hasVote, let percent = isVoted ? choice.percentIfSelected : choice.percentIfNotSelected {
                            Text(percent).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                    .padding(Layout.rowSpacing)
                    .frame(minHeight: 44)
                    .background(alignment: .leading) {
                        if hasVote, let ratio = isVoted ? choice.ratioIfSelected : choice.ratioIfNotSelected {
                            GeometryReader { geometry in
                                Rectangle().fill(.tint.opacity(0.25)).frame(width: geometry.size.width * ratio)
                            }
                        }
                    }
                    .background(Color(.secondarySystemFill))
                    .clipShape(.rect(cornerRadius: Layout.tileRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: isVoted)
                .accessibilityAddTraits(isVoted ? .isSelected : [])
            }
            HStack(spacing: Layout.screenPadding) {
                Button {
                    let wasLiked = showsLiked
                    perform(wasLiked ? post.unlikeAction : post.likeAction) {
                        isLiked = !wasLiked
                    } undo: {
                        isLiked = wasLiked
                    }
                } label: {
                    Label {
                        Text(shownLikes)
                    } icon: {
                        Image(systemName: showsLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(showsLiked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .glyphMotion(showsLiked ? .pop : .deflate, trigger: showsLiked)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Like")
                .accessibilityValue(shownLikes)
                .accessibilityAddTraits(showsLiked ? .isSelected : [])
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
    var avatarSize = Layout.avatarSmall

    var body: some View {
        HStack(spacing: Layout.menuRowSpacing) {
            Avatar(url: channel.thumbnailURL, size: avatarSize)
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
        CachedImage(url: url, maxPixels: Int(size * 3))
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
