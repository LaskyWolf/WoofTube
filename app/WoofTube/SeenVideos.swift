import Foundation
import SwiftyTube

/// Videos the person has scrolled past or opened, so a reload of Home and Shorts shows something else.
enum SeenVideos {
    private static let key = "seenVideos"
    /// After this long a video may come back.
    private static let keepSeconds: TimeInterval = 14 * 24 * 60 * 60
    private static let marksBetweenSaves = 100
    private static var marksSinceSave = 0
    private static var seen = stored()

    private static func stored() -> [String: Double] {
        let saved = ProfileStorage.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let oldest = Date().timeIntervalSince1970 - keepSeconds
        return saved.filter { $0.value > oldest }
    }

    static func reload() {
        seen = stored()
        marksSinceSave = 0
    }

    static func save() {
        ProfileStorage.defaults.set(seen, forKey: key)
        marksSinceSave = 0
    }

    static func contains(_ videoId: String) -> Bool {
        seen[videoId] != nil
    }

    static func mark(_ videoId: String) {
        guard !SearchSettings.isIncognito else { return }
        if seen.updateValue(Date().timeIntervalSince1970, forKey: videoId) == nil { marksSinceSave += 1 }
        if marksSinceSave >= marksBetweenSaves { save() }
    }

    /// Only part of a shelf is on screen at once, so only its first videos count.
    static func mark(_ item: FeedItem) {
        switch item {
        case .video(let video, _): mark(video.videoId)
        case .shelf(_, let videos), .shorts(_, let videos): videos.prefix(3).forEach { mark($0.videoId) }
        default: break
        }
    }

    static func removing(from items: [FeedItem]) -> [FeedItem] {
        items.compactMap { item -> FeedItem? in
            switch item {
            case .video(let video, _):
                return contains(video.videoId) ? nil : item
            case .shelf(let title, let videos):
                let fresh = videos.filter { !contains($0.videoId) }
                return fresh.isEmpty ? nil : .shelf(title: title, fresh)
            case .shorts(let title, let videos):
                let fresh = videos.filter { !contains($0.videoId) }
                return fresh.isEmpty ? nil : .shorts(title: title, fresh)
            default:
                return item
            }
        }
    }
}

/// When each channel was last watched, for the Subs filter of channels not seen in a while.
enum WatchedChannels {
    private static let key = "watchedChannels"
    private static let staleAfter: TimeInterval = 30 * 24 * 60 * 60

    private static var dates: [String: Double] {
        ProfileStorage.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    static func mark(_ channelId: String?) {
        guard let channelId, !SearchSettings.isIncognito else { return }
        var updated = dates
        updated[channelId] = Date().timeIntervalSince1970
        ProfileStorage.defaults.set(updated, forKey: key)
    }

    /// Reads the dates once, because a filter asks about every row of a list.
    static func staleCheck() -> (String) -> Bool {
        let saved = dates
        let now = Date().timeIntervalSince1970
        return { isStale(lastWatched: saved[$0], now: now) }
    }

    private static func isStale(lastWatched: Double?, now: Double) -> Bool {
        guard let lastWatched else { return true }
        return now - lastWatched > staleAfter
    }

    /// The app only knows what it played itself, so this adds the account's recent history.
    /// These count as watched now, because the history page gives no usable date.
    static func addHistory() async {
        guard let json = try? await FeedSource.browse(YouTubeFeeds.history).fetch() else { return }
        let items = await offMain { FeedParser.items(in: json) }
        var updated = dates
        let now = Date().timeIntervalSince1970
        for case .video(let video, _) in items {
            if let id = video.channelId, updated[id] == nil { updated[id] = now }
        }
        ProfileStorage.defaults.set(updated, forKey: key)
    }

    static func selfCheck() {
        assert(isStale(lastWatched: nil, now: 0))
        assert(!isStale(lastWatched: 100, now: 100 + staleAfter))
        assert(isStale(lastWatched: 100, now: 101 + staleAfter))
    }
}
