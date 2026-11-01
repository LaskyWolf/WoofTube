import SwiftUI
import SwiftyTube

/// Woof Music's library: filters, shortcut tiles, then the sections.
struct LibraryView: View {
    private enum Filter: String, CaseIterable {
        case playlists = "Playlists"
        case channels = "Channels"
        case downloaded = "Downloaded"
        case inProgress = "In Progress"
    }

    @Environment(Router.self) private var router
    @ObservedObject private var downloads = DownloadStore.shared
    private var subscriptions: Subscriptions { .shared }
    @State private var history = FeedModel()
    @State private var liked = FeedModel()
    @State private var watchLater = FeedModel()
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
                    LibraryDownloadCard()
                    if selectedFilter == nil {
                        HistoryStrip(model: history)
                    }
                    if shows(.playlists) {
                        playlistsSection
                    }
                    if shows(.channels) {
                        channelsSection
                    }
                    if selectedFilter == .downloaded {
                        videoSection(
                            title: "Downloaded",
                            videos: downloads.items.map { ($0.video, VideoExtras()) },
                            emptyText: "Long press a video and choose Download."
                        )
                    }
                    if selectedFilter == .inProgress {
                        videoSection(title: "In Progress", videos: history.unfinished, emptyText: "Videos you stop partway through show up here.")
                    }
                }
                .animation(.smooth(duration: 0.4), value: selectedFilter)
            }
            .tabRoot(title: "Library", tab: .library) {
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
        if liked.videos.isEmpty {
            await liked.load(.browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.likedVideosPlaylistId)))
        }
    }

    private func loadPlaylists() async {
        let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEplaylist_aggregation")
        // A failed refresh leaves the list on screen.
        if let json { playlists = YouTubeFeedParser.playlists(in: json) }
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
            ZoomLink(wholeLabel: true) {
                PlaylistPage(title: "Liked Videos", playlistId: YouTubeFeeds.likedVideosPlaylistId)
            } label: {
                ShortcutTile(title: "Liked Videos", subtitle: countText(liked), icon: "hand.thumbsup.fill", tint: .lime, covers: likedCovers)
            }
            ZoomLink(wholeLabel: true) {
                PlaylistPage(title: "Watch Later", playlistId: YouTubeFeeds.watchLaterPlaylistId)
            } label: {
                ShortcutTile(title: "Watch Later", subtitle: countText(watchLater), icon: "clock.fill", tint: .orange, covers: covers(watchLater.videos))
            }
            ZoomLink(wholeLabel: true) {
                DownloadsView()
            } label: {
                ShortcutTile(
                    title: "Downloads",
                    subtitle: downloads.items.isEmpty ? "Offline" : "\(downloads.items.count) \(downloads.items.count == 1 ? "video" : "videos")",
                    icon: "arrow.down.circle.fill",
                    tint: .violet,
                    covers: covers(downloads.items.map(\.video))
                )
            }
        }
        .buttonStyle(ZoomPressStyle())
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.chipSpacing)
        .padding(.bottom, Layout.sectionGap)
    }

    /// Built from the video's id, because YouTube sends some list entries with an unusable picture.
    private func covers(_ videos: [YouTubeVideo]) -> [String] {
        videos.prefix(2).map { "https://i.ytimg.com/vi/\($0.videoId)/hqdefault.jpg" }
    }

    /// The hidden Liked Videos playlist has a cover of its own, for when its videos don't load.
    private var likedCovers: [String] {
        let loaded = covers(liked.videos)
        guard loaded.isEmpty else { return loaded }
        let playlist = playlists.first { $0.playlistId == YouTubeFeeds.likedVideosPlaylistId || $0.playlistId == "VL" + YouTubeFeeds.likedVideosPlaylistId }
        return [playlist?.thumbnailURL].compactMap { $0 }
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
                LoadingMediaRows(isCircular: false)
            }
            LazyVStack(spacing: 0) {
                ForEach(shownPlaylists, id: \.playlistId) { playlist in
                    ZoomLink {
                        PlaylistPage(title: playlist.title, playlistId: playlist.playlistId)
                    } label: {
                        MediaListRow(url: playlist.thumbnailURL, title: playlist.title, subtitle: playlist.videoCountText)
                    }
                    .buttonStyle(RowPressStyle())
                    .padding(.horizontal, Layout.screenPadding)
                    .contextMenu {
                        Button("Download", systemImage: "arrow.down.to.line") {
                            Task {
                                downloads.download(await FeedModel.allVideos(ofPlaylist: playlist.playlistId), maxHeight: router.maxHeight)
                            }
                        }
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
                    LoadingMediaRows(isCircular: true)
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
                        if let id = channel.channelId { router.openChannelPage(id) }
                    } label: {
                        ChannelRow(channel: channel, avatarSize: Layout.avatarMedium)
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

    private func videoSection(title: String, videos: [(video: YouTubeVideo, extras: VideoExtras)], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title, count: videos.count)
            if videos.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Layout.screenPadding)
            }
            LazyVStack(spacing: 0) {
                ForEach(videos, id: \.video.videoId) { entry in
                    VideoButton(video: entry.video, extras: entry.extras, isCompact: true)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.rowPadding)
                }
            }
        }
        .padding(.bottom, Layout.sectionGap)
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
private extension Color {
    static let lime = Color(red: 0.48, green: 0.74, blue: 0.08)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
}

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
    let model: FeedModel
    @Environment(Router.self) private var router

    private static let coverWidth: CGFloat = 150
    private static let shown = 20
    private static let padding: CGFloat = 12

    var body: some View {
        if model.isLoading || !model.videosAndShorts.isEmpty {
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                NavigationLink {
                    ScopedSearchPage(title: "History", prompt: "Search your history", browseId: YouTubeFeeds.history, listsWithoutQuery: true)
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
                        if model.videosAndShorts.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                    ShimmerBlock(width: Self.coverWidth, height: Self.coverWidth * 9 / 16, radius: Layout.tileRadius)
                                    LoadingLine(height: 12)
                                    LoadingLine(height: 12, shortBy: 40)
                                }
                                .frame(width: Self.coverWidth)
                            }
                        }
                        ForEach(Array(model.videosAndShorts.prefix(Self.shown)), id: \.videoId) { video in
                            tile(video)
                        }
                    }
                    .padding(.horizontal, Self.padding)
                }
                .shimmerClock()
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
                    // Every tile the same height: a lazy row measures only the tiles it has drawn so far.
                    .lineLimit(2, reservesSpace: true)
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
    @State private var shuffleTaps = 0
    let title: String
    let playlistId: String

    @Environment(Router.self) private var router
    @EnvironmentObject private var settings: AppSettings
    @State private var model = FeedModel()
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
                    LoadingRows(kind: .compact)
                }
                if videos.isEmpty, !model.isLoading {
                    ContentUnavailableView {
                        Label(model.errorText == nil ? "No Videos" : "Couldn't Load", systemImage: "play.rectangle")
                    } description: {
                        if let errorText = model.errorText { Text(errorText) }
                    }
                }
                FeedRows(model: model, isCompact: true, editablePlaylistId: allowsRemoving ? playlistId : nil, playlistTitle: shownTitle)
                    .environment(\.playlistVideos, videos)
            }
        }
        .toolbar {
            Menu("Options", systemImage: "ellipsis") {
                Button("Download", systemImage: "arrow.down.to.line") {
                    Task {
                        DownloadStore.shared.download(await FeedModel.allVideos(ofPlaylist: playlistId), maxHeight: router.maxHeight)
                    }
                }
                if allowsRenaming {
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
        .detailBarTitle(shownTitle)
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
                Button {
                    shuffleTaps += 1
                    router.playAll(videos, shuffled: true)
                } label: {
                    HeaderRoundIcon(systemImage: "shuffle", motion: .crossSwap, trigger: shuffleTaps)
                }
                .accessibilityLabel("Shuffle")
                Button {
                    if let first = videos.first {
                        router.playPlaylist(first, title: shownTitle, model: model)
                    }
                } label: {
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
