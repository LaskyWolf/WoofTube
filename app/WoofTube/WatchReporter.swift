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
    /// Sent once the video really plays, so opening one doesn't count as watching it.
    private var playbackURL: String?
    private var playerStatus: String?
    private var segments = WatchSegments()
    private var unanswered = SearchSettings.isIncognito ? 0 : 3
    /// What each place says, in seconds. Exact, unlike the history's whole percent.
    private var playerSeconds: Double?
    private var nextSeconds: Double?
    private var historySeconds: Double?
    private var historyProgress: Double?

    /// Shorts always start from the beginning, so they don't ask where to start.
    init(videoId: String, asksPosition: Bool = true) {
        guard !SearchSettings.isIncognito else { return }
        Task { await start(videoId: videoId) }
        guard asksPosition else { return }
        Task { await askNext(videoId: videoId) }
        Task { await askHistory(videoId: videoId) }
    }

    /// Waits for the account's answers, for at most this many steps of 100 ms.
    func waitForAccount(steps: Int) async {
        // ponytail: polls, because waiting on three requests can't be given a time limit as simply.
        // `next` outranks the others, so its answer ends the wait.
        for _ in 0..<steps where unanswered > 0 && nextSeconds == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func accountPosition(duration: Double?) -> Double? {
        nextSeconds ?? playerSeconds ?? historySeconds ?? historyProgress.flatMap { progress in duration.map { progress * $0 } }
    }

    /// Where to start: this phone's position, or the account's if another device has moved on.
    func position(local: Double, duration: Double?) -> Double {
        WatchPositions.handoff(local: local, account: accountPosition(duration: duration), duration: duration)
    }

    /// One line for Diagnostics, because only the phone can see what the account answers.
    func summary(local: Double, duration: Double?) -> String {
        func text(_ time: Double?) -> String { time?.clockText ?? "–" }
        let percent = historyProgress.map { "\(Int($0 * 100))%" } ?? "–"
        return "Handoff: phone \(text(local)), next \(text(nextSeconds)), player \(playerStatus ?? "–") \(text(playerSeconds)), "
            + "history \(text(historySeconds)) \(percent), still waiting \(unanswered), used \(text(position(local: local, duration: duration)))"
    }

    private func askNext(videoId: String) async {
        defer { unanswered -= 1 }
        let json = try? await YouTubeAPI.post("next", body: ["videoId": videoId])
        nextSeconds = JSON.first("startTimeSeconds", in: json?["currentVideoEndpoint"]) as? Double
    }

    /// The watch history is where YouTube keeps every device's progress.
    private func askHistory(videoId: String) async {
        defer { unanswered -= 1 }
        guard let json = try? await FeedSource.browse(YouTubeFeeds.history).fetch() else { return }
        let items = await offMain { FeedParser.items(in: json) }
        for case .video(let video, let extras) in items where video.videoId == videoId {
            historySeconds = extras.startSeconds
            historyProgress = extras.progress
            return
        }
    }

    func tick(_ time: Double) {
        if let playbackURL {
            send(playbackURL, ["cmt": Self.seconds(time)])
            self.playbackURL = nil
        }
        if let segment = segments.advance(to: time) { report(segment) }
    }

    func finish() {
        if let segment = segments.finish() { report(segment) }
    }

    private func start(videoId: String) async {
        defer { unanswered -= 1 }
        var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
        // Without this, YouTube answers the website's client that the video is unavailable.
        if let timestamp = await StreamResolveProviders.live.signatureTimestamp?() {
            body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": timestamp, "html5Preference": "HTML5_PREF_WANTS"]]
        }
        let response = try? await YouTubeAPI.post("player", body: body)
        playerStatus = JSON.string("status", in: response?["playabilityStatus"])
        playerSeconds = JSON.first("startSeconds", in: response?["playerConfig"]) as? Double
        let tracking = response?["playbackTracking"] as? [String: Any]
        watchtimeURL = JSON.string("baseUrl", in: tracking?["videostatsWatchtimeUrl"])
        playbackURL = JSON.string("baseUrl", in: tracking?["videostatsPlaybackUrl"])
    }

    private func report(_ segment: (start: Double, end: Double)) {
        let end = Self.seconds(segment.end)
        send(watchtimeURL, ["st": Self.seconds(segment.start), "et": end, "cmt": end])
    }

    private func send(_ address: String?, _ values: [String: String]) {
        guard !SearchSettings.isIncognito, let address, var components = URLComponents(string: address) else { return }
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
