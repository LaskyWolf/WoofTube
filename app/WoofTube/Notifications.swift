import SwiftUI
import SwiftyTube

private struct NotificationItem: Identifiable {
    let id: String
    let name: String?
    let message: String
    let videoTitle: String
    let time: String?
    let avatar: String?
    let thumbnail: String?
    let videoId: String?
    let clickRequest: String?
    var isRead: Bool

    init(renderer: [String: Any], seen: Set<String>) {
        let full = JSON.text(renderer["shortMessage"]) ?? ""
        // "Name uploaded: Title" becomes the name on its own line, as in YouTube's app.
        if let range = full.range(of: " uploaded: ") ?? full.range(of: " ha caricato: ") {
            name = String(full[..<range.lowerBound])
            videoTitle = String(full[range.upperBound...])
            message = "Uploaded: " + videoTitle
        } else {
            name = nil
            videoTitle = full
            message = full
        }
        id = renderer["notificationId"] as? String ?? UUID().uuidString
        time = JSON.text(renderer["sentTimeText"])
        avatar = JSON.lastThumbnail(renderer["thumbnail"])
        thumbnail = JSON.lastThumbnail(renderer["videoThumbnail"])
        videoId = JSON.string("videoId", in: renderer["navigationEndpoint"])
        clickRequest = JSON.string("serializedInteractionsRequest", in: renderer["recordClickEndpoint"])
        isRead = renderer["read"] as? Bool ?? false || seen.contains(id)
    }
}

private struct NotificationSection: Identifiable {
    let title: String
    var items: [NotificationItem]
    var id: String { title }
}

/// YouTube's `read` only follows clicks, so rows seen on the page are remembered here, per account.
private enum SeenNotifications {
    private static let key = "seenNotifications"
    private static let limit = 500

    static var all: Set<String> {
        Set(ProfileStorage.defaults.stringArray(forKey: key) ?? [])
    }

    static func add(_ ids: Set<String>) {
        guard !ids.isEmpty, !SearchSettings.isIncognito else { return }
        let saved = ProfileStorage.defaults.stringArray(forKey: key) ?? []
        let updated = saved.filter { !ids.contains($0) } + ids
        ProfileStorage.defaults.set(Array(updated.suffix(limit)), forKey: key)
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var session: Session
    @Environment(Router.self) private var router
    @State private var sections: [NotificationSection] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var seenOnPage: Set<String> = []

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        NotificationRow(item: item) {
                            markRead([item.id])
                            open(item)
                        }
                        .onAppear {
                            if !item.isRead { seenOnPage.insert(item.id) }
                        }
                        .listRowInsets(EdgeInsets(top: Layout.rowPadding, leading: Layout.screenPadding, bottom: Layout.rowPadding, trailing: Layout.screenPadding))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if sections.isEmpty {
                if isLoading {
                    LoadingTextRows(showsThumbnail: true)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, Layout.rowSpacing)
                } else {
                    ContentUnavailableView {
                        if errorText != nil {
                            Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                        } else {
                            Label("No Notifications", systemImage: "bell")
                        }
                    } description: {
                        if let errorText { Text(errorText) }
                    } actions: {
                        Button("Try Again") {
                            isLoading = true
                            Task { await load() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            session.unseenNotifications = 0
            await load()
        }
        .refreshable { await load() }
        .onDisappear {
            SeenNotifications.add(seenOnPage)
            markRead(seenOnPage)
            seenOnPage = []
        }
    }

    /// By ID, because a refresh can replace the list while a row still holds its place in it.
    private func markRead(_ ids: Set<String>) {
        for section in sections.indices {
            for row in sections[section].items.indices where ids.contains(sections[section].items[row].id) {
                sections[section].items[row].isRead = true
            }
        }
    }

    private func open(_ item: NotificationItem) {
        if let request = item.clickRequest {
            Task {
                _ = try? await YouTubeAPI.post("notification/record_interactions", body: ["serializedRecordNotificationInteractionsRequests": [request]])
            }
        }
        if let id = item.videoId {
            router.openVideo(YouTubeVideo(videoId: id, title: item.videoTitle, thumbnailURL: item.thumbnail))
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            let json = try await YouTubeAPI.post(
                "notification/get_notification_menu",
                body: ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"]
            )
            sections = Self.sections(in: json)
            errorText = nil
        } catch {
            // Leaving the page cancels the request, which says nothing about the notifications.
            if (error as? URLError)?.code != .cancelled, !(error is CancellationError) {
                errorText = error.localizedDescription
            }
        }
    }

    /// Keeps YouTube's own section titles. Items it leaves untitled are grouped by age.
    private static func sections(in json: [String: Any]) -> [NotificationSection] {
        var result: [NotificationSection] = []
        let seen = SeenNotifications.all
        func add(_ item: NotificationItem, to title: String) {
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].items.append(item)
            } else {
                result.append(NotificationSection(title: title, items: [item]))
            }
        }
        for section in nodes("multiPageMenuNotificationSectionRenderer", in: json) {
            let title = JSON.text(section["notificationSectionTitle"]) ?? JSON.text(section["title"])
            for renderer in nodes("notificationRenderer", in: section["items"]) {
                let item = NotificationItem(renderer: renderer, seen: seen)
                add(item, to: title ?? ageTitle(item.time))
            }
        }
        if result.isEmpty {
            for renderer in nodes("notificationRenderer", in: json) {
                let item = NotificationItem(renderer: renderer, seen: seen)
                add(item, to: ageTitle(item.time))
            }
        }
        return result
    }

    private static func ageTitle(_ time: String?) -> String {
        let words = Set((time ?? "").lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["second", "seconds", "minute", "minutes", "hour", "hours", "secondo", "secondi", "minuto", "minuti", "ora", "ore"]) { return "Today" }
        if !words.isDisjoint(with: ["day", "days", "giorno", "giorni"]) { return "This Week" }
        return "Older"
    }

    private static func nodes(_ key: String, in object: Any?) -> [[String: Any]] {
        if let dict = object as? [String: Any] {
            if let node = dict[key] as? [String: Any] { return [node] }
            return dict.values.flatMap { nodes(key, in: $0) }
        }
        if let array = object as? [Any] {
            return array.flatMap { nodes(key, in: $0) }
        }
        return []
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let onOpen: () -> Void
    @Environment(Router.self) private var router
    @State private var showsPlaylists = false

    var body: some View {
        Button(action: onOpen) {
            // The History page's row: the cover, the channel's picture on its edge, then the text.
            HStack(spacing: Layout.rowSpacing) {
                if let thumbnail = item.thumbnail, let id = item.videoId {
                    Thumbnail(url: thumbnail, videoId: id, maxPixels: 400)
                        .frame(width: Layout.videoSmall)
                        .fadesAtTrailing()
                        .deArrowMark(id, size: 16)
                        .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
                }
                avatar
                    .padding(.trailing, item.thumbnail == nil ? 0 : -Layout.rowSpacing / 2)
                VStack(alignment: .leading, spacing: 2) {
                    if let name = item.name {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(item.message)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let time = item.time {
                        Text(time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
        .liftedMenu {
            if let id = item.videoId {
                VideoMenuItems(video: YouTubeVideo(videoId: id, title: item.videoTitle), router: router, showsPlaylists: $showsPlaylists)
            }
        }
        .sheet(isPresented: $showsPlaylists) {
            if let id = item.videoId {
                PlaylistPickerSheet(video: YouTubeVideo(videoId: id, title: item.videoTitle))
            }
        }
    }

    /// On the cover's edge when there is a cover, with the dot of a new notification.
    private var avatar: some View {
        let onCover = item.thumbnail != nil
        return Avatar(url: item.avatar, size: RowAvatar.size)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: onCover ? 2.5 : 0))
            .overlay(alignment: .topLeading) {
                if !item.isRead {
                    Circle()
                        .fill(.tint)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: -2, y: -2)
                        .accessibilityLabel("New")
                }
            }
            .frame(height: onCover ? RowAvatar.coverHeight : nil, alignment: .top)
            .padding(.leading, onCover ? -RowAvatar.overlap : 0)
    }
}
