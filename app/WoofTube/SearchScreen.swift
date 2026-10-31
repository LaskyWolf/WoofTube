import SwiftUI
import SwiftyTube

enum SearchSettings {
    static let tracksHistoryKey = "search.tracksHistory"
    static let incognitoKey = "search.incognito"

    /// While on, nothing the person searches or watches is kept.
    static var isIncognito: Bool { UserDefaults.standard.bool(forKey: incognitoKey) }
    static var tracksHistory: Bool { UserDefaults.standard.object(forKey: tracksHistoryKey) as? Bool ?? true }
}

/// YouTube's own suggestions, the job Woof Music gives to YouTube Music's. They need no account.
enum YouTubeSuggestions {
    static func fetch(_ query: String) async throws -> [String] {
        var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "oe", value: "utf8"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "gl", value: Locale.current.region?.identifier ?? "US")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The answer is `window.google.ac.h(["query",[["suggestion",0,[…]],…],…])`.
    static func parse(_ answer: String) -> [String] {
        guard let open = answer.firstIndex(of: "("), let close = answer.lastIndex(of: ")"), open < close,
              let root = try? JSONSerialization.jsonObject(with: Data(answer[answer.index(after: open)..<close].utf8)) as? [Any],
              root.count > 1, let entries = root[1] as? [[Any]] else { return [] }
        return entries.compactMap { $0.first as? String }
    }

    static func selfCheck() {
        assert(parse(#"window.google.ac.h(["mr",[["mrbeast",0,[512]],["mr bean (old)",0]],{"a":1}])"#) == ["mrbeast", "mr bean (old)"])
        assert(parse("<html>").isEmpty)
    }
}

/// Woof Music's recent searches. Each account keeps its own.
@MainActor
final class SearchHistory: ObservableObject {
    private static let key = "search.history"
    private static let maxEntries = 20
    private static let maxMatches = 3

    @Published private(set) var entries: [String]

    init() {
        CreatorMatch.selfCheck()
        YouTubeSuggestions.selfCheck()
        entries = ProfileStorage.defaults.stringArray(forKey: Self.key) ?? []
    }

    func add(_ query: String) {
        guard SearchSettings.tracksHistory, !SearchSettings.isIncognito else { return }
        entries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        entries.insert(query, at: 0)
        entries = Array(entries.prefix(Self.maxEntries))
        save()
    }

    func delete(_ query: String) {
        entries.removeAll { $0 == query }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func matching(_ text: String) -> [String] {
        Array(entries.filter { $0.localizedStandardContains(text) }.prefix(Self.maxMatches))
    }

    private func save() {
        ProfileStorage.defaults.set(entries, forKey: Self.key)
    }
}

/// Decides whether a channel is what the search asked for. It ignores case, accents and
/// spaces, and allows a small typo. YouTube's own search handles typos in the results.
enum CreatorMatch {
    private static let shortestFuzzyName = 5

    static func matches(query: String, name: String) -> Bool {
        let query = normalized(query)
        let name = normalized(name)
        guard !query.isEmpty, !name.isEmpty else { return false }
        if name.contains(query) { return query.count * 2 >= name.count }
        if query.contains(name) { return name.count >= 3 }
        return name.count >= shortestFuzzyName && distance(query, name) <= name.count / 3
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// How many letters to add, remove or change to turn one word into the other.
    private static func distance(_ first: String, _ second: String) -> Int {
        let second = Array(second)
        var row = Array(0...second.count)
        for (index, letter) in first.enumerated() {
            var previous = row[0]
            row[0] = index + 1
            for column in second.indices {
                let replaced = previous + (letter == second[column] ? 0 : 1)
                previous = row[column + 1]
                row[column + 1] = min(replaced, previous + 1, row[column] + 1)
            }
        }
        return row[second.count]
    }

    static func selfCheck() {
        assert(matches(query: "mr beast", name: "MrBeast"))
        assert(matches(query: "mrbaest", name: "MrBeast"))
        assert(matches(query: "mrbeast new video", name: "MrBeast"))
        assert(matches(query: "beyonce", name: "Beyoncé"))
        assert(!matches(query: "cat", name: "Catfish and the Bottlemen"))
        assert(!matches(query: "how to cook", name: "Gordon Ramsay"))
    }
}

struct SearchScreen: View {
    @StateObject private var history = SearchHistory()
    @AppStorage(SearchSettings.incognitoKey) private var isIncognito = false
    @State private var text = ""
    @State private var submitted: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let submitted, submitted == text {
                    SearchResults(query: submitted)
                        .id(submitted)
                } else {
                    SearchStart(text: text, history: history, isIncognito: isIncognito) { submit($0) }
                }
            }
            .tabRoot(title: "Search", tab: .search, incognito: $isIncognito)
        }
        .searchable(text: $text, prompt: "Videos and channels")
        .searchFocused($isFieldFocused)
        .onSubmit(of: .search) { submit(text) }
    }

    private func submit(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        text = query
        submitted = query
        history.add(query)
        isFieldFocused = false
    }
}

/// Recent searches with an empty field, then matching ones and YouTube's suggestions while typing.
private struct SearchStart: View {
    let text: String
    @ObservedObject var history: SearchHistory
    let isIncognito: Bool
    let onSubmit: (String) -> Void
    @State private var hints: [String] = []

    private static let historyIcon = "clock.arrow.trianglehead.counterclockwise.rotate.90"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isIncognito {
                    Label("Incognito is on. Searches and watch progress aren't saved, and videos stay out of your YouTube history.", systemImage: "eyeglasses")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.chipSpacing)
                }
                if text.isEmpty {
                    recents
                } else {
                    suggestions
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: text) {
            // Waits for a pause in typing, because each change cancels this task.
            guard !text.isEmpty else {
                hints = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hints = (try? await YouTubeSuggestions.fetch(text)) ?? []
        }
    }

    @ViewBuilder
    private var recents: some View {
        if !SearchSettings.tracksHistory || history.entries.isEmpty {
            ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass")
                .padding(.vertical, 48)
        } else {
            HStack {
                Text("Recently searched").font(.headline)
                Spacer()
                Button("Clear") { history.clear() }
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, Layout.screenPadding)
            ForEach(history.entries, id: \.self) { historyRow($0) }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let matches = SearchSettings.tracksHistory ? history.matching(text) : []
        ForEach(matches, id: \.self) { historyRow($0) }
        ForEach(hints.filter { !matches.contains($0) }, id: \.self) { hint in
            queryRow(hint, systemImage: "magnifyingglass", iconStyle: .secondary)
        }
    }

    private func historyRow(_ query: String) -> some View {
        queryRow(query, systemImage: Self.historyIcon, iconStyle: .tint)
            .overlay(alignment: .trailing) {
                Button("Remove from History", systemImage: "xmark") { history.delete(query) }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .padding(.trailing, Layout.chipSpacing)
            }
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) { history.delete(query) }
            }
    }

    private func queryRow(_ query: String, systemImage: String, iconStyle: some ShapeStyle) -> some View {
        Button {
            onSubmit(query)
        } label: {
            HStack(spacing: Layout.rowSpacing) {
                Image(systemName: systemImage).foregroundStyle(iconStyle)
                Text(query)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // Room for the remove button.
                Spacer(minLength: 44)
            }
            .padding(.horizontal, Layout.screenPadding)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Woof Music's results: filters, the creator when the search names one, then everything else.
private struct SearchResults: View {
    private enum Filter: String, CaseIterable {
        case videos = "Videos"
        case shorts = "Shorts"
        case channels = "Channels"
        case playlists = "Playlists"
        case history = "My History"

        /// The codes youtube.com puts in its search filter links.
        var params: String? {
            switch self {
            case .videos: return "EgIQAQ%3D%3D"
            case .shorts: return "EgIQCQ%3D%3D"
            case .channels: return "EgIQAg%3D%3D"
            case .playlists: return "EgIQAw%3D%3D"
            case .history: return nil
            }
        }
    }

    let query: String
    @EnvironmentObject private var router: Router
    @StateObject private var model = FeedModel()
    @State private var filter: Filter?
    @State private var creator: YouTubeChannel?

    var body: some View {
        FeedContent(model: model, retry: { await load() }, isCompact: filter == .history) {
            FilterChips(titles: Filter.allCases.map(\.rawValue), selected: filter?.rawValue) { title in
                let tapped = Filter(rawValue: title)
                filter = filter == tapped ? nil : tapped
            }
            if let creator, let id = creator.channelId {
                creatorCard(creator, id: id)
            }
        }
        .task(id: filter) { await load() }
    }

    private func load() async {
        if filter == .history {
            await model.load(.scoped(browseId: YouTubeFeeds.history, query: query))
        } else {
            await model.load(.search(query, params: filter?.params))
        }
        guard filter == nil else {
            creator = nil
            return
        }
        let found = await findCreator()
        guard !Task.isCancelled else { return }
        creator = found
        if let found { model.remove(.channel(found)) }
    }

    /// YouTube doesn't always put the channel on the first page, so this also asks for channels.
    private func findCreator() async -> YouTubeChannel? {
        if let found = firstMatch(in: model.items) { return found }
        guard let json = try? await FeedSource.search(query, params: Filter.channels.params).fetch() else { return nil }
        return firstMatch(in: FeedParser.items(in: json))
    }

    private func firstMatch(in items: [FeedItem]) -> YouTubeChannel? {
        for case .channel(let channel) in items where channel.channelId != nil {
            if CreatorMatch.matches(query: query, name: channel.title)
                || CreatorMatch.matches(query: query, name: channel.handle ?? "") {
                return channel
            }
        }
        return nil
    }

    private func creatorCard(_ channel: YouTubeChannel, id: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        return Button {
            router.openChannelPage(id)
        } label: {
            HStack(spacing: 14) {
                Avatar(url: channel.thumbnailURL, size: Layout.avatarSmall)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Channel")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(channel.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail = channel.subscriberCountText ?? channel.handle {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Layout.screenPadding)
            .padding(.vertical, Layout.rowSpacing)
            .background(shape.fill(Color(.systemGray6)))
            .contentShape(shape)
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
    }
}
