import Foundation
import Observation

/// Plays a video on a TV through YouTube's "Link with TV code", which YouTube on TV and SmartTube both accept.
@MainActor
@Observable
final class TVLink {
    static let shared = TVLink()

    struct Screen: Codable {
        let id: String
        let name: String
    }

    private(set) var screen: Screen? = TVLink.saved

    private static let storageKey = "tvScreen"
    private static let base = URL(string: "https://www.youtube.com/api/lounge/")!
    private static let deviceId = UUID().uuidString

    private static var saved: Screen? {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Screen.self, from: $0) }
    }

    func pair(code: String) async throws {
        let answer: String
        do {
            answer = try await Self.send("pairing/get_screen", form: ["pairing_code": code.filter(\.isNumber)])
        } catch TVLinkError.noAnswer(404) {
            throw TVLinkError.wrongCode
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
              let found = json["screen"] as? [String: Any],
              let id = found["screenId"] as? String else { throw TVLinkError.wrongCode }
        let screen = Screen(id: id, name: found["name"] as? String ?? "TV")
        UserDefaults.standard.set(try? JSONEncoder().encode(screen), forKey: Self.storageKey)
        self.screen = screen
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        screen = nil
    }

    /// Asks for a fresh token, joins the TV's session, then replaces what it plays.
    func play(videoId: String, at seconds: Double) async throws {
        guard let screen else { throw TVLinkError.wrongCode }
        let tokens = try await Self.send("pairing/get_lounge_token_batch", form: ["screen_ids": screen.id])
        guard let json = try? JSONSerialization.jsonObject(with: Data(tokens.utf8)) as? [String: Any],
              let token = (json["screens"] as? [[String: Any]])?.first?["loungeToken"] as? String else { throw TVLinkError.noAnswer(0) }
        let bind = try await Self.send("bc/bind", query: ["RID": "0", "VER": "8", "CVER": "1"], form: [
            "device": "REMOTE_CONTROL", "id": Self.deviceId, "name": "WoofTube",
            "mdx-version": "3", "pairing_type": "cast", "app": "android-phone-13.14.55"
        ], token: token)
        guard let session = Self.session(in: bind) else { throw TVLinkError.noAnswer(0) }
        _ = try await Self.send("bc/bind", query: ["SID": session.sid, "gsessionid": session.gsessionid, "RID": "1", "VER": "8", "CVER": "1"], form: [
            "count": "1", "req0__sc": "setPlaylist", "req0_videoId": videoId, "req0_currentTime": String(Int(seconds)),
            "req0_currentIndex": "-1", "req0_listId": "", "req0_audioOnly": "false"
        ], token: token)
    }

    /// The bind answer is a list of chunks: "c" carries the session id, "S" the gsessionid.
    static func session(in answer: String) -> (sid: String, gsessionid: String)? {
        guard let sid = answer.firstMatch(of: #/"c","(.*?)","/#)?.1,
              let gsessionid = answer.firstMatch(of: #/"S","(.*?)"]/#)?.1 else { return nil }
        return (String(sid), String(gsessionid))
    }

    private static func send(_ path: String, query: [String: String] = [:], form: [String: String], token: String? = nil) async throws -> String {
        var parts = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let token { request.setValue(token, forHTTPHeaderField: "X-YouTube-LoungeId-Token") }
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A form reads + as a space, and URLComponents leaves it as it is.
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TVLinkError.noAnswer(status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func selfCheck() {
        let parsed = session(in: #"[[0,["c","SID123","",8]],[1,["S","GS456"]]]"#)
        assert(parsed?.sid == "SID123" && parsed?.gsessionid == "GS456")
        assert(session(in: "[]") == nil)
    }
}

enum TVLinkError: LocalizedError {
    case wrongCode
    case noAnswer(Int)

    var errorDescription: String? {
        switch self {
        case .wrongCode: "That code doesn't match a TV. Check the code on the TV and try again."
        case .noAnswer: "The TV didn't answer. Open YouTube or SmartTube on the TV and try again."
        }
    }
}
