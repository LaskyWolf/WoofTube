import Foundation
import SwiftyTube

struct LoadedStream: @unchecked Sendable {
    let url: String
    let summary: String
    let captions: [YouTubeCaptionTrack]
    /// Separate files, which downloads and audio tracks need. HLS and combined streams have none.
    var videoURL: String?
    var audioURL: String?
    var videoSize: Int64?
    var audioSize: Int64?
    var duration: Int?
    var client: YouTubeClient?
    var isLive = false
    var title: String?
    var channelTitle: String?
    var channelId: String?
}

struct AudioTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let isOriginal: Bool
}

/// A grid of small frames from the video, shown above the bar while scrubbing.
struct Storyboard {
    let urlTemplate: String
    let level: Int
    let name: String
    let signature: String
    let frameSize: CGSize
    let count: Int
    let columns: Int
    let rows: Int
    let interval: Double

    /// `base|w#h#count#columns#rows#intervalMs#name#signature|...`, smallest level first.
    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count > 1, let fields = parts.last?.components(separatedBy: "#"), fields.count >= 8,
              let width = Double(fields[0]), let height = Double(fields[1]), let count = Int(fields[2]),
              let columns = Int(fields[3]), let rows = Int(fields[4]), let interval = Double(fields[5]),
              columns > 0, rows > 0, interval > 0 else { return nil }
        urlTemplate = parts[0]
        level = parts.count - 2
        name = fields[6]
        signature = fields[7]
        frameSize = CGSize(width: width, height: height)
        self.count = count
        self.columns = columns
        self.rows = rows
        self.interval = interval
    }

    func frame(at seconds: Double) -> (url: URL?, column: Int, row: Int) {
        let index = min(max(Int(seconds * 1000 / interval), 0), max(count - 1, 0))
        let perSheet = columns * rows
        let sheetName = name.replacingOccurrences(of: "$M", with: String(index / perSheet))
        let url = urlTemplate
            .replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: sheetName) + "&sigh=" + signature
        let position = index % perSheet
        return (URL(string: url), position % columns, position / columns)
    }
}

/// Thrown with one line per client tried, shown on screen because the app runs on the phone.
struct StreamFailure: LocalizedError {
    let attempts: [String]
    var errorDescription: String? { attempts.joined(separator: "\n") }

    init(attempts: [String]) {
        self.attempts = attempts
        FileLog.shared.append("stream", "ERROR", attempts.joined(separator: " | "))
    }
}

enum StreamLoader {
    private static let sessionId = UUID().uuidString

    /// Fields SwiftyTube's typed response leaves out. Loaded after playback starts, so they don't delay it.
    static func extras(videoId: String, client: YouTubeClient) async -> (tracks: [AudioTrack], storyboard: Storyboard?) {
        guard let json = try? await InnerTubeClient.wooftube.player(videoId: videoId, client: client) else { return ([], nil) }
        let formats = JSON.first("adaptiveFormats", in: json) as? [[String: Any]] ?? []
        var best: [String: (bitrate: Int, track: AudioTrack)] = [:]
        for format in formats {
            guard let audio = format["audioTrack"] as? [String: Any],
                  let id = audio["id"] as? String,
                  let name = audio["displayName"] as? String,
                  let url = format["url"] as? String,
                  format["isDrc"] as? Bool != true else { continue }
            let bitrate = format["bitrate"] as? Int ?? 0
            if bitrate > best[id]?.bitrate ?? -1 {
                best[id] = (bitrate, AudioTrack(id: id, name: name, url: url, isOriginal: audioTags(of: url).contains(originalTag)))
            }
        }
        let tracks = best.values.map(\.track).sorted { ($0.isOriginal ? 0 : 1, $0.name) < ($1.isOriginal ? 0 : 1, $1.name) }
        return (tracks, JSON.string("spec", in: json["storyboards"]).flatMap(Storyboard.init(spec:)))
    }

    private static let originalTag = "acont=original"
    private static let compressedTag = "drc=1"

    /// What YouTube says about an audio file, kept in its address: `acont=dubbed-auto:lang=it`.
    private static func audioTags(of url: String?) -> [String] {
        let tags = url.flatMap(URLComponents.init(string:))?.queryItems?.first { $0.name == "xtags" }?.value
        return tags?.components(separatedBy: ":") ?? []
    }

    /// A video with dubs lists every language side by side, so without this the choice falls on any of them.
    /// Videos with one language have no such tag and are kept whole.
    private static func originalAudio<Item>(in items: [Item], url: (Item) -> String?) -> [Item] {
        let originals = items.filter { audioTags(of: url($0)).contains(originalTag) }
        let uncompressed = originals.filter { !audioTags(of: url($0)).contains(compressedTag) }
        return [uncompressed, originals].first { !$0.isEmpty } ?? items
    }

    static func selfCheck() {
        func address(_ tags: String) -> String { "https://a.com/videoplayback?xtags=\(tags)&itag=251" }
        let dub = address("acont%3Ddubbed-auto%3Alang%3Dit")
        let original = address("acont%3Doriginal%3Alang%3Den")
        let compressed = address("acont%3Doriginal%3Adrc%3D1%3Alang%3Den")
        assert(audioTags(of: dub) == ["acont=dubbed-auto", "lang=it"])
        assert(originalAudio(in: [dub, compressed, original], url: { $0 }) == [original])
        assert(originalAudio(in: [dub, compressed], url: { $0 }) == [compressed])
        assert(originalAudio(in: ["https://a.com/plain", dub], url: { $0 }) == ["https://a.com/plain", dub])
    }

    /// The clients tried first for streams can return no storyboard, so this asks the iOS client.
    static func storyboard(videoId: String) async -> Storyboard? {
        guard let json = try? await InnerTubeClient.wooftube.player(videoId: videoId, client: .iOS) else { return nil }
        return JSON.string("spec", in: json["storyboards"]).flatMap(Storyboard.init(spec:))
    }

    /// The clients tried first for streams can return no captions at all, so these come from the iOS client.
    static func captions(videoId: String) async -> [YouTubeCaptionTrack] {
        let response: PlayerResponse? = try? await InnerTubeClient.wooftube.playerResponse(videoId: videoId, client: .iOS, options: PlayerRequestOptions(signatureTimestamp: nil))
        return response.map { YouTubeWatchParser.captionTracks(from: $0) } ?? []
    }

    /// YouTube's current visionOS app. Older versions get fewer formats and no captions.
    private static let visionOS = YouTubeClient(
        clientName: "VISIONOS",
        clientVersion: "1.04",
        clientId: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        useMusicPlayerEndpoint: true,
        includeUserAgentInContext: true,
        skipPlayerResponseValidation: true,
        osName: "visionOS",
        osVersion: "26.6.0.23O770",
        deviceMake: "Apple",
        deviceModel: "RealityDevice17,1"
    )
    /// In SwiftyTube's list the other direct clients are refused, or their addresses stop working
    /// partway through a video. The older visionOS stays in case an account is treated differently.
    private static let directClients: [YouTubeClient] = [visionOS, .visionOS, .iOS]
    private static let fallbackChain = directClients.map { FallbackClient(client: $0, skipValidation: $0 == .iOS) }
        + [FallbackClient(client: .web, skipValidation: true)]

    private static let cache = StreamCache()

    /// The same address again when it's fresh, and the same request when one is already on its way.
    static func load(videoId: String, maxHeight: Int) async throws -> LoadedStream {
        try await cache.stream(videoId: videoId, maxHeight: maxHeight) {
            try await resolve(videoId: videoId, maxHeight: maxHeight)
        }
    }

    static func forget(videoId: String) async {
        await cache.remove(videoId: videoId)
    }

    static func forgetAll() async {
        await cache.removeAll()
    }

    /// `StreamFallback.resolveVideo` returns a 360p combined stream whenever one
    /// exists, so this looks for separate video and audio first.
    private static func resolve(videoId: String, maxHeight: Int) async throws -> LoadedStream {
        let tube = InnerTubeClient.wooftube
        var providers = StreamResolveProviders.live
        providers.poTokenProvider = { id in
            try? await PoTokenGenerator.shared.generate(videoId: id, sessionId: sessionId)
        }

        var attempts: [String] = []
        var isLive = false
        for client in directClients {
            do {
                let timestamp = client.useSignatureTimestamp ? await providers.signatureTimestamp?() : nil
                let response: PlayerResponse = try await tube.playerResponse(
                    videoId: videoId,
                    client: client,
                    options: PlayerRequestOptions(signatureTimestamp: timestamp)
                )
                guard response.isPlayable, let data = response.streamingData else {
                    let status = response.playabilityStatus
                    attempts.append("\(client.clientName): \(status?.reason ?? status?.status ?? "no streams")")
                    continue
                }
                let captions = YouTubeWatchParser.captionTracks(from: response)
                let details = response.videoDetails
                // A live stream has no length, and mpv can only play it through HLS.
                if details?.lengthSeconds == "0" {
                    isLive = true
                    guard let hls = data.hlsManifestUrl else {
                        attempts.append("\(client.clientName): live, but no HLS address")
                        continue
                    }
                    return LoadedStream(url: hls, summary: "\(client.clientName) · Live HLS", captions: captions, isLive: true, title: details?.title, channelTitle: details?.author, channelId: details?.channelId)
                }
                // The short side, so a vertical 1080x1920 Short counts as 1080p.
                let formats = ((data.formats ?? []) + (data.adaptiveFormats ?? []))
                    .filter { min($0.width ?? 0, $0.height ?? 0) <= maxHeight }
                if let video = FormatSelector.bestVideoOnlyFormat(from: formats),
                   let videoURL = video.url,
                   let audio = FormatSelector.bestAudioFormat(from: originalAudio(in: formats, url: \.url), preference: .high),
                   let audioURL = audio.url {
                    let duration = response.videoDetails?.lengthSeconds.flatMap(Int.init)
                    return LoadedStream(
                        url: StreamFallback.combineVideoAndAudio(videoURL: videoURL, audioURL: audioURL, duration: duration),
                        summary: "\(client.clientName) · \(min(video.width ?? 0, video.height ?? 0))p · \(video.codec)",
                        captions: captions,
                        videoURL: videoURL,
                        audioURL: audioURL,
                        videoSize: video.contentLength.flatMap(Int64.init),
                        audioSize: audio.contentLength.flatMap(Int64.init),
                        duration: duration,
                        client: client,
                        title: details?.title,
                        channelTitle: details?.author,
                        channelId: details?.channelId
                    )
                }
                if let hls = data.hlsManifestUrl {
                    return LoadedStream(url: hls, summary: "\(client.clientName) · HLS", captions: captions, title: details?.title, channelTitle: details?.author, channelId: details?.channelId)
                }
                attempts.append("\(client.clientName): no direct streams")
            } catch {
                attempts.append("\(client.clientName): \(error.localizedDescription)")
            }
        }

        // The fallback below only finds files, which a live stream doesn't have.
        if isLive { throw StreamFailure(attempts: attempts) }

        // Web clients return encrypted URLs. This path decrypts them, but only gives a combined stream.
        do {
            let request = StreamResolveRequest(videoId: videoId, chain: fallbackChain)
            let result = try await StreamFallback.resolveFirstValid(request, using: tube, providers: providers)
            // This path carries no captions, so they come from a plain player request.
            let captionTracks = await captions(videoId: videoId)
            return LoadedStream(
                url: result.muxedStreamUrl ?? result.streamUrl,
                summary: "\(result.clientName) · \(result.muxedHeight ?? 0)p combined",
                captions: captionTracks
            )
        } catch {
            attempts.append("Fallback: \(error.localizedDescription)")
            throw StreamFailure(attempts: attempts)
        }
    }
}

actor StreamCache {
    private struct Entry {
        let videoId: String
        let task: Task<LoadedStream, Error>
        let started: Date
    }

    /// YouTube's addresses last for hours, so this is well inside that.
    private static let lifetime: TimeInterval = 30 * 60
    private var entries: [String: Entry] = [:]

    func stream(videoId: String, maxHeight: Int, resolve: @escaping @Sendable () async throws -> LoadedStream) async throws -> LoadedStream {
        let key = "\(videoId)|\(maxHeight)"
        entries = entries.filter { Date().timeIntervalSince($0.value.started) < Self.lifetime }
        let task = entries[key]?.task ?? Task { try await resolve() }
        entries[key] = entries[key] ?? Entry(videoId: videoId, task: task, started: Date())
        do {
            let stream = try await task.value
            // A live stream's address is the live edge, and playing it later would start behind.
            if stream.isLive { entries[key] = nil }
            return stream
        } catch {
            entries[key] = nil
            throw error
        }
    }

    func remove(videoId: String) {
        entries = entries.filter { $0.value.videoId != videoId }
    }

    func removeAll() {
        entries = [:]
    }

    static func selfCheck() async {
        func stream(_ url: String, isLive: Bool = false) -> LoadedStream {
            LoadedStream(url: url, summary: "", captions: [], isLive: isLive)
        }
        let cache = StreamCache()
        _ = try? await cache.stream(videoId: "a", maxHeight: 1) { stream("first") }
        let repeated = try? await cache.stream(videoId: "a", maxHeight: 1) { stream("second") }
        assert(repeated?.url == "first")
        await cache.remove(videoId: "a")
        let refreshed = try? await cache.stream(videoId: "a", maxHeight: 1) { stream("third") }
        assert(refreshed?.url == "third")
        _ = try? await cache.stream(videoId: "b", maxHeight: 1) { throw URLError(.badURL) }
        let retried = try? await cache.stream(videoId: "b", maxHeight: 1) { stream("fourth") }
        assert(retried?.url == "fourth")
        _ = try? await cache.stream(videoId: "c", maxHeight: 1) { stream("live", isLive: true) }
        let live = try? await cache.stream(videoId: "c", maxHeight: 1) { stream("fifth") }
        assert(live?.url == "fifth")
    }
}
