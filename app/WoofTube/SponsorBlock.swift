import CryptoKit
import SwiftUI

/// What happens when playback reaches a kind of segment. All of them stay marked on the seek bar.
enum SponsorAction: String, CaseIterable, Identifiable {
    case skip, ask, ignore

    var id: Self { self }

    var title: String {
        switch self {
        case .skip: "Auto Skip"
        case .ask: "Show Button"
        case .ignore: "Do Nothing"
        }
    }
}

/// The kinds of segment SponsorBlock's extension can skip, each with a pastel color in rainbow order.
enum SponsorCategory: String, CaseIterable, Identifiable {
    case sponsor, selfpromo, interaction, intro, outro, preview, hook, filler
    case musicOfftopic = "music_offtopic"

    var id: Self { self }

    var title: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self Promotion"
        case .interaction: "Interaction Reminder"
        case .intro: "Intermission"
        case .outro: "Credits"
        case .preview: "Preview"
        case .hook: "Hook"
        case .filler: "Tangent"
        case .musicOfftopic: "Non-Music"
        }
    }

    var detail: String {
        switch self {
        case .sponsor: "Paid promotion and advertisements."
        case .selfpromo: "Unpaid promotion, like merch or donations."
        case .interaction: "Asking to like, subscribe or follow."
        case .intro: "Intro animations and pauses without content."
        case .outro: "Credits and end cards."
        case .preview: "Clips of what's coming up, and recaps."
        case .hook: "Narrated trailers, greetings and goodbyes."
        case .filler: "Scenes and jokes the video doesn't need."
        case .musicOfftopic: "Parts of a music video without music."
        }
    }

    var color: Color {
        switch self {
        case .sponsor: Color(red: 0xFF / 255, green: 0x9A / 255, blue: 0xA2 / 255)
        case .selfpromo: Color(red: 0xFF / 255, green: 0xB8 / 255, blue: 0x77 / 255)
        case .interaction: Color(red: 0xFF / 255, green: 0xE5 / 255, blue: 0x8A / 255)
        case .intro: Color(red: 0xA8 / 255, green: 0xE6 / 255, blue: 0xA1 / 255)
        case .outro: Color(red: 0x86 / 255, green: 0xE3 / 255, blue: 0xCE / 255)
        case .preview: Color(red: 0x8F / 255, green: 0xD3 / 255, blue: 0xFF / 255)
        case .hook: Color(red: 0xA7 / 255, green: 0xB8 / 255, blue: 0xFF / 255)
        case .filler: Color(red: 0xCD / 255, green: 0xA8 / 255, blue: 0xFF / 255)
        case .musicOfftopic: Color(red: 0xFF / 255, green: 0xA8 / 255, blue: 0xE0 / 255)
        }
    }

    var defaultAction: SponsorAction {
        switch self {
        case .sponsor: .skip
        case .selfpromo, .interaction: .ask
        default: .ignore
        }
    }

    var storageKey: String { "sponsorAction.\(rawValue)" }

    var action: SponsorAction {
        UserDefaults.standard.string(forKey: storageKey).flatMap { SponsorAction(rawValue: $0) } ?? defaultAction
    }
}

struct SponsorSegment: Equatable, Identifiable {
    let id: String
    let category: SponsorCategory
    let range: ClosedRange<Double>
}

/// A colored part of a progress bar, from 0 to 1.
struct BarHighlight: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let color: Color
}

/// SponsorBlock's community list of segments. It's opt-in, and it only receives the start
/// of a code many videos share, so it answers for all of them and can't tell which one is playing.
enum SponsorBlock {
    static func segments(videoId: String) async -> [SponsorSegment] {
        let categories = SponsorCategory.allCases.map { "category=\($0.rawValue)" }.joined(separator: "&")
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments/\(hashPrefix(of: videoId))?\(categories)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return segments(in: entries, videoId: videoId)
    }

    static func hashPrefix(of videoId: String) -> String {
        SHA256.hash(data: Data(videoId.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    private static func segments(in entries: [[String: Any]], videoId: String) -> [SponsorSegment] {
        let entry = entries.first { $0["videoID"] as? String == videoId }
        let found: [SponsorSegment] = (entry?["segments"] as? [[String: Any]] ?? []).compactMap { item in
            guard let segment = item["segment"] as? [Double], segment.count == 2, segment[0] < segment[1],
                  let category = (item["category"] as? String).flatMap({ SponsorCategory(rawValue: $0) }) else { return nil }
            return SponsorSegment(id: item["UUID"] as? String ?? "\(category.rawValue)\(segment[0])", category: category, range: segment[0]...segment[1])
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func selfCheck() {
        assert(hashPrefix(of: "dQw4w9WgXcQ") == "5f6b")
        let other: [[String: Any]] = [["segment": [1.0, 2.0], "category": "sponsor"]]
        let mine: [[String: Any]] = [
            ["segment": [8.0, 9.0], "category": "music_offtopic", "UUID": "b"],
            ["segment": [3.0, 4.0], "category": "sponsor", "UUID": "a"],
            ["segment": [5.0, 5.0], "category": "sponsor"],
            ["segment": [6.0, 7.0], "category": "unknown"]
        ]
        let entries: [[String: Any]] = [["videoID": "other", "segments": other], ["videoID": "mine", "segments": mine]]
        assert(segments(in: entries, videoId: "mine").map(\.id) == ["a", "b"])
        assert(segments(in: entries, videoId: "mine").last?.category == .musicOfftopic)
        assert(segments(in: entries, videoId: "none").isEmpty)
    }
}

/// Offers to skip the segment playing now, above the seek bar. It stays while the controls are hidden.
struct SponsorSkipButton: View {
    @Environment(Router.self) private var router
    private static let barClearance: CGFloat = 72

    var body: some View {
        ZStack {
            if let segment = router.offeredSegment {
                Button {
                    router.skip(segment)
                } label: {
                    HStack(spacing: Layout.chipSpacing) {
                        Circle().fill(segment.category.color).frame(width: 8, height: 8)
                        Text("Skip \(segment.category.title)")
                            .lineLimit(1)
                        Image(systemName: "forward.end.fill").imageScale(.small)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Layout.screenPadding)
                    .frame(minHeight: 44)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity)
            }
        }
        .padding(.trailing, Layout.chipSpacing)
        .padding(.bottom, Self.barClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.2), value: router.offeredSegment)
    }
}

struct SponsorBlockSettingsView: View {
    @Environment(Router.self) private var router

    var body: some View {
        List {
            Section {
                Toggle("Use SponsorBlock", isOn: Bindable(router).usesSponsorBlock)
            } footer: {
                Text("Uses SponsorBlock's community list. It receives part of a code shared by many videos, not which one you watch.")
            }
            if router.usesSponsorBlock {
                Section {
                    ForEach(SponsorCategory.allCases) { SponsorCategoryRow(category: $0) }
                } footer: {
                    Text("Segments appear in color on the seek bar. Do Nothing only marks them.")
                }
            }
        }
        .navigationTitle("SponsorBlock")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SponsorCategoryRow: View {
    let category: SponsorCategory
    @AppStorage private var action: SponsorAction

    init(category: SponsorCategory) {
        self.category = category
        _action = AppStorage(wrappedValue: category.defaultAction, category.storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    Text(category.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Circle()
                    .fill(category.color)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.separator))
            }
            Picker(category.title, selection: $action) {
                ForEach(SponsorAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .listRowBackground(category.color.opacity(0.22))
    }
}
