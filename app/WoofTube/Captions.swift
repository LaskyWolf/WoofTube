import SwiftUI
import SwiftyTube

struct CaptionCue {
    let start: Double
    let end: Double
    let text: String
}

enum CaptionLoader {
    /// YouTube's json3 format lists events with a start, a duration and text segments.
    static func cues(for track: YouTubeCaptionTrack) async throws -> [CaptionCue] {
        guard let base = track.baseURL, var components = URLComponents(string: base) else { return [] }
        // Some clients' addresses already ask for another format, and YouTube obeys the first one.
        var query = (components.percentEncodedQueryItems ?? []).filter { $0.name != "fmt" }
        query.append(URLQueryItem(name: "fmt", value: "json3"))
        components.percentEncodedQueryItems = query
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let events = json?["events"] as? [[String: Any]] ?? []
        return events.compactMap { event in
            guard let start = event["tStartMs"] as? Double,
                  let segments = event["segs"] as? [[String: Any]] else { return nil }
            let text = segments.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let duration = event["dDurationMs"] as? Double ?? 0
            return CaptionCue(start: start / 1000, end: (start + duration) / 1000, text: text)
        }
    }
}

/// Drawn by SwiftUI rather than mpv, because mpv's subtitle renderer has no fonts on iOS.
struct CaptionOverlay: View {
    @ObservedObject var clock: PlayerClock
    let cues: [CaptionCue]
    let isFullscreen: Bool

    var body: some View {
        if let cue = cues.last(where: { $0.start <= clock.time && clock.time < $0.end }) {
            Text(cue.text)
                .font(isFullscreen ? .title3.weight(.medium) : .footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.chipSpacing)
                .padding(.vertical, Layout.cardSpacing)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: Layout.cardSpacing))
                .padding(.horizontal, Layout.screenPadding)
                .padding(.bottom, isFullscreen ? 28 : Layout.rowSpacing)
                .allowsHitTesting(false)
        }
    }
}
