import Foundation

/// A YouTube address the app can open by itself. These come from other apps or the clipboard, so ids are checked.
enum YouTubeLink: Equatable {
    case video(String)
    case short(String)
    case channel(String)
    /// An @handle, /c/ or /user/ path, which only YouTube can turn into a channel.
    case channelPath(String)

    private static let webHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com", "youtu.be", "www.youtu.be"
    ]
    private static let appSchemes: Set<String> = ["wooftube", "youtube", "vnd.youtube"]

    init?(url: URL) {
        guard let link = Self.parse(url) else { return nil }
        self = link
    }

    private static func parse(_ url: URL) -> YouTubeLink? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased() else { return nil }
        let host = parts.host?.lowercased()
        var path = parts.path.split(separator: "/").map(String.init)
        let isAppScheme = appSchemes.contains(scheme)
        if isAppScheme {
            // youtube://watch?v=… has no real host, and vnd.youtube://ID has the id there.
            if let original = parts.host, let host, !webHosts.contains(host) { path.insert(original, at: 0) }
        } else {
            guard scheme == "http" || scheme == "https", let host, webHosts.contains(host) else { return nil }
        }
        guard let first = path.first else { return nil }
        let second = path.count > 1 ? path[1] : nil

        if host == "youtu.be" || host == "www.youtu.be" {
            return videoLink(first)
        }
        switch first {
        case "watch":
            return videoLink(parts.queryItems?.first { $0.name == "v" }?.value)
        case "live", "embed", "v":
            return videoLink(second)
        case "shorts":
            guard let second, isVideoId(second) else { return nil }
            return .short(second)
        case "channel":
            guard let second, second.hasPrefix("UC") else { return nil }
            return .channel(second)
        case "c", "user":
            guard let second else { return nil }
            return .channelPath("/\(first)/\(second)")
        default:
            if first.hasPrefix("@"), first.count > 1 { return .channelPath("/\(first)") }
            return isAppScheme ? videoLink(first) : nil
        }
    }

    /// For text in the search field. Ordinary searches return nil.
    init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let hasScheme = text.contains("://") || text.lowercased().hasPrefix("vnd.youtube:")
        guard let url = URL(string: hasScheme ? text : "https://" + text) else { return nil }
        self.init(url: url)
    }

    private static func videoLink(_ id: String?) -> YouTubeLink? {
        guard let id, isVideoId(id) else { return nil }
        return .video(id)
    }

    private static func isVideoId(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func selfCheck() {
        let id = "dQw4w9WgXcQ"
        for text in [
            "https://www.youtube.com/watch?v=\(id)&list=PL1&t=30", "http://m.youtube.com/watch?v=\(id)", "youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)?si=abc", "youtu.be/\(id)", "https://www.youtube.com/live/\(id)", "https://www.youtube.com/embed/\(id)",
            "youtube://www.youtube.com/watch?v=\(id)", "youtube://watch?v=\(id)", "vnd.youtube://\(id)", "vnd.youtube:\(id)",
            "wooftube://www.youtube.com/watch?v=\(id)", "  https://youtu.be/\(id)\n"
        ] {
            assert(YouTubeLink(text: text) == .video(id), text)
        }
        assert(YouTubeLink(text: "https://www.youtube.com/shorts/\(id)") == .short(id))
        assert(YouTubeLink(text: "https://www.youtube.com/channel/UCabc") == .channel("UCabc"))
        assert(YouTubeLink(text: "https://www.youtube.com/@LinusTechTips/videos") == .channelPath("/@LinusTechTips"))
        assert(YouTubeLink(text: "https://www.youtube.com/c/Linus") == .channelPath("/c/Linus"))
        for text in [
            "cat", "how to cook", "LTT", "@LinusTechTips", "https://example.com/watch?v=\(id)", "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/playlist?list=PL1", "https://www.youtube.com/", "youtube://", "https://notyoutube.com/@a"
        ] {
            assert(YouTubeLink(text: text) == nil, text)
        }
    }
}
