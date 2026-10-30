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
