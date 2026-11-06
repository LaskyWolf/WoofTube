import SwiftUI

/// Start or join a Watch Together room, and run it: who is in, who wants in,
/// what guests suggest.
struct WatchTogetherView: View {
    @Environment(Router.self) private var router
    @EnvironmentObject private var session: Session
    @AppStorage(WatchTogether.usernameKey) private var username = ""
    @AppStorage(WatchTogether.serverKey) private var serverURL = WatchTogether.defaultServerURL
    @State private var code = ""
    private let room = WatchTogether.shared

    var body: some View {
        List {
            if let notice = room.notice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            switch room.status {
            case .idle:
                startSections
            case .connecting, .waitingForApproval:
                waitingSection
            case .inRoom, .reconnecting:
                roomSections
            }
        }
        .navigationTitle("Watch Together")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: room.status)
        .animation(.default, value: room.users)
        .animation(.default, value: room.joinRequests)
        .onAppear { room.attach(router) }
    }

    /// The signed-in account's name; nil for a guest session.
    private var accountName: String? {
        session.currentAccountId == nil ? nil : session.account?.name
    }

    // MARK: - Not in a room

    @ViewBuilder
    private var startSections: some View {
        Section {
            TextField("Your name", text: $username, prompt: Text(accountName ?? WatchTogether.fallbackName))
                .textContentType(.nickname)
        } header: {
            Text("Name")
        } footer: {
            Text("Everyone in the room sees it.")
        }

        Section {
            Button("Start a Room", systemImage: "person.2.wave.2") { room.createRoom(accountName: accountName) }
        } footer: {
            Text("You control the video. Share the room code; you let each person in.")
        }

        Section {
            TextField("Room code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit(join)
            Button("Join Room", systemImage: "arrow.right.circle", action: join)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Join")
        } footer: {
            Text("The host's video plays on your phone, in step with theirs.")
        }

        Section {
            TextField("Server", text: $serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            if serverURL != WatchTogether.defaultServerURL {
                Button("Use Metrolist's Server") { serverURL = WatchTogether.defaultServerURL }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Rooms are shared with Woof Music and Metrolist on the same server.")
        }
    }

    private func join() {
        room.joinRoom(code: code, accountName: accountName)
    }

    private var waitingSection: some View {
        Section {
            HStack(spacing: Layout.rowSpacing) {
                ProgressView()
                Text(room.status == .connecting ? "Connecting…" : "Waiting for the host to let you in…")
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { room.leave() }
        }
    }

    // MARK: - In a room

    @ViewBuilder
    private var roomSections: some View {
        Section {
            VStack(alignment: .leading, spacing: Layout.rowPadding) {
                Text(room.isHost ? "You're the host" : "Watching along")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(room.roomCode ?? "")
                    .font(.largeTitle.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                if room.status == .reconnecting {
                    Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, Layout.cardSpacing)
            if let code = room.roomCode {
                ShareLink(item: "Watch with me on WoofTube. Room code: \(code)") {
                    Label("Share Room Code", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            if room.isGuest {
                Text("The host controls the video. Suggest videos from any video's menu.")
            }
        }

        if room.isHost, !room.joinRequests.isEmpty {
            Section("Wants to Join") {
                ForEach(room.joinRequests) { request in
                    let name = WatchTogether.displayName(request.username)
                    HStack {
                        Label {
                            Text(name)
                        } icon: {
                            MemberPicture(name: name, url: nil)
                        }
                        Spacer()
                        RoundAction(title: "Decline", icon: "xmark", tint: .red) { room.reject(request) }
                        RoundAction(title: "Let In", icon: "checkmark", isProminent: true) { room.approve(request) }
                    }
                }
            }
        }

        if room.isHost, !room.suggestions.isEmpty {
            Section("Suggestions") {
                ForEach(room.suggestions) { suggestion in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.track.title)
                                .lineLimit(2)
                            Text("\(suggestion.track.artist) · from \(WatchTogether.displayName(suggestion.fromUsername))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        RoundAction(title: "Skip", icon: "xmark") { room.reject(suggestion) }
                        RoundAction(title: "Play Next", icon: "text.insert", isProminent: true) { room.approve(suggestion) }
                    }
                }
            }
        }

        Section("In the Room") {
            ForEach(room.users) { user in
                let name = WatchTogether.displayName(user.username)
                let isMe = user.userId == room.myUserId
                HStack {
                    Label {
                        Text(isMe ? "\(name) (you)" : name)
                    } icon: {
                        MemberPicture(name: name, url: isMe ? session.account?.thumbnailUrl : nil)
                            .overlay(alignment: .bottomTrailing) {
                                if user.isHost {
                                    Image(systemName: "crown.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.yellow)
                                        .padding(3)
                                        .background(Color(.secondarySystemGroupedBackground), in: .circle)
                                        .offset(x: 5, y: 4)
                                        .accessibilityLabel("Host")
                                }
                            }
                    }
                    Spacer()
                    if !user.isConnected {
                        Text("Away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if room.isHost, !isMe {
                        Button("Make Host", systemImage: "crown") { room.makeHost(user) }
                        Button("Remove", systemImage: "person.fill.xmark", role: .destructive) { room.kick(user) }
                    }
                }
            }
        }

        Section {
            Button("Leave Room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                room.leave()
            }
        }
    }
}

/// Watch Together in its own stack, for opening from the player's menu.
struct WatchTogetherSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WatchTogetherView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

/// An icon button with a 44 pt target that grows with the text size.
private struct RoundAction: View {
    let title: String
    let icon: String
    var tint: Color?
    var isProminent = false
    let action: () -> Void
    @ScaledMetric private var size: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(isProminent ? AnyShapeStyle(Color.white) : (tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)))
                .frame(width: size, height: size)
                .background(isProminent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .circle)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}

/// The account's picture for this phone, else the member's initial on a colour of their own.
private struct MemberPicture: View {
    let name: String
    let url: String?
    @ScaledMetric private var size: CGFloat = 30

    var body: some View {
        Group {
            if let url {
                CachedImage(url: url, maxPixels: Int(size * 3))
            } else {
                Circle()
                    .fill(color.gradient)
                    .overlay {
                        Text(String(name.first ?? "?").uppercased())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private static let colors: [Color] = [.orange, .pink, .purple, .indigo, .teal, .green, .brown]

    /// The same colour for a name on every launch (`hashValue` changes per launch).
    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.colors[sum % Self.colors.count]
    }
}
