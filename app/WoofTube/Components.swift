import SwiftUI
import SwiftyTube

/// Woof Music's ZoomPressStyle: stays shrunk briefly, so a quick tap still shows it.
struct ZoomPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        ZoomPressLabel(configuration: configuration, scale: scale)
    }
}

private struct ZoomPressLabel: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @State private var zoomed = false

    var body: some View {
        configuration.label
            .scaleEffect(zoomed ? scale : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: zoomed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    zoomed = true
                } else {
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        if !configuration.isPressed { zoomed = false }
                    }
                }
            }
    }
}

/// Woof Music's header button face. `primary` fills it and makes it larger.
struct HeaderRoundIcon: View {
    let systemImage: String
    var primary: Color?
    var tint: Color = .primary

    private var size: CGFloat { primary == nil ? 38 : 50 }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: primary == nil ? 15 : 19, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(primary == nil ? tint : .white)
            .frame(width: size, height: size)
            .glassEffect(primary.map { Glass.regular.tint($0) } ?? .regular, in: .circle)
            // Reaches 44 pt, using the gap between neighbouring buttons.
            .contentShape(Circle().inset(by: primary == nil ? -3 : 0))
    }
}

/// Woof Music's header for the channel and playlist pages: a large cover on the left,
/// then the kind, title, secondary line and round buttons on the right.
struct DetailHeaderCard<Cover: View, Secondary: View, Buttons: View>: View {
    let meta: String
    let title: String
    var artSize = Layout.artLarge
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var secondary: () -> Secondary
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            cover()
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                secondary()
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    buttons()
                }
                .buttonStyle(ZoomPressStyle(scale: 0.92))
            }
            .frame(maxWidth: .infinity, minHeight: artSize, alignment: .leading)
        }
        .padding(.horizontal, Layout.screenPadding)
    }
}

/// Woof Music's blurred artwork that fades into the page behind a header.
struct BlurredArtworkBackdrop: View {
    let url: String?
    private static let height: CGFloat = 400
    /// Reaches under the navigation bar and fills the pull-down overscroll.
    private static let overflow: CGFloat = 300

    var body: some View {
        CoverImage(url: url)
            .frame(height: Self.height + Self.overflow)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 40, opaque: true)
            .opacity(0.7)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .padding(.top, -Self.overflow)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A channel's banner, sharp at the top of the page and fading into what's below.
struct ChannelBanner: View {
    let url: String
    /// How far the page's content starts below the banner's top, to sit on its faded part.
    static let contentInset: CGFloat = 84
    private static let height: CGFloat = 150
    /// Reaches under the navigation bar.
    private static let overflow: CGFloat = 60

    var body: some View {
        CoverImage(url: url)
            .frame(height: Self.height + Self.overflow)
            .frame(maxWidth: .infinity)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .padding(.top, -Self.overflow)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An image that fills whatever frame it gets.
struct CoverImage: View {
    let url: String?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay { CachedImage(url: url) }
            .clipped()
    }
}

/// Covers the video surface with the thumbnail until the new video has a frame.
struct VideoPoster: View {
    @ObservedObject var player: MpvPlayer
    let video: YouTubeVideo?

    var body: some View {
        if !player.isVideoReady, let video {
            CoverImage(url: video.thumbnailURL ?? "https://i.ytimg.com/vi/\(video.videoId)/hqdefault.jpg")
        }
    }
}

/// Woof Music's rounded card that stacks menu rows.
struct MenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.sheetRadius, style: .continuous))
    }
}

/// Woof Music's menu row: accent icon, title and an optional subtitle.
struct MenuRowLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: Layout.menuRowSpacing) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.rowSpacing)
        .contentShape(.rect)
    }
}

/// Woof Music's list row for a playlist: square cover, title and subtitle.
struct MediaListRow: View {
    let url: String?
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: Layout.menuRowSpacing) {
            CoverImage(url: url)
                .frame(width: Layout.artSmall, height: Layout.artSmall)
                .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Layout.rowPadding)
        .contentShape(.rect)
    }
}

/// Woof Music's section title, with the number of entries on the right.
struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
    }
}

/// Decoded images in memory and their files on disk. AsyncImage keeps neither,
/// so it downloads again whenever SwiftUI rebuilds the view.
@MainActor
enum ImageStore {
    // ponytail: counts images, not bytes. Limit by bytes if memory warnings show up in Diagnostics.
    private static let limit = 150
    private static var images: [String: UIImage] = [:]
    private static var order: [String] = []
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()
    private static let memoryWarning = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            images.removeAll()
            order.removeAll()
        }
    }

    static func image(for url: String) -> UIImage? {
        images[url]
    }

    static func load(_ url: String) async throws -> UIImage {
        _ = memoryWarning
        guard let address = URL(string: url) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: address)
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        let prepared = await image.byPreparingForDisplay() ?? image
        if images[url] == nil { order.append(url) }
        images[url] = prepared
        if order.count > limit { images[order.removeFirst()] = nil }
        return prepared
    }
}

/// Woof Music's AsyncImageView: a cached image shows at once, and a shimmer stands in for the rest.
struct CachedImage: View {
    let url: String?
    @State private var loaded: (url: String, image: UIImage)?
    @State private var didFail = false

    private var image: UIImage? {
        guard let url else { return nil }
        return ImageStore.image(for: url) ?? (loaded?.url == url ? loaded?.image : nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if url == nil || didFail {
                Color.clear
            } else {
                ShimmerFill(radius: 0)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        didFail = false
        guard let url, ImageStore.image(for: url) == nil else { return }
        var retryDelays: [Duration] = [.seconds(1), .seconds(3)]
        while !Task.isCancelled {
            do {
                let image = try await ImageStore.load(url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { loaded = (url, image) }
                return
            } catch {
                guard !retryDelays.isEmpty else {
                    didFail = true
                    return
                }
                try? await Task.sleep(for: retryDelays.removeFirst())
            }
        }
    }
}

/// Woof Music's ShimmerFill: a light band sweeps across a gray block.
struct ShimmerFill: View {
    var radius: CGFloat = Layout.cardRadius
    @Environment(\.shimmerPhase) private var sharedPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color(.systemGray5).clipShape(.rect(cornerRadius: radius))
        } else if let sharedPhase {
            fill(phase: sharedPhase)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                fill(phase: shimmerPhase(at: timeline.date))
            }
        }
    }

    private func fill(phase: CGFloat) -> some View {
        Color(.systemGray5)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.5), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 1.5, height: geometry.size.height)
                    .offset(x: (phase * 2 - 1) * geometry.size.width)
                }
            }
            .clipShape(.rect(cornerRadius: radius))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private func shimmerPhase(at date: Date) -> CGFloat {
    let period: TimeInterval = 1.6
    return CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
}

extension EnvironmentValues {
    /// Shared by every fill under `shimmerClock()`.
    @Entry var shimmerPhase: CGFloat?
}

extension View {
    /// Drives every ShimmerFill inside from one timeline, instead of one per block.
    func shimmerClock() -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            environment(\.shimmerPhase, shimmerPhase(at: timeline.date))
        }
    }
}

struct ShimmerBlock: View {
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        ShimmerFill(radius: radius).frame(width: width, height: height)
    }
}
