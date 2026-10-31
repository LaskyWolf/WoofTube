import Foundation
import SwiftyTube

struct LoadedStream {
    let url: String
    let summary: String
    let captions: [YouTubeCaptionTrack]
    let trackingURL: String?
    /// Separate files, which downloads and audio tracks need. HLS and combined streams have none.
    var videoURL: String?
    var audioURL: String?
    var duration: Int?
    var client: YouTubeClient?
}

struct AudioTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
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

/// Thrown with one line per client tried, shown on screen because the
/// app runs on the phone and there is no log to read.
struct StreamFailure: LocalizedError {
    let attempts: [String]
    var errorDescription: String? { attempts.joined(separator: "\n") }
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
                  let url = format["url"] as? String else { continue }
            let bitrate = format["bitrate"] as? Int ?? 0
            if bitrate > best[id]?.bitrate ?? -1 {
                best[id] = (bitrate, AudioTrack(id: id, name: name, url: url))
            }
        }
        let tracks = best.values.map(\.track).sorted { $0.name < $1.name }
        return (tracks, JSON.string("spec", in: json["storyboards"]).flatMap(Storyboard.init(spec:)))
    }

    /// The clients tried first for streams can return no captions at all, so these come from the iOS client.
    static func captions(videoId: String) async -> [YouTubeCaptionTrack] {
        let response: PlayerResponse? = try? await InnerTubeClient.wooftube.playerResponse(videoId: videoId, client: .iOS, options: PlayerRequestOptions(signatureTimestamp: nil))
        return response.map { YouTubeWatchParser.captionTracks(from: $0) } ?? []
    }

    /// `StreamFallback.resolveVideo` returns a 360p combined stream whenever one
    /// exists, so this looks for separate video and audio first.
    static func load(videoId: String, maxHeight: Int) async throws -> LoadedStream {
        let tube = InnerTubeClient.wooftube
        var providers = StreamResolveProviders.live
        providers.poTokenProvider = { id in
            try? await PoTokenGenerator.shared.generate(videoId: id, sessionId: sessionId)
        }

        var attempts: [String] = []
        for entry in ClientFallbackChain.youtube {
            let client = entry.client
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
                let tracking = response.playbackTracking?.videostatsPlaybackUrl?.baseUrl
                // The short side, so a vertical 1080x1920 Short counts as 1080p.
                let formats = ((data.formats ?? []) + (data.adaptiveFormats ?? []))
                    .filter { min($0.width ?? 0, $0.height ?? 0) <= maxHeight }
                if let video = FormatSelector.bestVideoOnlyFormat(from: formats),
                   let videoURL = video.url,
                   let audio = FormatSelector.bestAudioFormat(from: formats, preference: .high),
                   let audioURL = audio.url {
                    let duration = response.videoDetails?.lengthSeconds.flatMap(Int.init)
                    return LoadedStream(
                        url: StreamFallback.combineVideoAndAudio(videoURL: videoURL, audioURL: audioURL, duration: duration),
                        summary: "\(client.clientName) · \(min(video.width ?? 0, video.height ?? 0))p · \(video.codec)",
                        captions: captions,
                        trackingURL: tracking,
                        videoURL: videoURL,
                        audioURL: audioURL,
                        duration: duration,
                        client: client
                    )
                }
                if let hls = data.hlsManifestUrl {
                    return LoadedStream(url: hls, summary: "\(client.clientName) · HLS", captions: captions, trackingURL: tracking)
                }
                attempts.append("\(client.clientName): no direct streams")
            } catch {
                attempts.append("\(client.clientName): \(error.localizedDescription)")
            }
        }

        // Web clients return encrypted URLs. This path decrypts them, but only gives a combined stream.
        do {
            let request = StreamResolveRequest(videoId: videoId, chain: ClientFallbackChain.youtube)
            let result = try await StreamFallback.resolveFirstValid(request, using: tube, providers: providers)
            // This path carries no captions, so they come from a plain player request.
            let captionsResponse: PlayerResponse? = try? await tube.playerResponse(videoId: videoId, client: .web, options: PlayerRequestOptions(signatureTimestamp: nil))
            return LoadedStream(
                url: result.muxedStreamUrl ?? result.streamUrl,
                summary: "\(result.clientName) · \(result.muxedHeight ?? 0)p combined",
                captions: captionsResponse.map { YouTubeWatchParser.captionTracks(from: $0) } ?? [],
                trackingURL: nil
            )
        } catch {
            attempts.append("Fallback: \(error.localizedDescription)")
            throw StreamFailure(attempts: attempts)
        }
    }
}
