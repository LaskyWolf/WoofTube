import SwiftUI
import SwiftyTube

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

    @Published private(set) var items: [Item] = []
    @Published private(set) var active: [Active] = []

    private static let folder = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    private static let index = folder.appending(path: "index.json")

    private init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.index) {
            items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        }
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

    func download(_ video: YouTubeVideo, maxHeight: Int) async throws {
        let id = video.videoId
        guard !isDownloaded(id), !active.contains(where: { $0.id == id }) else { return }
        active.append(Active(video: video))
        defer { active.removeAll { $0.id == id } }

        let stream = try await StreamLoader.load(videoId: id, maxHeight: maxHeight)
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

struct DownloadsView: View {
    @ObservedObject private var store = DownloadStore.shared
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.items.isEmpty, store.active.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Long press a video and choose Download.")
                    )
                    .padding(.vertical, 48)
                }
                ForEach(store.active) { active in
                    VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                        CompactVideoRow(video: active.video)
                        ProgressView(value: active.fraction)
                    }
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.vertical, Layout.rowPadding)
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
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
