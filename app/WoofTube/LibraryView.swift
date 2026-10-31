import SwiftUI
import SwiftyTube

/// Woof Music's library: filters, shortcut tiles, then the sections.
struct LibraryView: View {
    private enum Filter: String, CaseIterable {
        case history = "History"
        case playlists = "Playlists"
        case channels = "Channels"
    }

    @EnvironmentObject private var router: Router
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var subscriptions = Subscriptions.shared
    @StateObject private var history = FeedModel()
    @StateObject private var liked = FeedModel()
    @StateObject private var watchLater = FeedModel()
    @State private var playlists: [YouTubePlaylist] = []
    @State private var isLoadingPlaylists = true
    @State private var musicPlaylistIds: Set<String> = []
    @State private var selectedFilter: Filter?
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var playlistToDelete: YouTubePlaylist?

    private var shownPlaylists: [YouTubePlaylist] {
        var seen = Set<String>()
        return playlists.filter {
            !LibraryPlaylists.isHidden($0.playlistId)
                && !musicPlaylistIds.contains($0.playlistId)
                && seen.insert($0.playlistId).inserted
        }
    }

    private func shows(_ filter: Filter) -> Bool {
        selectedFilter == nil || selectedFilter == filter
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FilterChips(titles: Filter.allCases.map(\.rawValue), selected: selectedFilter?.rawValue) { title in
                        let filter = Filter(rawValue: title)
                        selectedFilter = selectedFilter == filter ? nil : filter
                    }
                    shortcuts
                    if shows(.history) {
                        HistoryStrip(model: history)
                    }
                    if shows(.playlists) {
                        playlistsSection
                    }
                    if shows(.channels) {
                        channelsSection
                    }
                }
            }
            .tabRoot(title: "Library") {
                newTitle = ""
                isCreating = true
            }
            .refreshable { await load() }
            .task { await load() }
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

    private func load() async {
        async let historyLoad: Void = history.load(.browse(YouTubeFeeds.history))
        async let likedLoad: Void = liked.load(.browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.likedVideosPlaylistId)))
        async let laterLoad: Void = watchLater.load(.browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.watchLaterPlaylistId)))
        async let channelsLoad: Void = subscriptions.load()
        await loadPlaylists()
        _ = await (historyLoad, likedLoad, laterLoad, channelsLoad)
    }

    private func loadPlaylists() async {
        let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
        playlists = json.map { YouTubeFeedParser.playlists(in: $0) } ?? []
        isLoadingPlaylists = false
        for playlist in playlists where !LibraryPlaylists.isHidden(playlist.playlistId) {
            if await LibraryPlaylists.isMusicOnly(playlist) {
                musicPlaylistIds.insert(playlist.playlistId)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        HStack(spacing: 10) {
            NavigationLink {
                PlaylistPage(title: "Liked Videos", playlistId: YouTubeFeeds.likedVideosPlaylistId)
            } label: {
                ShortcutTile(title: "Liked Videos", subtitle: countText(liked), icon: "hand.thumbsup.fill", tint: .pink, covers: covers(liked.videos))
            }
            NavigationLink {
                PlaylistPage(title: "Watch Later", playlistId: YouTubeFeeds.watchLaterPlaylistId)
            } label: {
                ShortcutTile(title: "Watch Later", subtitle: countText(watchLater), icon: "clock.fill", tint: .orange, covers: covers(watchLater.videos))
            }
            NavigationLink {
                DownloadsView()
            } label: {
                ShortcutTile(
                    title: "Downloads",
                    subtitle: downloads.items.isEmpty ? "Offline" : "\(downloads.items.count) \(downloads.items.count == 1 ? "video" : "videos")",
                    icon: "arrow.down.circle.fill",
                    tint: .blue,
                    covers: covers(downloads.items.map(\.video))
                )
            }
        }
        .buttonStyle(ZoomPressStyle())
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.chipSpacing)
        .padding(.bottom, Layout.sectionGap)
    }

    private func covers(_ videos: [YouTubeVideo]) -> [String] {
        videos.prefix(2).map { $0.thumbnailURL ?? "https://i.ytimg.com/vi/\($0.videoId)/hqdefault.jpg" }
    }

    /// YouTube sends a page at a time, so a long list shows the first page and a plus.
    private func countText(_ model: FeedModel) -> String? {
        let count = model.videos.count
        guard count > 0 else { return nil }
        return "\(count)\(model.hasMore ? "+" : "") \(count == 1 ? "video" : "videos")"
    }

    // MARK: Sections

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Playlists", count: shownPlaylists.count)
            if isLoadingPlaylists {
                loadingRows(isCircular: false)
            }
            LazyVStack(spacing: 0) {
                ForEach(shownPlaylists, id: \.playlistId) { playlist in
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
        .padding(.bottom, Layout.sectionGap)
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Channels", count: subscriptions.channels.count)
            if subscriptions.channels.isEmpty {
                if subscriptions.isLoading {
                    loadingRows(isCircular: true)
                } else {
                    Text("YouTube didn't send your channels. Pull down to try again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.screenPadding)
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(subscriptions.channels, id: \.self) { channel in
                    Button {
                        if let id = channel.channelId { router.openChannel(id) }
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
        .padding(.bottom, Layout.sectionGap)
    }

    private func loadingRows(isCircular: Bool) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: Layout.menuRowSpacing) {
                    ShimmerBlock(width: Layout.artSmall, height: Layout.artSmall, radius: isCircular ? Layout.artSmall / 2 : Layout.cardRadius)
                    VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                        ShimmerBlock(width: 160, height: 16)
                        ShimmerBlock(width: 100, height: 13)
                    }
                }
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .shimmerClock()
    }
}

/// Decides which playlists the Library leaves out. Watch Later and Liked Videos have
/// their own tiles, and music belongs in Woof Music.
enum LibraryPlaylists {
    private static let hiddenIds: Set<String> = ["WL", "LL", "LM"]
    private static let musicPrefixes = ["OLAK5uy_", "RDCLAK"]
    private static let checksKey = "musicPlaylistChecks2"
    private static let sampleSize = 6

    static func isHidden(_ playlistId: String) -> Bool {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        return hiddenIds.contains(id)
    }

    /// YouTube doesn't mark music playlists, and official artist channels carry no marker in
    /// their name, so this asks for the category of a few videos spread across the first page.
    /// One video in five may differ, because music videos are sometimes filed under other
    /// categories. The answer is kept until the playlist's video count changes.
    @MainActor
    static func isMusicOnly(_ playlist: YouTubePlaylist) async -> Bool {
        let id = playlist.playlistId
        if musicPrefixes.contains(where: id.hasPrefix) { return true }
        let key = id + "|" + (playlist.videoCountText ?? "")
        var checks = UserDefaults.standard.dictionary(forKey: checksKey) as? [String: Bool] ?? [:]
        if let known = checks[key] { return known }
        guard let json = try? await FeedSource.browse(YouTubeFeeds.playlistBrowseId(id)).fetch() else { return false }
        let videos = YouTubeFeedParser.videos(in: json)
        let step = max(videos.count / sampleSize, 1)
        let sample = stride(from: 0, to: videos.count, by: step).prefix(sampleSize).map { videos[$0] }
        let answers = await withTaskGroup(of: Bool?.self) { group in
            for video in sample {
                group.addTask { await isMusic(video) }
            }
            return await group.reduce(into: [Bool]()) { answers, answer in
                if let answer { answers.append(answer) }
            }
        }
        guard !answers.isEmpty, !Task.isCancelled else { return false }
        let result = answers.filter { !$0 }.count * 5 <= answers.count
        checks = UserDefaults.standard.dictionary(forKey: checksKey) as? [String: Bool] ?? [:]
        checks[key] = result
        UserDefaults.standard.set(checks, forKey: checksKey)
        return result
    }

    private static func isMusic(_ video: YouTubeVideo) async -> Bool? {
        let channel = video.channelTitle ?? ""
        if channel.hasSuffix(" - Topic") || channel.hasSuffix("VEVO") { return true }
        guard let json = try? await YouTubeAPI.post("player", body: ["videoId": video.videoId]),
              let category = JSON.string("category", in: json["microformat"]) else { return nil }
        return category == "Music"
    }
}

/// Woof Music's shortcut tile: two fanned covers over a large symbol the corner crops.
private struct ShortcutTile: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let covers: [String]

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fannedCovers
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .background {
            ZStack {
                LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                Image(systemName: icon)
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(-18))
                    .offset(x: 19, y: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .clipShape(Self.shape)
            .shadow(color: tint.opacity(0.4), radius: 6, y: 4)
            .accessibilityHidden(true)
        }
        .contentShape(Self.shape)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fannedCovers: some View {
        if let first = covers.first {
            ZStack(alignment: .topLeading) {
                if covers.count > 1 {
                    cover(covers[1])
                        .rotationEffect(.degrees(-8))
                        .offset(x: 2, y: 8)
                }
                cover(first)
                    .rotationEffect(.degrees(covers.count > 1 ? 6 : 0))
                    .offset(x: covers.count > 1 ? 24 : 2, y: 2)
            }
        }
    }

    private func cover(_ url: String) -> some View {
        CoverImage(url: url)
            .frame(width: 56, height: 32)
            .clipShape(.rect(cornerRadius: Layout.rowPadding, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }
}

/// Woof Music's Keep Listening card: the title on top and covers to scroll through below.
private struct HistoryStrip: View {
    @ObservedObject var model: FeedModel
    @EnvironmentObject private var router: Router

    private static let coverWidth: CGFloat = 150
    private static let shown = 20
    private static let padding: CGFloat = 12

    var body: some View {
        if model.isLoading || !model.videos.isEmpty {
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                NavigationLink {
                    FeedList(source: .browse(YouTubeFeeds.history), isCompact: true)
                        .navigationTitle("History")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("History").font(.title3.bold())
                        Spacer(minLength: Layout.chipSpacing)
                        Text("See All")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Self.padding)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        if model.videos.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in
                                ShimmerBlock(width: Self.coverWidth, height: Self.coverWidth * 9 / 16, radius: Layout.tileRadius)
                            }
                        }
                        ForEach(Array(model.videos.prefix(Self.shown)), id: \.videoId) { video in
                            tile(video)
                        }
                    }
                    .padding(.horizontal, Self.padding)
                }
            }
            .padding(.vertical, Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, Layout.screenPadding)
            .padding(.bottom, Layout.sectionGap)
        }
    }

    private func tile(_ video: YouTubeVideo) -> some View {
        Button {
            router.play(video)
        } label: {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                CoverImage(url: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")
                    .frame(width: Self.coverWidth, height: Self.coverWidth * 9 / 16)
                    .overlay { WatchProgressLine(video: video, extras: VideoExtras()) }
                    .clipShape(.rect(cornerRadius: Layout.tileRadius, style: .continuous))
                Text(video.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: Self.coverWidth, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(ZoomPressStyle())
        .videoMenu(video)
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
                if videos.isEmpty, model.isLoading {
                    LoadingRows(isCompact: true)
                }
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
