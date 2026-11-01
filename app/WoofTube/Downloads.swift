import Combine
import Network
import SwiftUI
import SwiftyTube

enum DownloadSettings {
    static let wifiOnlyKey = "downloads.wifiOnly"
    /// How many videos on each side of a playlist video to save with it. 0 saves only that video.
    static let adjacentKey = "downloads.adjacent"
    /// 0 follows the player's quality.
    static let maxHeightKey = "downloads.maxHeight"
}

/// Saves a video's separate video and audio files, so offline playback keeps the chosen quality.
/// The system does the transfers, so they go on while the app is suspended. A job's state is on
/// disk, because the system can also close the app and reopen it when the transfers end.
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

    /// A run of videos, followed by the card in the Library.
    struct Batch: Codable {
        var total = 0
        var completed = 0
        var failed = 0
        var failureReason: String?
        var isDone: Bool { completed + failed >= total }
    }

    /// One range of a file. YouTube slows down long requests, so files are fetched in short ones.
    struct Chunk: Codable {
        let name: String
        let url: URL
        let range: String
        let size: Int64
    }

    /// The video being saved.
    private struct Job: Codable {
        let video: YouTubeVideo
        let videoFile: String
        let audioFile: String
        var chunks: [Chunk]
        var finished: Set<String> = []
        let started: Date

        var isComplete: Bool { finished.count == chunks.count }
    }

    private struct Pending: Codable {
        var job: Job?
        var waiting: [YouTubeVideo]
        var batch: Batch?
        var maxHeight: Int
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var active: [Active] = []
    @Published private(set) var waiting: [YouTubeVideo] = []
    @Published private(set) var batch: Batch?
    /// For Diagnostics.
    private(set) var lastReport: String?

    /// Given by the system when it reopens the app, and called once the next job is on its way.
    var backgroundCompletion: (() -> Void)? {
        didSet { DownloadSession.shared.connect() }
    }

    private var job: Job?
    /// Popped from the queue, its stream address still loading.
    private var starting: YouTubeVideo?
    private var isJoining = false
    /// False until the app has its sign-in, which starting a new video needs.
    private var isSessionReady = false
    private var didDeliverBackgroundEvents = false
    /// Changes when the current work is thrown away, so what's still loading for it can tell.
    private var generation = 0
    private var addressRefresh: Task<Void, Never>?
    private var lastAddressRefresh = Date.distantPast
    private var queueHeight = 1080
    private var written: [String: Int64] = [:]
    private var retries: [String: Int] = [:]
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private let network = NWPathMonitor()

    /// Same size yt-dlp asks YouTube for.
    private nonisolated static let chunkSize: Int64 = 10 << 20
    private nonisolated static let joiningSuffix = "-joining"
    private static let retryLimit = 3
    private static let retryDelaySeconds = 2.0
    /// YouTube's addresses last for hours, so one refusal after another doesn't mean they all expired again.
    private static let refreshPauseSeconds = 60.0
    /// The system can reopen the app for a download without showing it, and then no sign-in arrives.
    private static let sessionWait = Duration.seconds(5)

    private static var folder: URL { ProfileStorage.downloadsFolder }
    private static var index: URL { folder.appending(path: "index.json") }
    private static var pendingFile: URL { folder.appending(path: "pending.json") }

    private init() {
        Self.selfCheck()
        network.start(queue: DispatchQueue(label: "downloads.network"))
        reloadForActiveProfile()
        Task {
            try? await Task.sleep(for: Self.sessionWait)
            sessionReady()
        }
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
        queueHeight = maxHeight
        savePending()
        advance()
    }

    /// One video, whose failure the caller shows, plus its neighbours in the playlist if the setting asks for them.
    func download(_ video: YouTubeVideo, from playlist: [YouTubeVideo] = [], maxHeight: Int) async throws {
        let id = video.videoId
        let count = UserDefaults.standard.integer(forKey: DownloadSettings.adjacentKey)
        download([video] + Self.adjacent(to: id, in: playlist, count: count), maxHeight: maxHeight)
        guard isQueued(id), waiters[id] == nil else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[id] = continuation
        }
    }

    func isQueued(_ videoId: String) -> Bool {
        active.contains { $0.id == videoId } || waiting.contains { $0.videoId == videoId }
    }

    /// The videos on both sides of this one, nearest first.
    static func adjacent(to videoId: String, in playlist: [YouTubeVideo], count: Int) -> [YouTubeVideo] {
        guard count > 0, let index = playlist.firstIndex(where: { $0.videoId == videoId }) else { return [] }
        return (1...count).flatMap { step in
            [index + step, index - step].filter { playlist.indices.contains($0) }.map { playlist[$0] }
        }
    }

    func clearFinishedBatch() {
        if batch?.isDone == true {
            batch = nil
            savePending()
        }
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

    func sessionReady() {
        guard !isSessionReady else { return }
        isSessionReady = true
        advance()
    }

    /// Stops what's downloading and what's waiting. The saved videos stay.
    func cancelAll() {
        waiting = []
        batch = nil
        dropCurrentWork(deletingFiles: true)
        savePending()
    }

    func deleteAll() {
        cancelAll()
        for item in items { delete(item) }
    }

    /// Everything in flight stops. Whoever is waiting for a video hears that it was cancelled.
    private func dropCurrentWork(deletingFiles: Bool) {
        generation += 1
        if job != nil || starting != nil { DownloadSession.shared.cancelAll() }
        if deletingFiles, let job {
            for chunk in job.chunks { try? FileManager.default.removeItem(at: Self.folder.appending(path: chunk.name)) }
            for file in [job.videoFile, job.audioFile] where !items.contains(where: { $0.videoFile == file || $0.audioFile == file }) {
                try? FileManager.default.removeItem(at: Self.folder.appending(path: file))
                try? FileManager.default.removeItem(at: Self.folder.appending(path: file + Self.joiningSuffix))
            }
        }
        job = nil
        starting = nil
        isJoining = false
        active = []
        written = [:]
        retries = [:]
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        waiters = [:]
    }

    /// Another account's job stays in its own folder, and carries on when that account comes back.
    func reloadForActiveProfile() {
        dropCurrentWork(deletingFiles: false)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var folder = Self.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let data = try? Data(contentsOf: Self.index)
        items = data.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        let pending = (try? Data(contentsOf: Self.pendingFile)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
        job = pending?.job
        waiting = pending?.waiting ?? []
        batch = pending?.batch
        queueHeight = pending?.maxHeight ?? queueHeight
        active = job.map { [Active(video: $0.video)] } ?? []
        Task { await resumeJob() }
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

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: Self.folder.appending(path: item.videoFile))
        try? FileManager.default.removeItem(at: Self.folder.appending(path: item.audioFile))
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: The queue

    private func advance() {
        guard isSessionReady, job == nil, starting == nil, let video = waiting.first else {
            settleBackground()
            return
        }
        waiting.removeFirst()
        starting = video
        active = [Active(video: video)]
        let startedIn = generation
        // Long enough to get the next video going when this runs with the phone locked.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task {
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            do {
                let new = try await makeJob(video)
                guard generation == startedIn else { return }
                starting = nil
                job = new
                savePending()
                for chunk in new.chunks { DownloadSession.shared.start(chunk) }
                settleBackground()
            } catch {
                guard generation == startedIn else { return }
                starting = nil
                conclude(video, failure: error)
            }
        }
    }

    private func makeJob(_ video: YouTubeVideo) async throws -> Job {
        let id = video.videoId
        if UserDefaults.standard.bool(forKey: DownloadSettings.wifiOnlyKey), network.currentPath.usesInterfaceType(.cellular) {
            throw NeedsWiFi()
        }
        let chosen = UserDefaults.standard.integer(forKey: DownloadSettings.maxHeightKey)
        let stream = try await StreamLoader.load(videoId: id, maxHeight: chosen > 0 ? chosen : queueHeight)
        guard let videoURL = stream.videoURL.flatMap(URL.init(string:)),
              let audioURL = stream.audioURL.flatMap(URL.init(string:)) else { throw NotDownloadable() }
        let videoFile = id + "-video"
        let audioFile = id + "-audio"
        return Job(
            video: video,
            videoFile: videoFile,
            audioFile: audioFile,
            chunks: Self.chunks(of: videoFile, url: videoURL, size: stream.videoSize) + Self.chunks(of: audioFile, url: audioURL, size: stream.audioSize),
            started: Date()
        )
    }

    /// A whole file in one request when YouTube doesn't say how big it is.
    nonisolated static func chunks(of file: String, url: URL, size: Int64?) -> [Chunk] {
        guard let size, size > 0 else {
            return [Chunk(name: file + ".0", url: url, range: "bytes=0-", size: 0)]
        }
        return stride(from: Int64(0), to: size, by: Int(chunkSize)).enumerated().map { index, start in
            let end = min(start + chunkSize, size)
            return Chunk(name: "\(file).\(index)", url: url, range: "bytes=\(start)-\(end - 1)", size: end - start)
        }
    }

    /// After a relaunch: whatever isn't on disk or on its way is asked for again.
    private func resumeJob() async {
        guard var job else {
            advance()
            return
        }
        let running = await DownloadSession.shared.runningNames()
        for chunk in job.chunks where FileManager.default.fileExists(atPath: Self.folder.appending(path: chunk.name).path) {
            job.finished.insert(chunk.name)
        }
        self.job = job
        if job.isComplete {
            join(job)
            return
        }
        for chunk in job.chunks where !job.finished.contains(chunk.name) && !running.contains(chunk.name) {
            DownloadSession.shared.start(chunk)
        }
    }

    func chunkProgressed(_ name: String, written bytes: Int64) {
        guard job != nil else { return }
        written[name] = bytes
        publishFraction()
    }

    func chunkFinished(_ name: String) {
        guard var job, job.chunks.contains(where: { $0.name == name }) else {
            // From a job that's gone.
            try? FileManager.default.removeItem(at: Self.folder.appending(path: name))
            return
        }
        guard job.finished.insert(name).inserted else { return }
        written[name] = nil
        self.job = job
        savePending()
        publishFraction()
        if job.isComplete { join(job) }
    }

    func chunkFailed(_ name: String, error: Error) {
        guard let job, job.chunks.contains(where: { $0.name == name }), !job.finished.contains(name) else { return }
        let tries = retries[name, default: 0] + 1
        retries[name] = tries
        guard tries < Self.retryLimit else {
            end(failure: error)
            return
        }
        let startedIn = generation
        let backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task {
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            try? await Task.sleep(for: .seconds(Self.retryDelaySeconds * Double(tries)))
            if (error as? Refused)?.status == 403 { await refreshAddresses() }
            guard generation == startedIn, let job = self.job, !job.finished.contains(name),
                  let current = job.chunks.first(where: { $0.name == name }) else { return }
            DownloadSession.shared.start(current)
        }
    }

    /// A refused address has usually expired. The parts already saved only fit a file of the same size.
    private func refreshAddresses() async {
        if let addressRefresh {
            await addressRefresh.value
            return
        }
        guard Date().timeIntervalSince(lastAddressRefresh) > Self.refreshPauseSeconds, let job else { return }
        lastAddressRefresh = Date()
        let startedIn = generation
        let refresh = Task {
            await StreamLoader.forget(videoId: job.video.videoId)
            let chosen = UserDefaults.standard.integer(forKey: DownloadSettings.maxHeightKey)
            guard let stream = try? await StreamLoader.load(videoId: job.video.videoId, maxHeight: chosen > 0 ? chosen : queueHeight),
                  let videoURL = stream.videoURL.flatMap(URL.init(string:)),
                  let audioURL = stream.audioURL.flatMap(URL.init(string:)),
                  generation == startedIn else { return }
            let chunks = Self.chunks(of: job.videoFile, url: videoURL, size: stream.videoSize) + Self.chunks(of: job.audioFile, url: audioURL, size: stream.audioSize)
            guard chunks.map(\.range) == job.chunks.map(\.range), chunks.map(\.name) == job.chunks.map(\.name) else { return }
            self.job?.chunks = chunks
            savePending()
        }
        addressRefresh = refresh
        await refresh.value
        addressRefresh = nil
    }

    /// Only on visible changes, because every view showing downloads redraws with this.
    private func publishFraction() {
        guard let job, !active.isEmpty else { return }
        let total = job.chunks.reduce(Int64(0)) { $0 + $1.size }
        let fraction: Double
        if total > 0 {
            let done = job.chunks.filter { job.finished.contains($0.name) }.reduce(Int64(0)) { $0 + $1.size }
            fraction = Double(done + written.values.reduce(0, +)) / Double(total)
        } else {
            fraction = Double(job.finished.count) / Double(job.chunks.count)
        }
        if abs(fraction - active[0].fraction) >= 0.005 || job.isComplete {
            active[0].fraction = min(fraction, 1)
        }
    }

    private func join(_ job: Job) {
        guard !isJoining else { return }
        isJoining = true
        let folder = Self.folder
        let startedIn = generation
        let backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task {
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            do {
                try await Task.detached {
                    try Self.join(job.chunks, into: job.videoFile, in: folder)
                    try Self.join(job.chunks, into: job.audioFile, in: folder)
                }.value
                guard generation == startedIn else { return }
                let seconds = Date().timeIntervalSince(job.started)
                let bytes = job.chunks.reduce(Int64(0)) { $0 + $1.size }
                lastReport = "Last download: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in \(Int(seconds)) s"
                items.insert(Item(video: job.video, videoFile: job.videoFile, audioFile: job.audioFile), at: 0)
                save()
                isJoining = false
                end(failure: nil)
            } catch {
                guard generation == startedIn else { return }
                isJoining = false
                end(failure: error)
            }
        }
    }

    /// The parts stay until the whole video is done, so a join cut short by the system simply runs again.
    private nonisolated static func join(_ chunks: [Chunk], into file: String, in folder: URL) throws {
        let destination = folder.appending(path: file)
        let joining = folder.appending(path: file + joiningSuffix)
        FileManager.default.createFile(atPath: joining.path, contents: nil)
        let handle = try FileHandle(forWritingTo: joining)
        for chunk in chunks where chunk.name.hasPrefix(file + ".") {
            let part = folder.appending(path: chunk.name)
            try handle.write(contentsOf: Data(contentsOf: part, options: .mappedIfSafe))
        }
        try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: joining, to: destination)
    }

    /// Clears the current job. Its partial files go, and a failure takes the output with it.
    private func end(failure: Error?) {
        guard let job else { return }
        DownloadSession.shared.cancelAll()
        for chunk in job.chunks { try? FileManager.default.removeItem(at: Self.folder.appending(path: chunk.name)) }
        if failure != nil {
            for file in [job.videoFile, job.audioFile] {
                try? FileManager.default.removeItem(at: Self.folder.appending(path: file))
                try? FileManager.default.removeItem(at: Self.folder.appending(path: file + Self.joiningSuffix))
            }
        }
        self.job = nil
        conclude(job.video, failure: failure)
    }

    private func conclude(_ video: YouTubeVideo, failure: Error?) {
        active = []
        written = [:]
        retries = [:]
        if let failure {
            batch?.failed += 1
            batch?.failureReason = failure.localizedDescription
        } else {
            batch?.completed += 1
        }
        let waiter = waiters.removeValue(forKey: video.videoId)
        if let failure {
            waiter?.resume(throwing: failure)
        } else {
            waiter?.resume()
        }
        savePending()
        advance()
    }

    /// The system counts this call as the end of the wake-up, so it waits for the session's last event.
    private func settleBackground() {
        guard didDeliverBackgroundEvents, starting == nil, !isJoining else { return }
        didDeliverBackgroundEvents = false
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    func backgroundEventsDelivered() {
        didDeliverBackgroundEvents = true
        settleBackground()
    }

    private func savePending() {
        let queue = (starting.map { [$0] } ?? []) + waiting
        let pending = Pending(job: job, waiting: queue, batch: batch, maxHeight: queueHeight)
        try? JSONEncoder().encode(pending).write(to: Self.pendingFile, options: .atomic)
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: Self.index, options: .atomic)
    }

    private static func selfCheck() {
        let url = URL(filePath: "/x")
        let parts = chunks(of: "a", url: url, size: chunkSize + 1)
        assert(parts.map(\.range) == ["bytes=0-\(chunkSize - 1)", "bytes=\(chunkSize)-\(chunkSize)"])
        assert(parts.reduce(0) { $0 + $1.size } == chunkSize + 1)
        assert(chunks(of: "a", url: url, size: nil).map(\.range) == ["bytes=0-"])
        let list = ["a", "b", "c", "d"].map { YouTubeVideo(videoId: $0, title: $0) }
        assert(adjacent(to: "a", in: list, count: 2).map(\.videoId) == ["b", "c"])
        assert(adjacent(to: "b", in: list, count: 1).map(\.videoId) == ["c", "a"])
        assert(adjacent(to: "z", in: list, count: 1).isEmpty)
        assert(adjacent(to: "b", in: list, count: 0).isEmpty)
    }
}

/// The system's download queue, which keeps running while the app isn't.
private final class DownloadSession: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadSession()

    private lazy var session: URLSession = {
        let id = (Bundle.main.bundleIdentifier ?? "wooftube") + ".downloads"
        let configuration = URLSessionConfiguration.background(withIdentifier: id)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Reattaches the system's session, whose events the reopened app is waiting for.
    func connect() {
        _ = session
    }

    func start(_ chunk: DownloadStore.Chunk) {
        // The same request mpv makes when it plays the file.
        var request = URLRequest(url: chunk.url)
        request.setValue(MpvPlayer.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(chunk.range, forHTTPHeaderField: "Range")
        request.allowsCellularAccess = !UserDefaults.standard.bool(forKey: DownloadSettings.wifiOnlyKey)
        let task = session.downloadTask(with: request)
        task.taskDescription = chunk.name
        task.resume()
    }

    func runningNames() async -> Set<String> {
        Set(await session.allTasks.compactMap(\.taskDescription))
    }

    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        Task { @MainActor in DownloadStore.shared.chunkProgressed(name, written: totalBytesWritten) }
    }

    /// The temporary file is deleted when this returns, so it moves here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            Task { @MainActor in DownloadStore.shared.chunkFailed(name, error: DownloadStore.Refused(status: status)) }
            return
        }
        let destination = ProfileStorage.downloadsFolder.appending(path: name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in DownloadStore.shared.chunkFinished(name) }
        } catch {
            Task { @MainActor in DownloadStore.shared.chunkFailed(name, error: error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let name = task.taskDescription, let error, (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in DownloadStore.shared.chunkFailed(name, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadStore.shared.backgroundEventsDelivered() }
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
    @Environment(Router.self) private var router
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmsRemoveAll = false

    private var videos: [YouTubeVideo] { store.items.map(\.video) }
    private var cover: String? { videos.first.map { "https://i.ytimg.com/vi/\($0.videoId)/hqdefault.jpg" } }
    private var size: String { ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file) }

    private var meta: String {
        let total = videos.compactMap(\.durationSeconds).reduce(0, +)
        let count = "\(videos.count) \(videos.count == 1 ? "video" : "videos")"
        guard !videos.isEmpty else { return "Downloads" }
        return ([count] + (total > 0 ? [Double(total).clockText] : []) + [size]).joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.items.isEmpty, store.active.isEmpty, store.waiting.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads Yet", systemImage: "arrow.down.to.line")
                    } description: {
                        Text("Long press a video and choose Download.")
                    } actions: {
                        NavigationLink("Download Settings") { DownloadSettingsView() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 48)
                } else {
                    header
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
                    Button("Cancel All", systemImage: "xmark", role: .destructive) { store.cancelAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.rowPadding)
                }
                ForEach(store.items) { item in
                    VideoButton(video: item.video, isCompact: true)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.rowPadding)
                }
            }
        }
        .detailBarTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Add to Queue", systemImage: "text.append") {
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
            BlurredArtworkBackdrop(url: cover)
        }
    }
}

/// Woof Music's download settings.
struct DownloadSettingsView: View {
    @ObservedObject private var store = DownloadStore.shared
    @AppStorage(DownloadSettings.maxHeightKey) private var maxHeight = 0
    @AppStorage(DownloadSettings.wifiOnlyKey) private var wifiOnly = false
    @AppStorage(DownloadSettings.adjacentKey) private var adjacent = 0

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
                Picker(selection: $adjacent) {
                    Text("Off").tag(0)
                    ForEach(1...3, id: \.self) { Text("\($0) Each Side").tag($0) }
                } label: {
                    Label("Adjacent Episodes", systemImage: "list.number")
                }
            } header: {
                Text("Preferences")
            } footer: {
                Text("Adjacent Episodes also saves the videos before and after the one you download from a playlist. Wi-Fi Only blocks downloads on cellular data.")
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
