import SwiftUI

/// Reads a live stream's chat. YouTube says how long to wait before asking again.
@MainActor
final class LiveChatModel: ObservableObject {
    struct Message: Identifiable {
        let id: String
        let author: String
        let text: String
        let avatar: String?
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var status: String? = "Connecting…"
    private static let limit = 200
    private static let shortestWait = 1000

    func run(token start: String) async {
        var token = start
        while !Task.isCancelled {
            do {
                let json = try await YouTubeAPI.post("live_chat/get_live_chat", body: ["continuation": token])
                guard let chat = JSON.first("liveChatContinuation", in: json) as? [String: Any],
                      let next = (chat["continuations"] as? [[String: Any]])?.first?.values.first as? [String: Any],
                      let nextToken = next["continuation"] as? String else {
                    status = "The chat has ended."
                    return
                }
                add(chat["actions"] as? [[String: Any]] ?? [])
                status = nil
                token = nextToken
                let wait = max(next["timeoutMs"] as? Int ?? Self.shortestWait, Self.shortestWait)
                try? await Task.sleep(for: .milliseconds(wait))
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
                return
            }
        }
    }

    private func add(_ actions: [[String: Any]]) {
        let known = Set(messages.map(\.id))
        let added = actions.compactMap { action -> Message? in
            guard let item = (action["addChatItemAction"] as? [String: Any])?["item"] as? [String: Any],
                  let renderer = (item["liveChatTextMessageRenderer"] ?? item["liveChatPaidMessageRenderer"]) as? [String: Any],
                  let id = renderer["id"] as? String, !known.contains(id),
                  let text = JSON.text(renderer["message"]), !text.isEmpty else { return nil }
            return Message(id: id, author: JSON.text(renderer["authorName"]) ?? "", text: text, avatar: JSON.lastThumbnail(renderer["authorPhoto"]))
        }
        messages = Array((messages + added).suffix(Self.limit))
    }
}

struct LiveChatSheet: View {
    let token: String
    @StateObject private var model = LiveChatModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(model.messages) { message in
                        HStack(alignment: .top, spacing: Layout.chipSpacing) {
                            CachedImage(url: message.avatar, maxPixels: 96)
                                .frame(width: 28, height: 28)
                                .clipShape(.circle)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.author)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(message.text)
                                    .font(.subheadline)
                            }
                        }
                    }
                    if let status = model.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.screenPadding)
            }
            .defaultScrollAnchor(.bottom)
            .navigationTitle("Live Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await model.run(token: token) }
    }
}
