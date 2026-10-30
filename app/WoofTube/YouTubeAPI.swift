import Foundation
import SwiftyTube

/// Small helpers for reading YouTube's deeply nested JSON.
enum JSON {
    static func first(_ key: String, in object: Any?) -> Any? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values {
                if let found = first(key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = first(key, in: value) { return found }
            }
        }
        return nil
    }

    static func string(_ key: String, in object: Any?) -> String? {
        first(key, in: object) as? String
    }

    /// YouTube writes text as a string, `simpleText`, `content` or a list of `runs`.
    static func text(_ object: Any?) -> String? {
        if let string = object as? String { return string }
        guard let dict = object as? [String: Any] else { return nil }
        if let text = dict["simpleText"] as? String ?? dict["content"] as? String { return text }
        let runs = (dict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        return runs?.joined()
    }

    static func lastThumbnail(_ object: Any?) -> String? {
        let thumbnails = first("thumbnails", in: object) as? [[String: Any]]
        return thumbnails?.last?["url"] as? String
    }
}

struct YouTubeAPIError: LocalizedError {
    let errorDescription: String?
}

/// SwiftyTube keeps its generic POST internal, so endpoints it has no method
/// for are sent from here with the same headers as its WEB client.
enum YouTubeAPI {
    static func post(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        let tube = InnerTubeClient.wooftube
        let auth = await tube.currentAuth()
        let client = YouTubeClient.web
        let origin = YouTubeService.youtube.origin

        var clientContext: [String: Any] = [
            "clientName": client.clientName,
            "clientVersion": client.clientVersion,
            "hl": Locale.current.language.languageCode?.identifier ?? "en",
            "gl": Locale.current.region?.identifier ?? "US",
            "userAgent": client.userAgent,
            "platform": "DESKTOP"
        ]
        clientContext["visitorData"] = auth.visitorData
        var payload = body
        payload["context"] = ["client": clientContext, "user": ["lockedSafetyMode": false]]

        var request = URLRequest(url: YouTubeService.youtube.baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(client.clientId)", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(auth.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue(auth.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        if let sapisid = auth.sapisid {
            request.setValue(SAPISIDAuth.authorizationHeader(sapisid: sapisid, origin: origin), forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw YouTubeAPIError(errorDescription: "\(endpoint): \(message ?? "HTTP \(status)")")
        }
        if JSON.string("status", in: json["actionResult"]) == "STATUS_FAILED" {
            throw YouTubeAPIError(errorDescription: JSON.text(JSON.first("feedback", in: json["actionResult"])) ?? "YouTube refused this action.")
        }
        return json
    }
}

/// Everything on the video page that SwiftyTube's watch parser leaves out.
struct WatchDetails {
    var description: String?
    var metadata: String?
    var channelTitle: String?
    var channelId: String?
    var channelAvatar: String?
    var subscribers: String?
    var isSubscribed = false
    var likeCount: String?
    var likeCountLiked: String?
    var likeStatus = "INDIFFERENT"
    var related: [YouTubeVideo] = []
    var commentsToken: String?

    init(json: [String: Any], videoId: String) {
        let secondary = JSON.first("videoSecondaryInfoRenderer", in: json)
        let primary = JSON.first("videoPrimaryInfoRenderer", in: json)
        let owner = JSON.first("videoOwnerRenderer", in: secondary)
        let subscribeButton = JSON.first("subscribeButtonRenderer", in: secondary) as? [String: Any]
        let likeButton = JSON.first("segmentedLikeDislikeButtonViewModel", in: json)
        let toggle = JSON.first("toggleButtonViewModel", in: likeButton)

        description = JSON.text(JSON.first("attributedDescription", in: secondary))
        metadata = [JSON.text(JSON.first("viewCount", in: primary)), JSON.text(JSON.first("dateText", in: primary))]
            .compactMap { $0 }
            .joined(separator: " · ")
        channelTitle = JSON.text(JSON.first("title", in: owner))
        channelId = subscribeButton?["channelId"] as? String ?? JSON.string("browseId", in: JSON.first("navigationEndpoint", in: owner))
        channelAvatar = JSON.lastThumbnail(JSON.first("thumbnail", in: owner))
        subscribers = JSON.text(JSON.first("subscriberCountText", in: owner))
        isSubscribed = subscribeButton?["subscribed"] as? Bool ?? false
        likeCount = JSON.string("title", in: JSON.first("defaultButtonViewModel", in: toggle))
        likeCountLiked = JSON.string("title", in: JSON.first("toggledButtonViewModel", in: toggle))
        likeStatus = JSON.string("likeStatus", in: likeButton) ?? "INDIFFERENT"

        let watch = YouTubeWatchParser.watch(in: json, videoId: videoId)
        related = watch.related
        commentsToken = watch.commentsContinuation
    }
}
