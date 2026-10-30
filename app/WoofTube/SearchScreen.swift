import SwiftUI
import SwiftyTube

struct SearchScreen: View {
    @State private var text = ""
    @State private var hints: [String] = []
    @State private var submitted: String?

    var body: some View {
        NavigationStack {
            Group {
                if let submitted {
                    FeedList(source: .search(submitted))
                        .id(submitted)
                } else {
                    ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass")
                }
            }
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "Videos and channels")
            .searchSuggestions {
                ForEach(hints, id: \.self) { hint in
                    Label(hint, systemImage: "magnifyingglass")
                        .searchCompletion(hint)
                }
            }
            .onSubmit(of: .search) { submitted = text }
            .task(id: text) {
                // Waits for a pause in typing, because each change cancels this task.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, !text.isEmpty else { return }
                hints = (try? await SearchSuggestions.suggest(query: text)) ?? []
            }
        }
    }
}

struct NotificationsView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let message: String
        let time: String?
        let thumbnail: String?
        let videoId: String?
    }

    @EnvironmentObject private var router: Router
    @State private var items: [Item] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        List(items) { item in
            Button {
                if let id = item.videoId {
                    router.play(YouTubeVideo(videoId: id, title: item.message))
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.message).font(.subheadline)
                        if let time = item.time {
                            Text(time).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    AsyncImage(url: item.thumbnail.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.secondarySystemFill)
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
            .buttonStyle(.plain)
            .disabled(item.videoId == nil)
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No Notifications", systemImage: "bell")
                    } description: {
                        if let errorText { Text(errorText) }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            let json = try await YouTubeAPI.post(
                "notification/get_notification_menu",
                body: ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"]
            )
            items = Self.renderers(in: json).map { renderer in
                Item(
                    message: JSON.text(renderer["shortMessage"]) ?? "",
                    time: JSON.text(renderer["sentTimeText"]),
                    thumbnail: JSON.lastThumbnail(renderer["videoThumbnail"]),
                    videoId: JSON.string("videoId", in: renderer["navigationEndpoint"])
                )
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func renderers(in object: Any?) -> [[String: Any]] {
        if let dict = object as? [String: Any] {
            if let renderer = dict["notificationRenderer"] as? [String: Any] { return [renderer] }
            return dict.values.flatMap { renderers(in: $0) }
        }
        if let array = object as? [Any] {
            return array.flatMap { renderers(in: $0) }
        }
        return []
    }
}
