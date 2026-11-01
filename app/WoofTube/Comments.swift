import SwiftUI
import SwiftyTube

struct Comment: Identifiable {
    let id: String
    let author: String
    let avatar: String?
    let text: String
    let time: String?
    let likeCount: String
    let likeCountLiked: String
    /// YouTube's own words, such as "722 replies". Past a thousand its count is "1.2K", not a number.
    let repliesLabel: String
    var isLiked: Bool
    let likeAction: String?
    let unlikeAction: String?
    let replyParams: String?
    var repliesToken: String?
    var replies: [Comment] = []
    var isLoadingReplies = false
    var isHearted = false
    var creatorAvatar: String?
    var heartLabel: String?
}

/// Comments are split across "mutations": each view model only holds keys to the
/// entities with the text, the author and the buttons' tokens.
struct CommentsPage {
    var comments: [Comment] = []
    var nextToken: String?
    var createParams: String?
    var title: String?

    init(json: [String: Any]) {
        var entities: [String: [String: Any]] = [:]
        let mutations = JSON.first("mutations", in: json["frameworkUpdates"]) as? [[String: Any]] ?? []
        for mutation in mutations {
            for value in (mutation["payload"] as? [String: Any] ?? [:]).values {
                if let entity = value as? [String: Any], let key = entity["key"] as? String {
                    entities[key] = entity
                }
            }
        }

        createParams = JSON.string("createCommentParams", in: json)
        title = JSON.text(JSON.first("countText", in: json))

        let endpoints = json["onResponseReceivedEndpoints"] as? [[String: Any]] ?? []
        for endpoint in endpoints {
            let command = (endpoint["reloadContinuationItemsCommand"] ?? endpoint["appendContinuationItemsAction"]) as? [String: Any]
            for item in command?["continuationItems"] as? [[String: Any]] ?? [] {
                if let thread = item["commentThreadRenderer"] as? [String: Any] {
                    if let comment = Self.comment(thread["commentViewModel"], repliesIn: thread["replies"], entities: entities) {
                        comments.append(comment)
                    }
                } else if item["commentViewModel"] != nil {
                    if let comment = Self.comment(item["commentViewModel"], repliesIn: nil, entities: entities) {
                        comments.append(comment)
                    }
                } else if item["continuationItemRenderer"] != nil {
                    nextToken = JSON.string("token", in: JSON.first("continuationCommand", in: item))
                }
            }
        }
    }

    private static func comment(_ viewModel: Any?, repliesIn replies: Any?, entities: [String: [String: Any]]) -> Comment? {
        guard let model = JSON.first("commentViewModel", in: viewModel) as? [String: Any] ?? viewModel as? [String: Any],
              let key = model["commentKey"] as? String,
              let entity = entities[key],
              let properties = entity["properties"] as? [String: Any] else { return nil }
        let author = entity["author"] as? [String: Any]
        let toolbar = entity["toolbar"] as? [String: Any]
        let state = (model["toolbarStateKey"] as? String).flatMap { entities[$0] }
        let surface = (model["toolbarSurfaceKey"] as? String).flatMap { entities[$0] }
        return Comment(
            id: properties["commentId"] as? String ?? key,
            author: author?["displayName"] as? String ?? "",
            avatar: author?["avatarThumbnailUrl"] as? String,
            text: JSON.text(properties["content"]) ?? "",
            time: properties["publishedTime"] as? String,
            likeCount: toolbar?["likeCountNotliked"] as? String ?? "",
            likeCountLiked: toolbar?["likeCountLiked"] as? String ?? "",
            repliesLabel: toolbar?["replyCountA11y"] as? String ?? "Replies",
            isLiked: state?["likeState"] as? String == "TOOLBAR_LIKE_STATE_LIKED",
            likeAction: JSON.string("action", in: surface?["likeCommand"]),
            unlikeAction: JSON.string("action", in: surface?["unlikeCommand"]),
            replyParams: JSON.string("createReplyParams", in: surface),
            repliesToken: JSON.string("token", in: JSON.first("continuationCommand", in: replies)),
            isHearted: state?["heartState"] as? String == "TOOLBAR_HEART_STATE_HEARTED",
            creatorAvatar: toolbar?["creatorThumbnailUrl"] as? String,
            heartLabel: toolbar?["heartActiveTooltip"] as? String
        )
    }

    static func selfCheck() {
        func thread(_ id: String) -> [String: Any] {
            let renderer: [String: Any] = [
                "commentViewModel": ["commentViewModel": ["commentKey": "c" + id, "toolbarStateKey": "s" + id]],
                "replies": ["continuationCommand": ["token": "t" + id]]
            ]
            return ["commentThreadRenderer": renderer]
        }
        func payload(_ entity: [String: Any]) -> [String: Any] { ["payload": ["entity": entity]] }
        func entities(_ id: String, heart: String) -> [[String: Any]] {
            [
                payload(["key": "c" + id, "properties": ["commentId": id], "toolbar": ["replyCountA11y": "1.2K replies", "heartActiveTooltip": "by someone"]]),
                payload(["key": "s" + id, "heartState": heart])
            ]
        }
        let page = CommentsPage(json: [
            "frameworkUpdates": ["mutations": entities("a", heart: "TOOLBAR_HEART_STATE_HEARTED") + entities("b", heart: "TOOLBAR_HEART_STATE_UNHEARTED")],
            "onResponseReceivedEndpoints": [["appendContinuationItemsAction": ["continuationItems": [thread("a"), thread("b")]]]]
        ])
        assert(page.comments.map(\.isHearted) == [true, false])
        assert(page.comments[0].repliesLabel == "1.2K replies" && page.comments[0].repliesToken == "ta")
    }
}

@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var title: String?
    @Published private(set) var isLoading = true
    @Published var errorText: String? {
        didSet {
            if let errorText { FileLog.shared.append("comments", "ERROR", errorText) }
        }
    }
    @Published private(set) var didFailLoading = false
    private(set) var createParams: String?
    private var nextToken: String?

    func load(token: String) async {
        defer { isLoading = false }
        didFailLoading = false
        isLoading = true
        do {
            let json = try await InnerTubeClient.wooftube.next(continuation: token)
            let page = await offMain { CommentsPage(json: json) }
            comments = page.comments
            title = page.title
            createParams = page.createParams
            nextToken = page.nextToken
        } catch {
            didFailLoading = true
        }
    }

    func loadMore(after comment: Comment) async {
        guard comment.id == comments.last?.id, let token = nextToken else { return }
        nextToken = nil
        guard let json = try? await InnerTubeClient.wooftube.next(continuation: token) else {
            nextToken = token
            return
        }
        let page = await offMain { CommentsPage(json: json) }
        comments += page.comments
        nextToken = page.nextToken
    }

    /// Each call adds the next page. A failure is shown, because a silent one looks like a dead button.
    func loadReplies(of comment: Comment) async {
        guard let token = comment.repliesToken, !comment.isLoadingReplies else { return }
        update(comment.id) { $0.isLoadingReplies = true }
        defer { update(comment.id) { $0.isLoadingReplies = false } }
        do {
            let json = try await InnerTubeClient.wooftube.next(continuation: token)
            let page = await offMain { CommentsPage(json: json) }
            if page.comments.isEmpty { errorText = "YouTube returned no replies for this comment." }
            update(comment.id) {
                $0.replies += page.comments
                $0.repliesToken = page.nextToken
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func toggleLike(_ comment: Comment) async {
        let target = !comment.isLiked
        guard let action = target ? comment.likeAction : comment.unlikeAction else {
            errorText = "YouTube didn't offer a like button for this comment."
            return
        }
        update(comment.id) { $0.isLiked = target }
        do {
            _ = try await YouTubeAPI.post("comment/perform_comment_action", body: ["actions": [action]])
        } catch {
            update(comment.id) { $0.isLiked = !target }
            errorText = error.localizedDescription
        }
    }

    /// Returns whether it was sent, so the composer keeps the text after a failure.
    func send(_ text: String, replyingTo parent: Comment?) async -> Bool {
        do {
            if let parent {
                guard let params = parent.replyParams else {
                    throw YouTubeAPIError(errorDescription: "YouTube didn't offer a reply button for this comment.")
                }
                _ = try await YouTubeAPI.post("comment/create_comment_reply", body: ["commentText": text, "createReplyParams": params])
                update(parent.id) { $0.replies.append(Self.ownComment(text)) }
            } else {
                guard let params = createParams else {
                    throw YouTubeAPIError(errorDescription: "Comments can't be added to this video.")
                }
                _ = try await YouTubeAPI.post("comment/create_comment", body: ["commentText": text, "createCommentParams": params])
                comments.insert(Self.ownComment(text), at: 0)
            }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func update(_ id: String, _ change: (inout Comment) -> Void) {
        for index in comments.indices {
            if comments[index].id == id {
                change(&comments[index])
                return
            }
            if let reply = comments[index].replies.firstIndex(where: { $0.id == id }) {
                change(&comments[index].replies[reply])
                return
            }
        }
    }

    private static func ownComment(_ text: String) -> Comment {
        Comment(id: UUID().uuidString, author: "You", avatar: nil, text: text, time: "Just now", likeCount: "", likeCountLiked: "", repliesLabel: "", isLiked: false, likeAction: nil, unlikeAction: nil, replyParams: nil, repliesToken: nil)
    }
}

struct CommentsSheet: View {
    let token: String

    @StateObject private var model = CommentsModel()
    @State private var draft = ""
    @State private var replyingTo: Comment?
    @State private var isSending = false
    @FocusState private var isComposing: Bool

    private static let replyInsets = EdgeInsets(top: Layout.rowPadding, leading: Layout.screenPadding + 44, bottom: Layout.rowPadding, trailing: Layout.screenPadding)

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.comments) { comment in
                    CommentRow(comment: comment, model: model) { reply(to: $0) }
                        .listRowInsets(Layout.rowInsets)
                        .task { await model.loadMore(after: comment) }
                    ForEach(comment.replies) { child in
                        CommentRow(comment: child, model: model) { reply(to: $0) }
                            .listRowInsets(Self.replyInsets)
                    }
                    if !comment.replies.isEmpty, comment.repliesToken != nil {
                        Button {
                            Task { await model.loadReplies(of: comment) }
                        } label: {
                            Group {
                                if comment.isLoadingReplies {
                                    ProgressView()
                                } else {
                                    Text("Show More Replies")
                                }
                            }
                            .font(.footnote.weight(.medium))
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .listRowInsets(Self.replyInsets)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.comments.isEmpty {
                    if model.isLoading {
                        LoadingTextRows()
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, Layout.rowSpacing)
                    } else if model.didFailLoading {
                        ContentUnavailableView {
                            Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                        } actions: {
                            Button("Try Again") { Task { await model.load(token: token) } }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ContentUnavailableView("No Comments", systemImage: "bubble.left")
                    }
                }
            }
            .navigationTitle(model.title ?? "Comments")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { composer }
            .alert("That Didn't Work", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorText ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await model.load(token: token) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            if let replyingTo {
                HStack(spacing: Layout.chipSpacing) {
                    Text("Replying to \(replyingTo.author)")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel Reply", systemImage: "xmark.circle.fill") { self.replyingTo = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .padding(.leading, Layout.screenPadding)
                .background(.regularMaterial, in: .capsule)
            }
            HStack(alignment: .bottom, spacing: Layout.chipSpacing) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isComposing)
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                Button("Send", systemImage: "arrow.up") {
                    Task { await send() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
    }

    private func reply(to comment: Comment) {
        replyingTo = comment
        isComposing = true
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if await model.send(text, replyingTo: replyingTo) {
            draft = ""
            replyingTo = nil
            isComposing = false
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    @ObservedObject var model: CommentsModel
    let onReply: (Comment) -> Void

    private static let heartAvatarSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: Layout.rowSpacing) {
            Avatar(url: comment.avatar, size: Layout.avatarSmall)
            VStack(alignment: .leading, spacing: Layout.rowPadding) {
                Text([comment.author, comment.time].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(comment.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    Button {
                        Task { await model.toggleLike(comment) }
                    } label: {
                        Label {
                            Text(comment.isLiked ? comment.likeCountLiked : comment.likeCount)
                        } icon: {
                            Image(systemName: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .glyphMotion(comment.isLiked ? .pop : .deflate, trigger: comment.isLiked)
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .accessibilityLabel("Like")
                    .accessibilityValue(comment.isLiked ? comment.likeCountLiked : comment.likeCount)
                    .accessibilityAddTraits(comment.isLiked ? .isSelected : [])
                    if comment.replyParams != nil {
                        Button {
                            onReply(comment)
                        } label: {
                            Text("Reply").frame(minHeight: 44).contentShape(.rect)
                        }
                    }
                    if comment.repliesToken != nil, comment.replies.isEmpty {
                        Button {
                            Task { await model.loadReplies(of: comment) }
                        } label: {
                            Group {
                                if comment.isLoadingReplies {
                                    ProgressView()
                                } else {
                                    Text(comment.repliesLabel)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                    }
                    if comment.isHearted {
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(url: comment.creatorAvatar, size: Self.heartAvatarSize)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .offset(x: 3, y: 3)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(comment.heartLabel ?? "Hearted by the creator")
                    }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .sensoryFeedback(.impact(weight: .light), trigger: comment.isLiked)
            }
        }
        .listRowSeparator(.hidden)
    }
}
