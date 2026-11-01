import Foundation
import SwiftyTube

/// The stretches of a video watched in one go. A seek ends one and starts the next.
struct WatchSegments {
    static let reportEvery = 30.0
    /// The clock ticks many times a second, so a bigger step than this is a seek.
    private static let longestStep = 3.0

    private var start: Double?
    private var last = 0.0

    /// Returns a finished stretch, if this time ended one.
    mutating func advance(to time: Double) -> (start: Double, end: Double)? {
        defer { last = time }
        guard let start else {
            self.start = time
            return nil
        }
        if abs(time - last) > Self.longestStep {
            self.start = time
            return last > start ? (start, last) : nil
        }
        guard time - start >= Self.reportEvery else { return nil }
        self.start = time
        return (start, time)
    }

    mutating func finish() -> (start: Double, end: Double)? {
        guard let start, last > start else { return nil }
        self.start = last
        return (start, last)
    }

    static func selfCheck() {
        var segments = WatchSegments()
        assert(segments.advance(to: 0) == nil)
        assert(segments.advance(to: 29) == nil)
        assert(segments.advance(to: 30)?.end == 30)
        assert(segments.advance(to: 31) == nil)
        // A seek reports what came before it.
        let beforeSeek = segments.advance(to: 100)
        assert(beforeSeek?.start == 30 && beforeSeek?.end == 31)
        assert(segments.advance(to: 101) == nil)
        assert(segments.finish()?.end == 101)
        assert(segments.finish() == nil)

        // No word from the account, or it's about the same: this phone's position stands.
        assert(WatchPositions.handoff(local: 300, account: nil, duration: 1000) == 300)
        assert(WatchPositions.handoff(local: 300, account: 310, duration: 1000) == 300)
        // Another device moved on, in either direction.
        assert(WatchPositions.handoff(local: 300, account: 700, duration: 1000) == 700)
        assert(WatchPositions.handoff(local: 700, account: 300, duration: 1000) == 300)
        // Finished elsewhere: nothing to carry on from.
        assert(WatchPositions.handoff(local: 300, account: 990, duration: 1000) == 300)
    }
}

/// Tells YouTube what's being watched, so it reaches the account's history with its progress.
/// The addresses come from a request as the website: others aren't tied to the account.
@MainActor
final class WatchReporter {
    private let sessionId = WatchReporter.makeSessionId()
    private var watchtimeURL: String?
    private var segments = WatchSegments()
    private var accountPosition: Double?
    private var didAskAccount = SearchSettings.isIncognito

    /// How long a video waits to hear from the account, in steps of 100 ms.
    private static let answerSteps = 20

    init(videoId: String) {
        guard !SearchSettings.isIncognito else { return }
        Task { await start(videoId: videoId) }
        Task { await askAccount(videoId: videoId) }
    }

    /// Where to start: this phone's position, or the account's if another device has moved on.
    func startPosition(local: Double, duration: Double?) async -> Double {
        // ponytail: polls the answer, because waiting on the request can't be given a time limit as simply.
        for _ in 0..<Self.answerSteps where !didAskAccount {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return WatchPositions.handoff(local: local, account: accountPosition, duration: duration)
    }

    /// The watch history is where YouTube keeps every device's progress.
    private func askAccount(videoId: String) async {
        defer { didAskAccount = true }
        guard let json = try? await FeedSource.browse(YouTubeFeeds.history).fetch() else { return }
        let items = await offMain { FeedParser.items(in: json) }
        for case .video(let video, let extras) in items where video.videoId == videoId {
            if let progress = extras.progress, let duration = video.durationSeconds {
                accountPosition = progress * Double(duration)
            }
            return
        }
    }

    func tick(_ time: Double) {
        if let segment = segments.advance(to: time) { report(segment) }
    }

    func finish() {
        if let segment = segments.finish() { report(segment) }
    }

    private func start(videoId: String) async {
        let body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
        let tracking = (try? await YouTubeAPI.post("player", body: body))?["playbackTracking"] as? [String: Any]
        watchtimeURL = JSON.string("baseUrl", in: tracking?["videostatsWatchtimeUrl"])
        send(JSON.string("baseUrl", in: tracking?["videostatsPlaybackUrl"]), ["cmt": "0"])
    }

    private func report(_ segment: (start: Double, end: Double)) {
        let end = Self.seconds(segment.end)
        send(watchtimeURL, ["st": Self.seconds(segment.start), "et": end, "cmt": end])
    }

    private func send(_ address: String?, _ values: [String: String]) {
        guard let address, var components = URLComponents(string: address) else { return }
        let added = values.merging(["ver": "2", "cpn": sessionId, "el": "detailpage"]) { first, _ in first }
        components.queryItems = (components.queryItems ?? []).filter { added[$0.name] == nil }
            + added.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return }
        Task { try? await YouTubeAPI.ping(url) }
    }

    private static func seconds(_ time: Double) -> String {
        String(format: "%.3f", time)
    }

    /// YouTube's name for one viewing: 16 random letters, the same on every report.
    private static func makeSessionId() -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).compactMap { _ in letters.randomElement() })
    }
}
