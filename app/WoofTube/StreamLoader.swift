import Foundation
import SwiftyTube

struct LoadedStream {
    let url: String
    let summary: String
}

/// Thrown with one line per client tried, shown on screen because the
/// app runs on the phone and there is no log to read.
struct StreamFailure: LocalizedError {
    let attempts: [String]
    var errorDescription: String? { attempts.joined(separator: "\n") }
}

enum StreamLoader {
    private static let maxHeight = 1080
    private static let sessionId = UUID().uuidString

    /// `StreamFallback.resolveVideo` returns a 360p combined stream whenever one
    /// exists, so this looks for the separate 1080p video and audio first.
    static func load(videoId: String) async throws -> LoadedStream {
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
                let formats = ((data.formats ?? []) + (data.adaptiveFormats ?? []))
                    .filter { ($0.height ?? 0) <= maxHeight }
                if let video = FormatSelector.bestVideoOnlyFormat(from: formats),
                   let videoURL = video.url,
                   let audio = FormatSelector.bestAudioFormat(from: formats, preference: .high),
                   let audioURL = audio.url {
                    let duration = response.videoDetails?.lengthSeconds.flatMap(Int.init)
                    return LoadedStream(
                        url: StreamFallback.combineVideoAndAudio(videoURL: videoURL, audioURL: audioURL, duration: duration),
                        summary: "\(client.clientName) · \(video.height ?? 0)p · \(video.codec)"
                    )
                }
                if let hls = data.hlsManifestUrl {
                    return LoadedStream(url: hls, summary: "\(client.clientName) · HLS")
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
            return LoadedStream(
                url: result.muxedStreamUrl ?? result.streamUrl,
                summary: "\(result.clientName) · \(result.muxedHeight ?? 0)p combined"
            )
        } catch {
            attempts.append("Fallback: \(error.localizedDescription)")
            throw StreamFailure(attempts: attempts)
        }
    }
}
