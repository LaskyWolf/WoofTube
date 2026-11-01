import Foundation

/// Videos the person has scrolled past or opened, so a reload of Home and Shorts shows something else.
enum SeenVideos {
    private static let key = "seenVideos"
    /// After this long a video may come back.
    private static let keepSeconds: TimeInterval = 14 * 24 * 60 * 60
    private static let marksBetweenSaves = 20
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
        seen[videoId] = Date().timeIntervalSince1970
        marksSinceSave += 1
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
