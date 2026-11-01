import Combine
import Foundation
import SwiftyTube

/// A menu entry YouTube attaches to a video, such as "Not interested". Its label comes from YouTube.
struct FeedbackAction: Hashable {
    let title: String
    let token: String
}

/// A creator of a video with several creators. YouTube lists them in the dialog the byline opens.
struct Collaborator: Hashable, Identifiable {
    let name: String
    let subtitle: String
    let avatar: String?
    let channelId: String
    var id: String { channelId }

    private static let invisibleMarks = CharacterSet(charactersIn: "\u{200E}\u{2068}\u{2069}")

    static func all(in node: Any?) -> [Collaborator] {
        if let array = node as? [Any] {
            for value in array {
                let found = all(in: value)
                if !found.isEmpty { return found }
            }
            return []
        }
        guard let dict = node as? [String: Any] else { return [] }
        if let dialog = dict["showDialogCommand"] {
            let items = JSON.first("listItems", in: dialog) as? [[String: Any]] ?? []
            let creators = items.compactMap { item -> Collaborator? in
                guard let model = item["listItemViewModel"] as? [String: Any],
                      let name = JSON.text(model["title"]),
                      let channelId = JSON.string("browseId", in: model) else { return nil }
                let sources = JSON.first("sources", in: JSON.first("avatarViewModel", in: model)) as? [[String: Any]]
                let subtitle = JSON.text(model["subtitle"])?.unicodeScalars.filter { !invisibleMarks.contains($0) }
                return Collaborator(
                    name: name,
                    subtitle: subtitle.map { String(String.UnicodeScalarView($0)) } ?? "",
                    avatar: sources?.first?["url"] as? String,
                    channelId: channelId
                )
            }
            if !creators.isEmpty { return creators }
        }
        for value in dict.values {
            let found = all(in: value)
            if !found.isEmpty { return found }
        }
        return []
    }
}

/// What the feed knows about a video beyond what SwiftyTube parses.
struct VideoExtras {
    var feedback: [FeedbackAction] = []
    var collaborators: [Collaborator] = []
    /// From 0 to 1. YouTube only sends this when signed in.
    var progress: Double?
    var startSeconds: Double?
    var isUpcoming = false
    /// Identifies the video's entry in a playlist, which removing it needs.
    var setVideoId: String?
}

struct PollChoice {
    let title: String
    let selectAction: String?
    let deselectAction: String?
    let isSelected: Bool
    /// YouTube sends both results, since they depend on whether you picked this one.
    let percentIfSelected: String?
    let percentIfNotSelected: String?
    let ratioIfSelected: Double?
    let ratioIfNotSelected: Double?
}

struct CommunityPost {
    let id: String
    let author: String
    let authorAvatar: String?
    let channelId: String?
    let text: String
    let time: String?
    let likes: String?
    let comments: String?
    let images: [String]
    let video: YouTubeVideo?
    let pollChoices: [PollChoice]
    let likeAction: String?
    let unlikeAction: String?
    let isLiked: Bool
}

enum FeedItem: Identifiable {
    case video(YouTubeVideo, VideoExtras)
    case shorts(title: String?, [YouTubeVideo])
    case shelf(title: String?, [YouTubeVideo])
    case post(CommunityPost)
    case playlist(YouTubePlaylist)
    case channel(YouTubeChannel)

    var id: String {
        switch self {
        case .video(let video, _): return video.videoId
        case .shorts(_, let videos): return "shorts-" + (videos.first?.videoId ?? "")
        case .shelf(_, let videos): return "shelf-" + (videos.first?.videoId ?? "")
        case .post(let post): return post.id
        case .playlist(let playlist): return playlist.playlistId
        case .channel(let channel): return channel.channelId ?? channel.title
        }
    }
}

/// The channels you follow, for the Library and the New badge.
@MainActor
@Observable
final class Subscriptions {
    static let shared = Subscriptions()

    private(set) var channels: [YouTubeChannel] = []
    private(set) var ids: Set<String> = []
    private(set) var isLoading = true

    /// The side menu's list comes whole, while the channels page arrives in parts.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        var found: [YouTubeChannel] = []
        if let json = try? await YouTubeAPI.post("guide", body: [:]) {
            found = Self.guideChannels(in: JSON.first("guideSubscriptionsSectionRenderer", in: json) ?? [String: Any]())
        }
        if found.isEmpty, let json = try? await InnerTubeClient.wooftube.browse(browseId: "FEchannels") {
            found = FeedParser.items(in: json).compactMap {
                if case .channel(let channel) = $0 { return channel }
                return nil
            }
        }
        guard !found.isEmpty else { return }
        channels = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        ids = Set(found.compactMap(\.channelId))
    }

    /// Another account took over.
    func reset() {
        channels = []
        ids = []
    }

    func add(_ newIds: [String]) {
        ids.formUnion(newIds)
    }

    func setSubscribed(_ channelId: String, _ isSubscribed: Bool) {
        if isSubscribed {
            ids.insert(channelId)
        } else {
            ids.remove(channelId)
        }
    }

    private static func guideChannels(in node: Any) -> [YouTubeChannel] {
        if let array = node as? [Any] {
            return array.flatMap { guideChannels(in: $0) }
        }
        guard let dict = node as? [String: Any] else { return [] }
        if let entry = dict["guideEntryRenderer"] as? [String: Any] {
            guard let id = JSON.string("browseId", in: entry["navigationEndpoint"]), id.hasPrefix("UC"),
                  let title = JSON.text(entry["formattedTitle"]) else { return [] }
            return [YouTubeChannel(channelId: id, title: title, thumbnailURL: JSON.lastThumbnail(entry["thumbnail"]))]
        }
        return dict.values.flatMap { guideChannels(in: $0) }
    }
}

extension YouTubeVideo {
    static func cover(of videoId: String) -> String {
        "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }

    var cover: String { thumbnailURL ?? Self.cover(of: videoId) }

    /// True when YouTube's "3 hours ago" counts in seconds, minutes or hours, so under a day.
    // ponytail: reads English and Italian, the languages in use. Other languages show no New badge.
    /// Out today, not live and not opened yet.
    var isNew: Bool {
        isRecent && !isLive && !SeenVideos.contains(videoId)
    }

    var isRecent: Bool {
        (publishedTimeText ?? "").lowercased().split { !$0.isLetter }.contains { Self.recentUnits.contains(String($0)) }
    }

    private static let recentUnits: Set<String> = ["second", "seconds", "minute", "minutes", "hour", "hours", "secondo", "secondi", "minuto", "minuti", "ora", "ore"]
}

/// SwiftyTube sorts a lockup's rows by English words, which fails in other languages and on "208M".
/// Where a part sits says what it is, and YouTube's rows no longer say much else.
enum LockupDetails {
    static func fixed(_ videos: [YouTubeVideo], in node: Any?) -> [YouTubeVideo] {
        var lockups: [String: [String: Any]] = [:]
        collect(node, into: &lockups)
        return videos.map { video in lockups[video.videoId].map { fixed(video, lockup: $0) } ?? video }
    }

    private static func collect(_ node: Any?, into lockups: inout [String: [String: Any]]) {
        if let array = node as? [Any] {
            array.forEach { collect($0, into: &lockups) }
        } else if let dict = node as? [String: Any] {
            for (key, value) in dict {
                if key == "lockupViewModel", let lockup = value as? [String: Any], let id = lockup["contentId"] as? String {
                    lockups[id] = lockup
                } else if key == "shortsLockupViewModel", let lockup = value as? [String: Any], let id = JSON.string("videoId", in: lockup["onTap"]) {
                    lockups[id] = lockup
                } else {
                    collect(value, into: &lockups)
                }
            }
        }
    }

    private static func fixed(_ original: YouTubeVideo, lockup: [String: Any]) -> YouTubeVideo {
        var video = original
        if video.thumbnailURL == nil, let sources = JSON.first("sources", in: lockup["thumbnailViewModel"]) as? [[String: Any]] {
            video.thumbnailURL = sources.last?["url"] as? String
        }
        if video.channelId == nil, let id = JSON.string("browseId", in: JSON.first("decoratedAvatarViewModel", in: lockup)), id.hasPrefix("UC") {
            video.channelId = id
        }
        let rows = (JSON.first("metadataRows", in: lockup["metadata"]) as? [[String: Any]] ?? []).map { row in
            (row["metadataParts"] as? [[String: Any]] ?? []).compactMap { JSON.text($0["text"]) }
        }
        // A row of two parts is the views and the age, unless its first part is the linked channel.
        guard let last = rows.last, last.count == 2, original.channelId == nil || last[0] != original.channelTitle else { return video }
        video.viewCountText = last[0]
        video.publishedTimeText = last[1]
        if rows.count == 1 {
            if original.channelId == nil { video.channelTitle = nil }
        } else if rows[0].count == 1 {
            video.channelTitle = rows[0][0]
        }
        return video
    }

    static func selfCheck() {
        func row(_ parts: String...) -> [String: Any] {
            ["metadataParts": parts.map { ["text": ["content": $0]] }]
        }
        func lockup(_ rows: [[String: Any]]) -> [String: Any] {
            ["metadata": ["metadataRows": rows]]
        }
        let video = YouTubeVideo(videoId: "a", title: "", isLive: false, isShort: false)
        let related = fixed(video, lockup: lockup([row("Rick Astley"), row("208M", "17y ago")]))
        assert(related.channelTitle == "Rick Astley" && related.viewCountText == "208M" && related.publishedTimeText == "17y ago")
        var misread = video
        misread.channelTitle = "10 Mln di visualizzazioni"
        let channelTab = fixed(misread, lockup: lockup([row("10 Mln di visualizzazioni", "2 anni fa")]))
        assert(channelTab.channelTitle == nil && channelTab.publishedTimeText == "2 anni fa")
        // Rows that don't fit stay as SwiftyTube read them.
        misread.viewCountText = "1K watching"
        assert(fixed(misread, lockup: lockup([row("Someone"), row("1K watching")])).viewCountText == "1K watching")
        var linked = video
        linked.channelId = "UCx"
        linked.channelTitle = "Someone"
        assert(fixed(linked, lockup: lockup([row("Someone", "5 views")])).viewCountText == nil)
    }
}

/// Reads a page in display order and keeps each kind of content.
/// SwiftyTube's parser only returns a flat list of videos.
enum FeedParser {
    private static let shelfKeys = ["reelShelfRenderer", "richShelfRenderer", "shelfRenderer", "gridShelfViewModel"]
    private static let postKeys = ["backstagePostThreadRenderer", "backstagePostRenderer", "sharedPostRenderer", "postRenderer"]
    private static let skippedKeys: Set<String> = [
        "responseContext", "header", "topbar", "sidebar", "microformat", "metadata", "frameworkUpdates",
        "continuationItemRenderer", "feedFilterChipBarRenderer", "engagementPanels", "menu"
    ]
    private static let videoKeys: Set<String> = [
        "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "videoWithContextRenderer",
        "playlistVideoRenderer", "reelItemRenderer", "lockupViewModel", "shortsLockupViewModel"
    ]

    static func items(in json: [String: Any]) -> [FeedItem] {
        var found: [FeedItem] = []
        collect(json, into: &found)

        var seen = Set<String>()
        var merged: [FeedItem] = []
        for item in found where seen.insert(item.id).inserted {
            // Single Shorts in a row read better as one shelf.
            if case .shorts(nil, let next) = item, case .shorts(nil, let previous)? = merged.last {
                merged[merged.count - 1] = .shorts(title: nil, previous + next)
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    private static func collect(_ node: Any, into items: inout [FeedItem]) {
        if let array = node as? [Any] {
            array.forEach { collect($0, into: &items) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        if let key = shelfKeys.first(where: { dict[$0] != nil }) {
            appendShelf(dict[key], into: &items)
        } else if postKeys.contains(where: { dict[$0] != nil }) {
            if let post = post(in: dict) { items.append(.post(post)) }
        } else if dict.keys.contains(where: videoKeys.contains) {
            appendVideoOrPlaylist(dict, into: &items)
        } else if dict["channelRenderer"] != nil || dict["gridChannelRenderer"] != nil {
            items += YouTubeFeedParser.channels(in: dict).map { .channel($0) }
        } else {
            for (key, value) in dict where !skippedKeys.contains(key) {
                collect(value, into: &items)
            }
        }
    }

    private static func appendShelf(_ shelf: Any?, into items: inout [FeedItem]) {
        guard let shelf = shelf as? [String: Any] else { return }
        var inner: [FeedItem] = []
        for (key, value) in shelf where !skippedKeys.contains(key) {
            collect(value, into: &inner)
        }
        let title = JSON.text(shelf["title"]) ?? JSON.text(shelf["header"]) ?? JSON.text(JSON.first("headline", in: shelf["header"]))
        let videos = LockupDetails.fixed(YouTubeFeedParser.videos(in: shelf), in: shelf)
        // YouTube's own list of your channels is a shelf with no videos.
        items += inner.filter {
            switch $0 {
            case .post, .channel: return true
            default: return false
            }
        }
        guard !videos.isEmpty else { return }
        if videos.allSatisfy(\.isShort) {
            items.append(.shorts(title: title, videos))
        } else {
            items.append(.shelf(title: title, videos))
        }
    }

    private static func appendVideoOrPlaylist(_ dict: [String: Any], into items: inout [FeedItem]) {
        if let video = LockupDetails.fixed(YouTubeFeedParser.videos(in: dict), in: dict).first {
            if video.isShort {
                items.append(.shorts(title: nil, [video]))
            } else {
                let percent = (JSON.first("percentDurationWatched", in: dict) ?? JSON.first("startPercent", in: dict)) as? Double
                items.append(.video(video, VideoExtras(
                    feedback: feedbackActions(in: dict),
                    collaborators: Collaborator.all(in: dict),
                    progress: percent.map { $0 / 100 },
                    startSeconds: JSON.first("startTimeSeconds", in: dict) as? Double,
                    isUpcoming: JSON.first("upcomingEventData", in: dict) != nil,
                    setVideoId: JSON.string("setVideoId", in: dict)
                )))
            }
        } else if let playlist = YouTubeFeedParser.playlists(in: dict).first ?? show(in: dict) {
            items.append(.playlist(playlist))
        }
    }

    /// A channel's series. SwiftyTube leaves these out, though they open like any playlist.
    private static func show(in dict: [String: Any]) -> YouTubePlaylist? {
        guard let lockup = dict["lockupViewModel"] as? [String: Any],
              lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_SHOW",
              let id = lockup["contentId"] as? String else { return nil }
        let sources = JSON.first("sources", in: lockup["contentImage"]) as? [[String: Any]]
        return YouTubePlaylist(
            playlistId: id,
            title: JSON.text(JSON.first("title", in: lockup["metadata"])) ?? "",
            thumbnailURL: sources?.last?["url"] as? String,
            videoCountText: JSON.string("text", in: JSON.first("thumbnailBadgeViewModel", in: lockup)),
            channelTitle: nil,
            channelId: nil
        )
    }

    private static func feedbackActions(in node: Any?) -> [FeedbackAction] {
        if let array = node as? [Any] {
            return array.flatMap { feedbackActions(in: $0) }
        }
        guard let dict = node as? [String: Any] else { return [] }
        for key in ["menuServiceItemRenderer", "listItemViewModel"] {
            if let item = dict[key] as? [String: Any] {
                guard let title = JSON.text(item["text"]) ?? JSON.text(item["title"]),
                      let token = JSON.string("feedbackToken", in: item) else { return [] }
                return [FeedbackAction(title: title, token: token)]
            }
        }
        return dict.values.flatMap { feedbackActions(in: $0) }
    }

    /// The endpoint's own action: its `clientActions` can hold other keys of the same name.
    private static func commentAction(in endpoint: Any?) -> String? {
        (JSON.first("performCommentActionEndpoint", in: endpoint) as? [String: Any])?["action"] as? String
    }

    private static func post(in dict: [String: Any]) -> CommunityPost? {
        guard let post = (JSON.first("backstagePostRenderer", in: dict) ?? JSON.first("postRenderer", in: dict)) as? [String: Any],
              let id = post["postId"] as? String else { return nil }
        let attachment = post["backstageAttachment"]
        let multiImages = JSON.first("postMultiImageRenderer", in: attachment) as? [String: Any]
        let imageNodes = multiImages?["images"] as? [Any] ?? [attachment].compactMap { $0 }
        let poll = JSON.first("pollRenderer", in: attachment) as? [String: Any]
        let choices = poll?["choices"] as? [[String: Any]] ?? []
        let likeButton = JSON.first("toggleButtonRenderer", in: JSON.first("likeButton", in: post["actionButtons"])) as? [String: Any]
        return CommunityPost(
            id: id,
            author: JSON.text(post["authorText"]) ?? "",
            authorAvatar: JSON.lastThumbnail(post["authorThumbnail"]),
            channelId: JSON.string("browseId", in: post["authorEndpoint"]),
            text: JSON.text(post["contentText"]) ?? "",
            time: JSON.text(post["publishedTimeText"]),
            likes: JSON.text(post["voteCount"]),
            comments: JSON.text(JSON.first("text", in: JSON.first("replyButton", in: post["actionButtons"]))),
            images: imageNodes.compactMap { JSON.lastThumbnail(JSON.first("backstageImageRenderer", in: $0)) },
            video: (attachment as? [String: Any]).flatMap { YouTubeFeedParser.videos(in: $0).first },
            pollChoices: choices.compactMap { choice in
                JSON.text(choice["text"]).map {
                    PollChoice(
                        title: $0,
                        selectAction: commentAction(in: choice["selectServiceEndpoint"]),
                        deselectAction: commentAction(in: choice["deselectServiceEndpoint"]),
                        isSelected: choice["selected"] as? Bool ?? false,
                        percentIfSelected: JSON.text(choice["votePercentageIfSelected"]),
                        percentIfNotSelected: JSON.text(choice["votePercentageIfNotSelected"]),
                        ratioIfSelected: choice["voteRatioIfSelected"] as? Double,
                        ratioIfNotSelected: choice["voteRatioIfNotSelected"] as? Double
                    )
                }
            },
            likeAction: commentAction(in: likeButton?["defaultServiceEndpoint"]),
            unlikeAction: commentAction(in: likeButton?["toggledServiceEndpoint"]),
            isLiked: likeButton?["isToggled"] as? Bool ?? false
        )
    }
}

/// The last Home page, shown at launch while the new one loads. Each account has its own.
enum SavedHome {
    static var file: URL { URL.cachesDirectory.appending(path: "home-\(ProfileStorage.active).json") }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    static func write(_ json: [String: Any], to file: URL) {
        try? JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
    }

    static func read(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
