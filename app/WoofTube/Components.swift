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
            .background(Circle().fill(primary ?? Color.primary.opacity(0.1)))
            .contentShape(Circle())
    }
}

/// Woof Music's header for the channel and playlist pages: a large cover on the left,
/// then the kind, title, secondary line and round buttons on the right.
struct DetailHeaderCard<Cover: View, Secondary: View, Buttons: View>: View {
    let meta: String
    let title: String
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var secondary: () -> Secondary
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            cover()
                .frame(width: Layout.artLarge, height: Layout.artLarge)
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
            .frame(maxWidth: .infinity, minHeight: Layout.artLarge, alignment: .leading)
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

/// An image that fills whatever frame it gets.
struct CoverImage: View {
    let url: String?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                AsyncImage(url: url.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
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

/// Woof Music's section title.
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .padding(.horizontal, Layout.screenPadding)
            .padding(.vertical, Layout.chipSpacing)
    }
}
