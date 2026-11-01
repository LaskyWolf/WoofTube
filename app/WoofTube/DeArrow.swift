import SwiftUI

/// DeArrow's community titles and thumbnails, shown in place of a video's own. It's opt-in. The title
/// list only receives the start of a code many videos share, but the picture server gets the video's ID.
@MainActor
enum DeArrow {
    nonisolated static let enabledKey = "usesDeArrow"

    struct Branding: Equatable {
        var title: String?
        var thumbnailTime: Double?
    }

    private static var known: [String: Branding] = [:]
    private static var running: [String: Task<Branding?, Never>] = [:]
    /// The service limits requests, so a refusal stops them for a while.
    private static var pausedUntil = Date.distantPast
    private static let waitBeforeAsking: Duration = .milliseconds(200)
    private static let requestTimeout: TimeInterval = 5
    private static let pauseSeconds: TimeInterval = 60

    static func cached(_ videoId: String) -> Branding? {
        known[videoId]
    }

    /// A row's title and picture both ask, so they share one request. Scrolling past cancels before it's sent.
    static func branding(of videoId: String) async -> Branding? {
        guard UserDefaults.standard.bool(forKey: enabledKey), !SearchSettings.isIncognito else { return nil }
        if let branding = known[videoId] { return branding }
        if let task = running[videoId] { return await task.value }
        try? await Task.sleep(for: waitBeforeAsking)
        guard !Task.isCancelled else { return nil }
        if let task = running[videoId] { return await task.value }
        let task = Task { await fetch(videoId) }
        running[videoId] = task
        let branding = await task.value
        running[videoId] = nil
        known[videoId] = branding
        return branding
    }

    private static func fetch(_ videoId: String) async -> Branding? {
        guard Date() > pausedUntil, let url = URL(string: "https://sponsor.ajay.app/api/branding/\(SponsorBlock.hashPrefix(of: videoId))") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            return await offMain {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return branding(in: json ?? [:], videoId: videoId)
            }
        case 404:
            return Branding()
        case 429:
            pausedUntil = Date().addingTimeInterval(pauseSeconds)
            return nil
        default:
            return nil
        }
    }

    /// The server sends YouTube's picture instead when it has no frame ready.
    static func thumbnail(of videoId: String, at time: Double) -> String {
        "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=\(videoId)&time=\(time)&redirectUrl=\(YouTubeVideo.cover(of: videoId))"
    }

    /// The best entry comes first, and it counts only if it's locked or hasn't been voted down.
    nonisolated private static func branding(in json: [String: Any], videoId: String) -> Branding {
        let entry = json[videoId] as? [String: Any]
        func best(_ key: String) -> [String: Any]? {
            guard let first = (entry?[key] as? [[String: Any]])?.first else { return nil }
            let isTrusted = first["locked"] as? Bool == true || first["votes"] as? Int ?? -1 >= 0
            return isTrusted && first["original"] as? Bool != true ? first : nil
        }
        // A ">" tells DeArrow's own formatter to leave the next word alone.
        return Branding(
            title: (best("titles")?["title"] as? String)?.replacingOccurrences(of: ">", with: ""),
            thumbnailTime: best("thumbnails")?["timestamp"] as? Double
        )
    }

    nonisolated static func selfCheck() {
        let good: [String: Any] = [
            "titles": [["title": ">Real title", "original": false, "votes": 0, "locked": false] as [String: Any]],
            "thumbnails": [["timestamp": 12.5, "original": false, "votes": 2, "locked": false] as [String: Any]]
        ]
        let bad: [String: Any] = [
            "titles": [["title": "Voted down", "original": false, "votes": -1, "locked": false] as [String: Any]],
            "thumbnails": [["original": true, "votes": 5, "locked": false] as [String: Any]]
        ]
        let json: [String: Any] = ["good": good, "bad": bad]
        assert(branding(in: json, videoId: "good") == Branding(title: "Real title", thumbnailTime: 12.5))
        assert(branding(in: json, videoId: "bad") == Branding())
        assert(branding(in: json, videoId: "none") == Branding())
    }
}

/// A video's title, DeArrow's when it has one. It starts as YouTube's so a row never waits for it.
struct VideoTitle: View {
    let video: YouTubeVideo
    @AppStorage(DeArrow.enabledKey) private var isDeArrowOn = false
    @State private var branded: String?

    private var usesDeArrow: Bool { isDeArrowOn && !video.isShort }

    var body: some View {
        Text(usesDeArrow ? branded ?? DeArrow.cached(video.videoId)?.title ?? video.title : video.title)
            .task(id: usesDeArrow ? video.videoId : "") {
                if usesDeArrow {
                    branded = await DeArrow.branding(of: video.videoId)?.title
                } else {
                    branded = nil
                }
            }
    }
}
