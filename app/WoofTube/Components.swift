import ImageIO
import SwiftUI
import SwiftyTube

/// For a button drawn with interactive Liquid Glass, which reacts to the finger by itself.
struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Dims and shrinks at the touch, then eases back with no bounce.
struct ZoomPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.1) : .smooth(duration: 0.26), value: configuration.isPressed)
    }
}

/// Woof Music's header button face. `primary` fills it and makes it larger.
struct HeaderRoundIcon: View {
    let systemImage: String
    var primary: Color?
    var motion: GlyphScript?
    var trigger: AnyHashable = 0

    private var size: CGFloat { primary == nil ? 38 : 50 }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: primary == nil ? 15 : 19, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(primary == nil ? Color.primary : .white)
            .glyphMotion(motion, trigger: trigger)
            .frame(width: size, height: size)
            .glassEffect((primary.map { Glass.regular.tint($0) } ?? .regular).interactive(), in: .circle)
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
        HStack(alignment: .top, spacing: Layout.menuRowSpacing) {
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
                .buttonStyle(GlassPressStyle())
            }
            .frame(maxWidth: .infinity, minHeight: artSize, alignment: .leading)
        }
        .padding(.horizontal, Layout.screenPadding)
    }
}

/// The shape of a list of `MediaListRow`s while it loads.
struct LoadingMediaRows: View {
    let isCircular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: Layout.menuRowSpacing) {
                    ShimmerBlock(width: Layout.artSmall, height: Layout.artSmall, radius: isCircular ? Layout.artSmall / 2 : Layout.cardRadius)
                    VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                        ShimmerBlock(width: 160, height: 16)
                        ShimmerBlock(width: 100, height: 13)
                    }
                }
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .shimmerClock()
    }
}

/// `DetailHeaderCard` already shows the title, so the bar repeats it only once the
/// header has scrolled away. A pinned title always shows.
private struct DetailBarTitle: ViewModifier {
    let title: String
    let pinnedTitle: String?
    @State private var isHeaderScrolledAway = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Layout.artLarge
            } action: { _, isScrolledAway in
                isHeaderScrolledAway = isScrolledAway
            }
            .navigationTitle(pinnedTitle ?? (isHeaderScrolledAway ? title : ""))
    }
}

extension View {
    /// Goes on the ScrollView of a page that starts with `DetailHeaderCard`.
    func detailBarTitle(_ title: String, pinnedTitle: String? = nil) -> some View {
        modifier(DetailBarTitle(title: title, pinnedTitle: pinnedTitle))
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
    /// The status and navigation bars' height. The banner reaches under them, up to the screen's top.
    let topInset: CGFloat
    /// How far the page's content starts below the banner's top, to sit on its faded part.
    static let contentInset: CGFloat = 84
    private static let height: CGFloat = 150

    var body: some View {
        CoverImage(url: url)
            .frame(height: Self.height + topInset)
            .frame(maxWidth: .infinity)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .padding(.top, -topInset)
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

/// The header card of a list of videos over its blurred cover, with Shuffle and Play All.
struct VideoListHeader: View {
    let meta: String
    let title: String
    let cover: String?
    let videos: [YouTubeVideo]
    let onPlayAll: () -> Void
    @Environment(Router.self) private var router
    @EnvironmentObject private var settings: AppSettings
    @State private var shuffleTaps = 0

    var body: some View {
        DetailHeaderCard(meta: meta, title: title) {
            CoverImage(url: cover)
                .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
        } secondary: {
            EmptyView()
        } buttons: {
            if !videos.isEmpty {
                Button {
                    shuffleTaps += 1
                    router.playAll(videos, shuffled: true)
                } label: {
                    HeaderRoundIcon(systemImage: "shuffle", motion: .crossSwap, trigger: shuffleTaps)
                }
                .accessibilityLabel("Shuffle")
                Button(action: onPlayAll) {
                    HeaderRoundIcon(systemImage: "play.fill", primary: settings.accentColor)
                }
                .accessibilityLabel("Play All")
            }
        }
        .padding(.vertical, Layout.screenPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: cover)
        }
    }
}

/// Covers the video surface with the thumbnail until the new video has a frame.
struct VideoPoster: View {
    @ObservedObject var player: MpvPlayer
    let video: YouTubeVideo?

    var body: some View {
        if !player.isVideoReady, let video {
            VideoCover(video: video)
        }
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
                .zoomLinkCover()
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
    /// What a full-width row needs, and the size of YouTube's largest thumbnails.
    nonisolated static let feedPixels = 1280
    private static let costLimit = 200 * 1024 * 1024
    // Empties itself under memory pressure.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = costLimit
        return cache
    }()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// Another account's covers say what it watched.
    static func clear() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private static func key(_ url: String, _ maxPixels: Int?) -> NSString {
        "\(url)|\(maxPixels ?? 0)" as NSString
    }

    static func image(for url: String, maxPixels: Int? = nil) -> UIImage? {
        cache.object(forKey: key(url, maxPixels))
    }

    /// Without `maxPixels` the image keeps its full size, which cropping a storyboard sheet needs.
    static func load(_ url: String, maxPixels: Int? = nil) async throws -> UIImage {
        // Some of YouTube's image addresses leave out the "https:".
        guard let address = URL(string: url.hasPrefix("//") ? "https:" + url : url) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: address)
        // YouTube answers a missing picture with a 404 and a gray image.
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 204 || status == 404 { throw URLError(.fileDoesNotExist) }
        guard let image = await offMain({ decode(data, maxPixels: maxPixels) }) else { throw URLError(.cannotDecodeContentData) }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key(url, maxPixels), cost: cost)
        return image
    }

    /// Memory follows an image's pixels, not its file size, so small uses decode small.
    nonisolated private static func decode(_ data: Data, maxPixels: Int?) -> UIImage? {
        if let maxPixels, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: thumbnail)
            }
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// Woof Music's AsyncImageView: a cached image shows at once, and a shimmer stands in for the rest.
struct CachedImage: View {
    let url: String?
    var maxPixels: Int? = ImageStore.feedPixels
    /// Called when `url` can't be loaded.
    var onFailure: (() -> Void)?
    @State private var loaded: (url: String, image: UIImage)?
    @State private var didFail = false

    private var image: UIImage? {
        guard let url else { return nil }
        return ImageStore.image(for: url, maxPixels: maxPixels) ?? (loaded?.url == url ? loaded?.image : nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if url == nil || didFail {
                Color.clear
            } else {
                Color(.systemGray5)
            }
        }
        .task(id: url) { await load() }
        // A lazy list keeps the state of rows scrolled away, and this would pin their pictures.
        .onDisappear { loaded = nil }
    }

    private func load() async {
        didFail = false
        guard let url else { return }
        // Kept here too, because the store can drop an image while this view still shows it.
        if let stored = ImageStore.image(for: url, maxPixels: maxPixels) {
            loaded = (url, stored)
            return
        }
        var retryDelays: [Duration] = [.seconds(1), .seconds(3)]
        while !Task.isCancelled {
            do {
                let image = try await ImageStore.load(url, maxPixels: maxPixels)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { loaded = (url, image) }
                return
            } catch {
                let isMissing = (error as? URLError)?.code == .fileDoesNotExist
                guard !isMissing, !retryDelays.isEmpty else {
                    didFail = true
                    onFailure?()
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
            TimelineView(.animation(minimumInterval: 1 / 30, paused: UIAccessibility.isReduceMotionEnabled)) { timeline in
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
        TimelineView(.animation(minimumInterval: 1 / 30, paused: UIAccessibility.isReduceMotionEnabled)) { timeline in
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
