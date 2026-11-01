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
    var isUpcoming = false
    /// Identifies the video's entry in a playlist, which removing it needs.
    var setVideoId: String?
}

struct PollChoice {
    let title: String
    let action: String?
    let isSelected: Bool
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
final class Subscriptions: ObservableObject {
    static let shared = Subscriptions()

    @Published private(set) var channels: [YouTubeChannel] = []
    @Published private(set) var ids: Set<String> = []
    @Published private(set) var isLoading = true

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
    /// True when YouTube's "3 hours ago" counts in seconds, minutes or hours, so under a day.
    // ponytail: reads English and Italian, the languages in use. Other languages show no New badge.
    var isRecent: Bool {
        let units: Set<String> = ["second", "seconds", "minute", "minutes", "hour", "hours", "secondo", "secondi", "minuto", "minuti", "ora", "ore"]
        return (publishedTimeText ?? "").lowercased().split { !$0.isLetter }.contains { units.contains(String($0)) }
    }
}

/// Reads a page in display order and keeps each kind of content.
/// SwiftyTube's parser only returns a flat list of videos.
enum FeedParser {
    private(set) static var seenContentTypes: Set<String> = []
    private(set) static var homePages = 0
    private(set) static var homePostsSent = 0
    private(set) static var homePostsShown = 0

    /// Tells a bug from a feed with no posts: if YouTube sends posts, both numbers rise.
    static func noteHomePage(_ json: [String: Any], items: [FeedItem]) {
        homePages += 1
        homePostsSent += postCount(in: json)
        homePostsShown += items.filter { if case .post = $0 { return true } else { return false } }.count
    }

    private static func postCount(in node: Any) -> Int {
        if let array = node as? [Any] { return array.reduce(0) { $0 + postCount(in: $1) } }
        guard let dict = node as? [String: Any] else { return 0 }
        return dict.reduce(0) { total, entry in
            total + (entry.key == "backstagePostRenderer" || entry.key == "postRenderer" ? 1 : postCount(in: entry.value))
        }
    }


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

        for key in ["richItemRenderer", "richSectionRenderer"] {
            if let content = (dict[key] as? [String: Any])?["content"] as? [String: Any] {
                seenContentTypes.formUnion(content.keys)
            }
        }
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
        let title = JSON.text(shelf["title"]) ?? JSON.text(shelf["header"])
        let videos = YouTubeFeedParser.videos(in: shelf)
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
        if let video = YouTubeFeedParser.videos(in: dict).first {
            if video.isShort {
                items.append(.shorts(title: nil, [video]))
            } else {
                let percent = (JSON.first("percentDurationWatched", in: dict) ?? JSON.first("startPercent", in: dict)) as? Double
                items.append(.video(video, VideoExtras(
                    feedback: feedbackActions(in: dict),
                    collaborators: Collaborator.all(in: dict),
                    progress: percent.map { $0 / 100 },
                    isUpcoming: JSON.first("upcomingEventData", in: dict) != nil,
                    setVideoId: JSON.string("setVideoId", in: dict)
                )))
            }
        } else if let playlist = YouTubeFeedParser.playlists(in: dict).first {
            items.append(.playlist(playlist))
        }
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
                    PollChoice(title: $0, action: JSON.string("action", in: choice["selectServiceEndpoint"]), isSelected: choice["selected"] as? Bool ?? false)
                }
            },
            likeAction: JSON.string("action", in: likeButton?["defaultServiceEndpoint"]),
            unlikeAction: JSON.string("action", in: likeButton?["toggledServiceEndpoint"]),
            isLiked: likeButton?["isToggled"] as? Bool ?? false
        )
    }
}
