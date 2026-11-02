import SwiftUI
import SwiftyTube

/// DeArrow's community titles and thumbnails, shown in place of a video's own. It's opt-in. The title
/// list only receives the start of a code many videos share, but the picture server gets each video's ID.
@MainActor
enum DeArrow {
    nonisolated static let enabledKey = "usesDeArrow"

    struct Branding: Equatable {
        var title: String?
        var thumbnailTime: Double?
        /// The community voted for the video's own picture.
        var usesOwnCover = false
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
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
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

    /// The server sends YouTube's automatic frame instead when it has no frame ready.
    static func thumbnail(of videoId: String, at time: Double, isShort: Bool) -> String {
        "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=\(videoId)&time=\(time)&redirectUrl=\(youTubeFrame(of: videoId, isShort: isShort))"
    }

    /// A frame YouTube picks by itself, for videos DeArrow has no frame of. It never has one of a Short.
    /// Only the "oar" files of a Short are upright, and only Shorts have them.
    nonisolated static func youTubeFrame(of videoId: String, isShort: Bool) -> String {
        "https://i.ytimg.com/vi/\(videoId)/\(isShort ? "oar2" : "hq2").jpg"
    }

    /// The best entry comes first, and it counts only if it's locked or hasn't been voted down.
    nonisolated private static func branding(in json: [String: Any], videoId: String) -> Branding {
        let entry = json[videoId] as? [String: Any]
        func best(_ key: String) -> [String: Any]? {
            guard let first = (entry?[key] as? [[String: Any]])?.first else { return nil }
            let isTrusted = first["locked"] as? Bool == true || first["votes"] as? Int ?? -1 >= 0
            return isTrusted ? first : nil
        }
        let bestTitle = best("titles")
        let title = bestTitle?["original"] as? Bool == true ? nil : bestTitle?["title"] as? String
        let bestThumbnail = best("thumbnails")
        let usesOwnCover = bestThumbnail?["original"] as? Bool == true
        var time = (bestThumbnail?["timestamp"] as? NSNumber)?.doubleValue
        // The server's random spot is a fraction of the video, and it knows the length of most videos it lists.
        if time == nil, !usesOwnCover,
           let random = (entry?["randomTime"] as? NSNumber)?.doubleValue,
           let length = (entry?["videoDuration"] as? NSNumber)?.doubleValue, length > 0 {
            time = random * length
        }
        // A ">" tells DeArrow's own formatter to leave the next word alone.
        return Branding(title: title?.replacingOccurrences(of: ">", with: ""), thumbnailTime: time, usesOwnCover: usesOwnCover)
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
        let random: [String: Any] = ["randomTime": 0.25, "videoDuration": 100]
        let noLength: [String: Any] = ["randomTime": 0.25, "videoDuration": NSNull()]
        let json: [String: Any] = ["good": good, "bad": bad, "random": random, "noLength": noLength]
        assert(branding(in: json, videoId: "good") == Branding(title: "Real title", thumbnailTime: 12.5))
        assert(branding(in: json, videoId: "bad") == Branding(usesOwnCover: true))
        assert(branding(in: json, videoId: "random") == Branding(thumbnailTime: 25))
        assert(branding(in: json, videoId: "noLength") == Branding())
        assert(branding(in: json, videoId: "none") == Branding())
        assert(youTubeFrame(of: "a", isShort: true) == "https://i.ytimg.com/vi/a/oar2.jpg")
        assert(youTubeFrame(of: "a", isShort: false) == "https://i.ytimg.com/vi/a/hq2.jpg")
    }
}

/// A video's title, DeArrow's when it has one. It starts as YouTube's so a row never waits for it.
struct VideoTitle: View {
    let video: YouTubeVideo
    @AppStorage(DeArrow.enabledKey) private var isDeArrowOn = false
    @State private var branded: String?

    var body: some View {
        Text(isDeArrowOn ? branded ?? DeArrow.cached(video.videoId)?.title ?? video.title : video.title)
            .task(id: isDeArrowOn ? video.videoId : "") {
                if isDeArrowOn {
                    branded = await DeArrow.branding(of: video.videoId)?.title
                } else {
                    branded = nil
                }
            }
    }
}

/// A video's picture, a frame of the video when DeArrow is on: the community's, DeArrow's random one or YouTube's.
struct VideoCoverImage: View {
    let url: String?
    let videoId: String
    var isShort = false
    var maxPixels: Int? = ImageStore.feedPixels
    @AppStorage(DeArrow.enabledKey) private var isDeArrowOn = false
    @State private var didAsk = false

    private var own: String { url ?? YouTubeVideo.cover(of: videoId) }

    /// Waits for DeArrow's answer, so YouTube's picture isn't downloaded just to be replaced.
    private var shownURL: String? {
        guard isDeArrowOn else { return own }
        let frame = DeArrow.youTubeFrame(of: videoId, isShort: isShort)
        guard let branding = DeArrow.cached(videoId) else { return didAsk ? frame : nil }
        if branding.usesOwnCover { return own }
        return branding.thumbnailTime.map { DeArrow.thumbnail(of: videoId, at: $0, isShort: isShort) } ?? frame
    }

    var body: some View {
        CachedImage(url: shownURL, maxPixels: maxPixels, fallback: isDeArrowOn ? own : nil)
            .task(id: isDeArrowOn ? videoId : "") {
                didAsk = false
                if isDeArrowOn { _ = await DeArrow.branding(of: videoId) }
                didAsk = true
            }
    }
}

/// A video's picture that fills whatever frame it gets.
struct VideoCover: View {
    let video: YouTubeVideo
    var maxPixels: Int? = ImageStore.feedPixels

    var body: some View {
        Color(.secondarySystemFill)
            .overlay { VideoCoverImage(url: video.thumbnailURL, videoId: video.videoId, isShort: video.isShort, maxPixels: maxPixels) }
            .clipped()
    }
}
