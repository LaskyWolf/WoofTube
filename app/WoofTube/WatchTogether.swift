import Combine
import Foundation
import Observation
import SwiftyTube

/// Watch Together: several people watch the same video at the same moment. Each phone
/// streams the video itself; a metroserver relays only what the host does (video, play,
/// pause, seek, queue). Rooms are shared with Woof Music and Metrolist on the same server.
///
/// - Host: every half second the player is compared with what the room was last told,
///   and the difference is sent.
/// - Guest: the room's messages drive the player, and the server's drift reports pull it
///   back when it runs ahead or behind.
@MainActor
@Observable
final class WatchTogether {
    static let shared = WatchTogether()

    /// Metrolist's public server, so rooms can mix the apps.
    nonisolated static let defaultServerURL = "wss://metroserverx.meowery.eu/ws"
    nonisolated static let serverKey = "watchTogether.serverURL"
    nonisolated static let usernameKey = "watchTogether.username"
    nonisolated static let fallbackName = "WoofTube viewer"

    enum Status: Equatable {
        case idle
        case connecting
        case waitingForApproval
        case inRoom
        /// The connection dropped; trying to get back into the same room.
        case reconnecting
    }

    private(set) var status: Status = .idle
    private(set) var roomCode: String?
    private(set) var myUserId: String?
    private(set) var hostId: String?
    private(set) var users: [LTUser] = []
    /// Host only: people waiting to be let in.
    private(set) var joinRequests: [LTUserEvent] = []
    /// Host only: videos guests asked for.
    private(set) var suggestions: [LTSuggestion] = []
    /// The last thing worth telling the user: an error, a refusal, a kick.
    var notice: String?

    var isInRoom: Bool { roomCode != nil }
    var isHost: Bool { isInRoom && hostId != nil && hostId == myUserId }
    /// While a guest, the room drives playback.
    var isGuest: Bool { isInRoom && !isHost }

    /// The player the room drives or reports. The Watch Together screen attaches it.
    @ObservationIgnored private weak var router: Router?
    @ObservationIgnored private var clockWatch: AnyCancellable?
    /// mpv's last position update and when it came, to place the player between updates.
    @ObservationIgnored private var clockMark = (time: 0.0, at: Date.distantPast)

    // Connection
    @ObservationIgnored private var connection: WatchTogetherConnection?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// What to ask once the server has answered the capabilities.
    @ObservationIgnored private var pendingRequest: Request?
    @ObservationIgnored private var sessionToken: String?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var leaving = false
    /// The name this phone joined with, for the first row of a new room.
    @ObservationIgnored private var myName = ""

    /// Server clock minus this phone's clock, in ms, from the pings.
    @ObservationIgnored private var clockOffset: Int64 = 0
    @ObservationIgnored private var pingSequence: UInt64 = 0
    @ObservationIgnored private var lastPing = Date.distantPast

    // Host: what the room was last told.
    @ObservationIgnored private var hostSequence: UInt64 = 0
    @ObservationIgnored private var sentTrackId: String?
    @ObservationIgnored private var sentPlaying = false
    @ObservationIgnored private var sentQueueIds: [String] = []
    @ObservationIgnored private var lastPosition: (seconds: Double, at: Date)?

    // Guest: the video the room is on, until this phone has loaded it.
    @ObservationIgnored private var awaitingBuffer: (trackId: String, revision: UInt64)?
    @ObservationIgnored private var lastDriftFix = Date.distantPast

    private enum Request {
        case create(username: String)
        case join(code: String, username: String)
        case reconnect(token: String)
    }

    private static let features = [
        "drift_report", "origin_tag", "server_restarting", "suggestion_ack",
        "replace_queue", "host_sequence", "track_revision"
    ]
    /// The most queue entries sent to the room; metroserver caps it too.
    private static let maxQueue = 100
    /// metroserver refuses longer names.
    private static let maxNameBytes = 50
    /// A position jump bigger than this, between two ticks, is a seek.
    private static let seekThreshold = 2.0
    /// Guests further than this from the room jump back into place.
    private static let maxDriftMs: Int64 = 400
    /// Seconds between two drift fixes, so a fix can settle before the next report.
    private static let driftCooldown = 4.0
    private static let tickInterval = Duration.milliseconds(500)
    private static let pingInterval = 5.0
    /// How often, and how many times, a guest checks that the room's video has started loading.
    private static let loadPollInterval = Duration.milliseconds(50)
    private static let loadPolls = 600
    /// mpv reports the position every quarter second.
    private static let clockStep = 0.25

    private init() {}

    func attach(_ router: Router) {
        guard self.router !== router else { return }
        self.router = router
        clockWatch = router.player.clock.$time.sink { [weak self] time in self?.clockMark = (time, Date()) }
    }

    // MARK: - Actions

    /// `accountName` is the fallback when no name is set in Watch Together.
    func createRoom(accountName: String?) {
        start(.create(username: name(accountName)))
    }

    func joinRoom(code: String, accountName: String?) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return }
        start(.join(code: code, username: name(accountName)))
    }

    func leave() {
        leaving = true
        if isInRoom { connection?.send(LTMessage.leaveRoom) }
        shutDown()
        resetRoom()
        status = .idle
    }

    func approve(_ request: LTUserEvent) {
        connection?.send(LTMessage.approveJoin, LTUserAction(userId: request.userId))
        joinRequests.removeAll { $0.userId == request.userId }
    }

    func reject(_ request: LTUserEvent) {
        connection?.send(LTMessage.rejectJoin, LTUserAction(userId: request.userId))
        joinRequests.removeAll { $0.userId == request.userId }
    }

    func approve(_ suggestion: LTSuggestion) {
        connection?.send(LTMessage.approveSuggestion, LTSuggestionAction(suggestionId: suggestion.suggestionId))
        suggestions.removeAll { $0.id == suggestion.id }
    }

    func reject(_ suggestion: LTSuggestion) {
        connection?.send(LTMessage.rejectSuggestion, LTSuggestionAction(suggestionId: suggestion.suggestionId))
        suggestions.removeAll { $0.id == suggestion.id }
    }

    func kick(_ user: LTUser) {
        connection?.send(LTMessage.kickUser, LTUserAction(userId: user.userId))
    }

    func makeHost(_ user: LTUser) {
        connection?.send(LTMessage.transferHost, LTUserAction(userId: user.userId))
    }

    /// Guests ask the host to play a video next.
    func suggest(_ video: YouTubeVideo) {
        connection?.send(LTMessage.suggestTrack, LTSuggestTrack(track: Self.track(for: video)))
    }

    // MARK: - Names

    // Woof Music adds its YouTube channel ID to a member's name: "Name \u{2063}UC…".
    private static let channelTag = " \u{2063}"

    /// The name to show, without the channel ID a Woof Music member added to it.
    static func displayName(_ username: String) -> String {
        guard let range = username.range(of: channelTag, options: .backwards) else { return username }
        let id = username[range.upperBound...]
        guard id.count == 24, id.hasPrefix("UC") else { return username }
        return String(username[..<range.lowerBound])
    }

    /// The name from settings, else the account's, cut to what metroserver accepts.
    private func name(_ accountName: String?) -> String {
        var name = (UserDefaults.standard.string(forKey: Self.usernameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = accountName ?? "" }
        if name.isEmpty { name = Self.fallbackName }
        while name.utf8.count > Self.maxNameBytes { name.removeLast() }
        myName = name
        return name
    }

    // MARK: - Connection

    private func start(_ request: Request) {
        leaving = false
        notice = nil
        shutDown()
        if case .reconnect = request {
            status = .reconnecting
        } else {
            resetRoom()
            status = .connecting
        }
        let text = (UserDefaults.standard.string(forKey: Self.serverKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.isEmpty ? Self.defaultServerURL : text),
              url.scheme == "ws" || url.scheme == "wss" else {
            notice = "The server address must start with wss:// or ws://."
            status = .idle
            return
        }
        pendingRequest = request
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let connection = WatchTogetherConnection(url: url, userAgent: "WoofTube/\(version) (iOS)")
        self.connection = connection
        connection.send(LTMessage.clientCapabilities, LTClientCapabilities(clientVersion: "WoofTube \(version)", features: Self.features))
        listenTask = Task { [weak self] in
            for await event in connection.events {
                guard let self, self.connection === connection else { return }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func shutDown() {
        listenTask?.cancel()
        tickTask?.cancel()
        reconnectTask?.cancel()
        connection?.close()
        connection = nil
    }

    private func resetRoom() {
        roomCode = nil
        myUserId = nil
        hostId = nil
        users = []
        joinRequests = []
        suggestions = []
        sessionToken = nil
        reconnectAttempts = 0
        sentTrackId = nil
        sentQueueIds = []
        lastPosition = nil
        awaitingBuffer = nil
    }

    private func handle(_ event: WatchTogetherConnection.Event) {
        switch event {
        case .opened:
            break
        case .message(let type, let payload):
            do {
                try handleMessage(type, payload)
            } catch {
                FileLog.shared.append("watchTogether", "WARNING", "unreadable \(type): \(error)")
            }
        case .closed(let reason):
            FileLog.shared.append("watchTogether", "NOTICE", "connection closed: \(reason)")
            connection = nil
            tickTask?.cancel()
            if leaving { return }
            if let token = sessionToken, isInRoom {
                scheduleReconnect(token: token)
            } else {
                notice = status == .connecting ? "Couldn't reach the Watch Together server." : "Disconnected from the room."
                resetRoom()
                status = .idle
            }
        }
    }

    /// Tries again with a growing pause, up to about 15 minutes: how long the
    /// server keeps a place in the room.
    private func scheduleReconnect(token: String, after seconds: Double? = nil) {
        status = .reconnecting
        reconnectAttempts += 1
        guard reconnectAttempts <= 30 else {
            notice = "Lost the connection to the room."
            resetRoom()
            status = .idle
            return
        }
        let delay = seconds ?? min(30, pow(2, Double(reconnectAttempts - 1)))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.status == .reconnecting else { return }
            self.start(.reconnect(token: token))
        }
    }

    // MARK: - Messages

    private func handleMessage(_ type: String, _ payload: Data) throws {
        switch type {
        case LTMessage.serverCapabilities:
            switch pendingRequest {
            case .create(let name): connection?.send(LTMessage.createRoom, LTCreateRoom(username: name))
            case .join(let code, let name):
                connection?.send(LTMessage.joinRoom, LTJoinRoom(roomCode: code, username: name))
                status = .waitingForApproval
            case .reconnect(let token): connection?.send(LTMessage.reconnect, LTReconnect(sessionToken: token))
            case nil: break
            }
            pendingRequest = nil

        case LTMessage.roomCreated:
            enter(try LTJoined.decode(.created, payload))
        case LTMessage.joinApproved:
            enter(try LTJoined.decode(.approved, payload))
        case LTMessage.reconnected:
            enter(try LTJoined.decode(.reconnected, payload))
        case LTMessage.joinRejected:
            let reason = try LTNotice(decoding: payload).code
            notice = reason.isEmpty ? "The host didn't let you in." : "The host didn't let you in: \(reason)"
            leaveQuietly()
        case LTMessage.kicked:
            let reason = try LTNotice(decoding: payload).code
            notice = reason.isEmpty ? "The host removed you from the room." : "Removed from the room: \(reason)"
            leaveQuietly()

        case LTMessage.joinRequest:
            let request = try LTUserEvent(decoding: payload)
            joinRequests.removeAll { $0.userId == request.userId }
            joinRequests.append(request)
        case LTMessage.userJoined:
            let user = try LTUserEvent(decoding: payload)
            users.removeAll { $0.userId == user.userId }
            users.append(LTUser(userId: user.userId, username: user.username, isHost: false, isConnected: true))
            joinRequests.removeAll { $0.userId == user.userId }
        case LTMessage.userLeft:
            let user = try LTUserEvent(decoding: payload)
            users.removeAll { $0.userId == user.userId }
        case LTMessage.userDisconnected, LTMessage.userReconnected:
            let user = try LTUserEvent(decoding: payload)
            if let index = users.firstIndex(where: { $0.userId == user.userId }) {
                users[index].isConnected = type == LTMessage.userReconnected
            }
        case LTMessage.hostChanged:
            setHost(try LTUserEvent(decoding: payload).userId)

        case LTMessage.syncPlayback:
            let playback = try LTPlayback(decoding: payload)
            isHost ? hostReceived(playback) : guestApply(playback)
        case LTMessage.syncState:
            let state = try LTSyncState(decoding: payload)
            if isGuest { guestLoad(state.currentTrack, revision: 0) }

        case LTMessage.suggestionReceived:
            suggestions.append(try LTSuggestion.decode(.received, payload))
        case LTMessage.suggestionApproved:
            let track = try LTSuggestion.decode(.approved, payload).track
            if !isHost { notice = "The host added \(track.title)." }
        case LTMessage.suggestionRejected:
            if !isHost { notice = "The host passed on your suggestion." }
        case LTMessage.suggestionSubmitted:
            notice = "Suggestion sent to the host."

        case LTMessage.pong:
            handlePong(try LTPong(decoding: payload))
        case LTMessage.serverRestarting:
            let eta = Double(try LTServerRestarting(decoding: payload).etaMs) / 1000
            if let token = sessionToken {
                reconnectAfterRestart(token: token, after: max(1, eta) + Double.random(in: 0...2))
            }
        case LTMessage.error:
            let error = try LTNotice(decoding: payload)
            FileLog.shared.append("watchTogether", "WARNING", "server error \(error.code): \(error.message)")
            // Races the next message repairs on its own.
            if ["stale_action", "stale_track", "sync_rate_limited"].contains(error.code) { return }
            if status == .reconnecting {
                notice = "The room has closed."
                leaveQuietly()
                return
            }
            notice = error.message.isEmpty ? error.code : error.message
            if status == .waitingForApproval || status == .connecting { leaveQuietly() }
        default:
            break
        }
    }

    private func enter(_ joined: LTJoined) {
        roomCode = joined.roomCode
        myUserId = joined.userId
        if !joined.sessionToken.isEmpty { sessionToken = joined.sessionToken }
        reconnectAttempts = 0
        status = .inRoom
        if let state = joined.state {
            users = state.users
            setHost(state.hostId)
            if isGuest { guestLoad(state.currentTrack, revision: 0) }
        } else {
            // A new room: just this phone, as its host.
            users = [LTUser(userId: joined.userId, username: myName, isHost: true, isConnected: true)]
            setHost(joined.userId)
        }
    }

    private func setHost(_ id: String) {
        let wasHost = isHost
        hostId = id
        for index in users.indices { users[index].isHost = users[index].userId == id }
        guard isHost, !wasHost else { return }
        // Just became host: the room is already on this video, so only what
        // changes from here on is sent. A new room hears the video from scratch.
        let roomHasVideo = users.count > 1
        sentTrackId = roomHasVideo ? router?.current?.videoId : nil
        sentPlaying = roomHasVideo && router?.player.isPaused == false
        sentQueueIds = roomHasVideo ? (router?.queue.prefix(Self.maxQueue).map(\.videoId) ?? []) : []
        lastPosition = nil
        awaitingBuffer = nil
    }

    /// Ends the room locally, without telling the server (it already knows).
    private func leaveQuietly() {
        leaving = true
        shutDown()
        resetRoom()
        status = .idle
    }

    private func reconnectAfterRestart(token: String, after seconds: Double) {
        leaving = true
        shutDown()
        leaving = false
        scheduleReconnect(token: token, after: seconds)
    }

    // MARK: - Clock

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var serverNowMs: Int64 { nowMs + clockOffset }

    /// The player's position, run on from mpv's last quarter-second update so the
    /// drift check isn't off by up to a quarter second.
    private func position(of player: MpvPlayer) -> Double {
        guard !player.isPaused, !player.isBuffering, clockMark.time == player.time else { return player.time }
        return player.time + min(Date().timeIntervalSince(clockMark.at), Self.clockStep) * player.speed
    }

    /// True while the player shows the video it should, ready and not waiting for data.
    private func isSteady(_ player: MpvPlayer) -> Bool {
        player.isVideoReady && !player.isBuffering && player.duration > 0
    }

    private func sendPing() {
        lastPing = Date()
        pingSequence += 1
        var ping = LTPing()
        ping.clientTime = nowMs
        ping.sequence = pingSequence
        // A guest playing a loaded video reports where it is, for the drift check.
        if isGuest, awaitingBuffer == nil, let router, let id = router.current?.videoId,
           !router.player.isPaused, isSteady(router.player) {
            ping.trackId = id
            ping.position = Int64(position(of: router.player) * 1000)
            ping.capturedAt = serverNowMs
        }
        connection?.send(LTMessage.ping, ping)
    }

    private func handlePong(_ pong: LTPong) {
        // Assumes the trip there and back take as long: the usual NTP guess.
        let received = nowMs
        clockOffset = ((pong.serverReceiveTime - pong.clientTime) + (pong.serverSendTime - received)) / 2
        guard isGuest, pong.driftValid, abs(pong.driftMs) > Self.maxDriftMs,
              Date().timeIntervalSince(lastDriftFix) > Self.driftCooldown,
              let player = router?.player, !player.isPaused, isSteady(player) else { return }
        lastDriftFix = Date()
        player.seek(to: max(0, position(of: player) - Double(pong.driftMs) / 1000))
    }

    // MARK: - Tick

    private func tick() {
        guard connection != nil else { return }
        if Date().timeIntervalSince(lastPing) >= Self.pingInterval { sendPing() }
        guard status == .inRoom else { return }
        if isHost {
            hostTick()
        } else {
            guestTick()
        }
    }

    // MARK: - Host

    private func hostTick() {
        guard let router, let video = router.current else { return }
        let player = router.player
        let upcoming = router.queue.prefix(Self.maxQueue)
        let queueIds = upcoming.map(\.videoId)

        if video.videoId != sentTrackId {
            var change = action(.changeTrack)
            change.track = Self.track(for: video, duration: player.duration)
            change.queue = upcoming.map { Self.track(for: $0) }
            change.replaceQueue = true
            connection?.send(LTMessage.playbackAction, change)
            sentTrackId = video.videoId
            // change_track leaves the room paused at 0; play follows once loaded.
            sentPlaying = false
            sentQueueIds = queueIds
            lastPosition = nil
            return
        }
        if queueIds != sentQueueIds {
            var sync = action(.syncQueue)
            sync.queue = upcoming.map { Self.track(for: $0) }
            connection?.send(LTMessage.playbackAction, sync)
            sentQueueIds = queueIds
        }
        guard isSteady(player) else { return }

        let isPlaying = !player.isPaused
        let position = self.position(of: player)
        if isPlaying != sentPlaying {
            sendTransport(isPlaying ? .play : .pause, trackId: video.videoId, position: position)
            sentPlaying = isPlaying
        } else if let last = lastPosition {
            let expected = last.seconds + (isPlaying ? Date().timeIntervalSince(last.at) * player.speed : 0)
            if abs(position - expected) > Self.seekThreshold {
                sendTransport(.seek, trackId: video.videoId, position: position)
            }
        }
        lastPosition = (position, Date())
    }

    private func action(_ kind: LTPlayback.Action) -> LTPlayback {
        hostSequence += 1
        var playback = LTPlayback(kind)
        playback.hostSequence = hostSequence
        return playback
    }

    private func sendTransport(_ kind: LTPlayback.Action, trackId: String, position: Double) {
        var playback = action(kind)
        playback.trackId = trackId
        playback.position = Int64(max(0, position) * 1000)
        playback.capturedAt = serverNowMs
        connection?.send(LTMessage.playbackAction, playback)
    }

    /// The host's own actions come back too; only a suggestion the host
    /// approved needs doing here: it plays next.
    private func hostReceived(_ playback: LTPlayback) {
        guard playback.action == LTPlayback.Action.queueAdd.rawValue,
              playback.originUserId != myUserId, let track = playback.track else { return }
        router?.playNext(Self.video(for: track))
    }

    // MARK: - Guest

    private func guestApply(_ playback: LTPlayback) {
        guard let router else { return }
        let player = router.player
        // Where the host is now: the position plus the time since the server sent it.
        let elapsed = Double(max(0, serverNowMs - playback.serverTime)) / 1000
        let position = Double(playback.position) / 1000
        let isOnTrack = awaitingBuffer == nil && playback.trackId == router.current?.videoId
        switch LTPlayback.Action(rawValue: playback.action) {
        case .changeTrack:
            guestLoad(playback.track, revision: playback.revision)
        case .play:
            guard isOnTrack else { return }
            let target = position + elapsed
            if abs(self.position(of: player) - target) > 0.5 { player.seek(to: target) }
            player.setPaused(false)
        case .pause:
            guard isOnTrack else { return }
            player.setPaused(true)
            player.seek(to: position)
        case .seek:
            guard isOnTrack else { return }
            player.seek(to: player.isPaused ? position : position + elapsed)
        // ponytail: the room's queue isn't copied into this phone's queue (Router keeps it
        // private); the host's change_track moves guests on. Add a Router setter if guests should see it.
        case .queueAdd, .queueRemove, .queueClear, .syncQueue, nil:
            break
        }
    }

    /// Puts the room's video on this phone, paused: once it has loaded,
    /// `buffer_ready` asks the server where the room is, and it answers with
    /// a seek and a play.
    private func guestLoad(_ track: LTTrack?, revision: UInt64) {
        guard let router, let track, !track.id.isEmpty else { return }
        awaitingBuffer = (track.id, revision)
        // Already here, e.g. the video was open before joining.
        if router.current?.videoId == track.id, !router.player.hasEnded { return }
        router.play(Self.video(for: track), expand: false)
        // Paused once the stream has opened (pausing before is undone by the load),
        // so the video doesn't play from its saved spot before the room's position.
        let player = router.player
        Task {
            for _ in 0..<Self.loadPolls {
                guard awaitingBuffer?.trackId == track.id else { return }
                if player.duration > 0 {
                    player.setPaused(true)
                    return
                }
                try? await Task.sleep(for: Self.loadPollInterval)
            }
        }
    }

    private func guestTick() {
        guard let router, let waiting = awaitingBuffer, router.current?.videoId == waiting.trackId,
              !router.player.isBuffering, router.player.duration > 0 else { return }
        awaitingBuffer = nil
        connection?.send(LTMessage.bufferReady, LTBufferReady(trackId: waiting.trackId, trackRevision: waiting.revision))
    }

    // MARK: - Videos

    static func track(for video: YouTubeVideo, duration: Double = 0) -> LTTrack {
        let seconds = duration > 0 ? duration : Double(video.durationSeconds ?? 0)
        return LTTrack(
            id: video.videoId,
            title: video.title,
            artist: video.channelTitle ?? "",
            duration: Int64(seconds * 1000),
            thumbnail: video.cover
        )
    }

    static func video(for track: LTTrack) -> YouTubeVideo {
        YouTubeVideo(
            videoId: track.id,
            title: track.title,
            channelTitle: track.artist.isEmpty ? nil : track.artist,
            durationSeconds: track.duration > 0 ? Int(track.duration / 1000) : nil,
            thumbnailURL: track.thumbnail.isEmpty ? nil : track.thumbnail
        )
    }
}
