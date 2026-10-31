import Combine
import Network
import SwiftUI
import SwiftyTube

enum DownloadSettings {
    static let wifiOnlyKey = "downloads.wifiOnly"
    static let autoOnLikeKey = "downloads.autoOnLike"
    /// 0 follows the player's quality.
    static let maxHeightKey = "downloads.maxHeight"
}

/// Saves a video's separate video and audio files, so offline playback keeps the chosen quality.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    struct Item: Codable, Identifiable {
        let video: YouTubeVideo
        let videoFile: String
        let audioFile: String
        var id: String { video.videoId }
    }

    struct Active: Identifiable {
        let video: YouTubeVideo
        var fraction = 0.0
        var id: String { video.videoId }
    }

    struct NotDownloadable: LocalizedError {
        var errorDescription: String? { "YouTube only offered a stream for this video, which can't be saved." }
    }

    struct Refused: LocalizedError {
        let status: Int
        var errorDescription: String? { "YouTube refused this download (error \(status))." }
    }

    struct NeedsWiFi: LocalizedError {
        var errorDescription: String? { "Downloads are set to Wi-Fi only." }
    }

    /// A run of several videos, followed by the card in the Library.
    struct Batch {
        var total = 0
        var completed = 0
        var failed = 0
        var failureReason: String?
        var isDone: Bool { completed + failed >= total }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var active: [Active] = []
    @Published private(set) var waiting: [YouTubeVideo] = []
    @Published private(set) var batch: Batch?

    private var isRunningQueue = false
    private let network = NWPathMonitor()

    private static var folder: URL { ProfileStorage.downloadsFolder }
    private static var index: URL { folder.appending(path: "index.json") }

    private init() {
        network.start(queue: DispatchQueue(label: "downloads.network"))
        reloadForActiveProfile()
    }

    /// One at a time, so a long playlist doesn't take over the connection.
    func download(_ videos: [YouTubeVideo], maxHeight: Int) {
        var known = Set(items.map(\.id) + active.map(\.id) + waiting.map(\.videoId))
        let new = videos.filter { known.insert($0.videoId).inserted }
        guard !new.isEmpty else { return }
        var next = batch.flatMap { $0.isDone ? nil : $0 } ?? Batch()
        next.total += new.count
        batch = next
        waiting += new
        guard !isRunningQueue else { return }
        isRunningQueue = true
        Task {
            while !waiting.isEmpty {
                let video = waiting.removeFirst()
                do {
                    try await save(video, maxHeight: maxHeight)
                    batch?.completed += 1
                } catch {
                    batch?.failed += 1
                    batch?.failureReason = error.localizedDescription
                }
            }
            isRunningQueue = false
        }
    }

    /// One video, whose failure the caller shows. The Library's card follows it too.
    func download(_ video: YouTubeVideo, maxHeight: Int) async throws {
        let id = video.videoId
        guard !isDownloaded(id), !active.contains(where: { $0.id == id }), !waiting.contains(where: { $0.videoId == id }) else { return }
        var next = batch.flatMap { $0.isDone ? nil : $0 } ?? Batch()
        next.total += 1
        batch = next
        do {
            try await save(video, maxHeight: maxHeight)
            batch?.completed += 1
        } catch {
            batch?.failed += 1
            batch?.failureReason = error.localizedDescription
            throw error
        }
    }

    func downloadIfLikesSave(_ video: YouTubeVideo, maxHeight: Int) {
        if UserDefaults.standard.bool(forKey: DownloadSettings.autoOnLikeKey) {
            download([video], maxHeight: maxHeight)
        }
    }

    func clearFinishedBatch() {
        if batch?.isDone == true { batch = nil }
    }

    /// From 0 to 1, counting how far the current video got.
    var batchFraction: Double {
        guard let batch, batch.total > 0 else { return 0 }
        let current = active.map(\.fraction).reduce(0, +)
        return min((Double(batch.completed + batch.failed) + current) / Double(batch.total), 1)
    }

    var storageBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func deleteAll() {
        waiting = []
        for item in items { delete(item) }
        batch = nil
    }

    /// Accounts can't change while something downloads, so nothing lands in the wrong folder.
    func reloadForActiveProfile() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let data = try? Data(contentsOf: Self.index)
        items = data.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    func isDownloaded(_ videoId: String) -> Bool {
        items.contains { $0.id == videoId }
    }

    /// The local stream for mpv, or nil when the video isn't saved.
    func stream(videoId: String) -> String? {
        guard let item = items.first(where: { $0.id == videoId }) else { return nil }
        return StreamFallback.combineVideoAndAudio(
            videoURL: Self.folder.appending(path: item.videoFile).path,
            audioURL: Self.folder.appending(path: item.audioFile).path,
            duration: nil
        )
    }

    private func save(_ video: YouTubeVideo, maxHeight: Int) async throws {
        let id = video.videoId
        guard !isDownloaded(id), !active.contains(where: { $0.id == id }) else { return }
        if UserDefaults.standard.bool(forKey: DownloadSettings.wifiOnlyKey), network.currentPath.usesInterfaceType(.cellular) {
            throw NeedsWiFi()
        }
        active.append(Active(video: video))
        defer { active.removeAll { $0.id == id } }

        let chosen = UserDefaults.standard.integer(forKey: DownloadSettings.maxHeightKey)
        let stream = try await StreamLoader.load(videoId: id, maxHeight: chosen > 0 ? chosen : maxHeight)
        guard let videoURL = stream.videoURL.flatMap(URL.init(string:)),
              let audioURL = stream.audioURL.flatMap(URL.init(string:)) else { throw NotDownloadable() }
        let videoFile = id + "-video"
        let audioFile = id + "-audio"
        do {
            // The audio is the smaller part, so the video counts for most of the bar.
            try await fetch(videoURL, to: videoFile, videoId: id, from: 0, span: 0.9)
            try await fetch(audioURL, to: audioFile, videoId: id, from: 0.9, span: 0.1)
        } catch {
            try? FileManager.default.removeItem(at: Self.folder.appending(path: videoFile))
            try? FileManager.default.removeItem(at: Self.folder.appending(path: audioFile))
            throw error
        }
        items.insert(Item(video: video, videoFile: videoFile, audioFile: audioFile), at: 0)
        save()
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: Self.folder.appending(path: item.videoFile))
        try? FileManager.default.removeItem(at: Self.folder.appending(path: item.audioFile))
        items.removeAll { $0.id == item.id }
        save()
    }

    private func fetch(_ url: URL, to name: String, videoId: String, from start: Double, span: Double) async throws {
        let file = FileDownload(destination: Self.folder.appending(path: name)) { [weak self] fraction in
            Task { @MainActor in
                guard let self, let index = self.active.firstIndex(where: { $0.id == videoId }) else { return }
                self.active[index].fraction = start + fraction * span
            }
        }
        try await file.run(url)
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: Self.index)
    }
}

/// One file, with progress. The async URLSession calls don't report any.
private final class FileDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            // The same request mpv makes when it plays the file.
            var request = URLRequest(url: url)
            request.setValue(MpvPlayer.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            session.downloadTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// The temporary file is deleted when this returns, so it moves here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            failure = DownloadStore.Refused(status: status)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

/// A small mark on a saved video's row. Only this video's answer redraws it.
struct DownloadedBadge: View {
    let videoId: String
    @State private var isDownloaded: Bool

    init(videoId: String) {
        self.videoId = videoId
        _isDownloaded = State(initialValue: DownloadStore.shared.isDownloaded(videoId))
    }

    var body: some View {
        // The ZStack stays when empty: it keeps the subscription, at no width.
        ZStack {
            if isDownloaded {
                Image(systemName: "arrow.down.to.line")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Downloaded")
            }
        }
        .onReceive(DownloadStore.shared.$items.map { [videoId] in $0.contains { $0.id == videoId } }.removeDuplicates()) {
            isDownloaded = $0
        }
    }
}

/// Woof Music's card under the Library's tiles. It stays after the last video until it's
/// opened or closed, so the result isn't missed on another tab.
struct LibraryDownloadCard: View {
    @ObservedObject private var store = DownloadStore.shared
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        if let batch = store.batch {
            NavigationLink {
                DownloadsView().onAppear { store.clearFinishedBatch() }
            } label: {
                content(batch)
            }
            .buttonStyle(ZoomPressStyle(scale: 0.98))
            .accessibilityHint("Opens Downloads")
            .overlay(alignment: .trailing) {
                if batch.isDone {
                    Button("Close", systemImage: "xmark") {
                        withAnimation(.smooth(duration: 0.3)) { store.clearFinishedBatch() }
                    }
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Layout.screenPadding)
            .padding(.bottom, Layout.sectionGap)
            .transition(.opacity)
        }
    }

    private func content(_ batch: DownloadStore.Batch) -> some View {
        HStack(spacing: Layout.rowSpacing) {
            Image(systemName: symbol(batch))
                .font(.title3.weight(.semibold))
                .foregroundStyle(batch.failed > 0 && batch.isDone ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(batch))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail(batch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: Layout.chipSpacing)
            if !batch.isDone {
                Text("\(Int(store.batchFraction * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            }
        }
        .padding(Layout.rowSpacing)
        // Room for the close button once it's done.
        .padding(.trailing, batch.isDone ? 28 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { progressFill(batch) }
        .background(Color(.secondarySystemBackground))
        .clipShape(shape)
        .contentShape(shape)
    }

    /// A tinted fill growing with a solid bar under it.
    private func progressFill(_ batch: DownloadStore.Batch) -> some View {
        GeometryReader { geometry in
            if !batch.isDone {
                let width = geometry.size.width * store.batchFraction
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(TintShapeStyle.tint.opacity(0.18)).frame(width: width)
                    Rectangle().fill(.tint).frame(width: width, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.batchFraction)
    }

    private func symbol(_ batch: DownloadStore.Batch) -> String {
        guard batch.isDone else { return "arrow.down.to.line" }
        return batch.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private func title(_ batch: DownloadStore.Batch) -> String {
        let videos = batch.total == 1 ? "video" : "videos"
        guard batch.isDone else { return "Downloading \(batch.total) \(videos)" }
        return batch.failed > 0 ? "\(batch.completed) of \(batch.total) \(videos) downloaded" : "\(batch.total) \(videos) downloaded"
    }

    private func detail(_ batch: DownloadStore.Batch) -> String {
        guard batch.isDone else { return "\(batch.completed + batch.failed) of \(batch.total) done" }
        guard batch.failed > 0 else { return "Ready to watch offline" }
        return batch.failureReason.map { "\(batch.failed) failed. \($0)" } ?? "\(batch.failed) failed."
    }
}

/// Woof Music's downloads page: the header card, what's downloading, then the saved videos.
struct DownloadsView: View {
    @ObservedObject private var store = DownloadStore.shared
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmsRemoveAll = false

    private var videos: [YouTubeVideo] { store.items.map(\.video) }
    private var cover: String? { videos.first.map { "https://i.ytimg.com/vi/\($0.videoId)/hqdefault.jpg" } }

    private var meta: String {
        let total = videos.compactMap(\.durationSeconds).reduce(0, +)
        let count = "\(videos.count) \(videos.count == 1 ? "video" : "videos")"
        return total > 0 ? count + " · " + Double(total).clockText : count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !videos.isEmpty {
                    header
                }
                if store.items.isEmpty, store.active.isEmpty, store.waiting.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.to.line")
                    } description: {
                        Text("Long press a video and choose Download.")
                    } actions: {
                        NavigationLink("Download Settings") { DownloadSettingsView() }
                    }
                    .padding(.vertical, 48)
                }
                if !store.active.isEmpty || !store.waiting.isEmpty {
                    SectionTitle(title: "Downloading", count: store.active.count + store.waiting.count)
                    ForEach(store.active) { active in
                        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                            CompactVideoRow(video: active.video)
                            HStack(spacing: Layout.chipSpacing) {
                                ProgressView(value: active.fraction)
                                Text("\(Int(active.fraction * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.rowPadding)
                    }
                    ForEach(store.waiting, id: \.videoId) { video in
                        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                            CompactVideoRow(video: video)
                            Text("Waiting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.rowPadding)
                    }
                }
                ForEach(store.items) { item in
                    Button {
                        router.play(item.video)
                    } label: {
                        CompactVideoRow(video: item.video)
                    }
                    .buttonStyle(RowPressStyle())
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.vertical, Layout.rowPadding)
                    .contextMenu {
                        Button("Delete Download", systemImage: "trash", role: .destructive) {
                            store.delete(item)
                        }
                    }
                }
            }
        }
        .detailBarTitle("Downloads", pinnedTitle: videos.isEmpty ? "Downloads" : nil)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Add to Queue", systemImage: "list.bullet") {
                    for video in videos { router.addToQueue(video) }
                }
                .disabled(videos.isEmpty)
                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    Label("Download Settings", systemImage: "gearshape")
                }
                Button("Remove All Downloads", systemImage: "trash", role: .destructive) {
                    confirmsRemoveAll = true
                }
                .disabled(videos.isEmpty)
            }
        }
        .confirmationDialog("Remove All Downloads?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { store.deleteAll() }
        } message: {
            Text("This permanently deletes all saved videos from your device.")
        }
    }

    private var header: some View {
        DetailHeaderCard(meta: meta, title: "Downloads") {
            CoverImage(url: cover)
                .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
        } secondary: {
            Text(ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } buttons: {
            Button { router.playAll(videos, shuffled: true) } label: {
                HeaderRoundIcon(systemImage: "shuffle")
            }
            .accessibilityLabel("Shuffle")
            Button { router.playAll(videos) } label: {
                HeaderRoundIcon(systemImage: "play.fill", primary: settings.accentColor)
            }
            .accessibilityLabel("Play All")
        }
        .padding(.vertical, Layout.screenPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: cover)
        }
    }
}

/// Woof Music's download settings.
struct DownloadSettingsView: View {
    @ObservedObject private var store = DownloadStore.shared
    @AppStorage(DownloadSettings.maxHeightKey) private var maxHeight = 0
    @AppStorage(DownloadSettings.wifiOnlyKey) private var wifiOnly = false
    @AppStorage(DownloadSettings.autoOnLikeKey) private var autoOnLike = false

    private static let heights = [1080, 720, 480, 360]

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
                            .font(.title2.weight(.bold))
                        Text("\(store.items.count) offline \(store.items.count == 1 ? "video" : "videos")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Layout.chipSpacing)
                }
            }
            Section {
                Picker(selection: $maxHeight) {
                    Text("Same as Player").tag(0)
                    ForEach(Self.heights, id: \.self) { Text("\($0)p").tag($0) }
                } label: {
                    Label("Download Quality", systemImage: "sparkles.tv")
                }
                Toggle(isOn: $wifiOnly) {
                    Label("Wi-Fi Only", systemImage: "wifi")
                }
                Toggle(isOn: $autoOnLike) {
                    Label("Auto-Download on Like", systemImage: "hand.thumbsup.fill")
                }
            } header: {
                Text("Preferences")
            } footer: {
                Text("Auto-download saves videos you like for offline watching. Wi-Fi Only blocks downloads on cellular data.")
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
