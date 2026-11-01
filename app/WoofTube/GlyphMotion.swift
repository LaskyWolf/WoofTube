import SwiftUI

/// One moment of an icon's movement. Distances are in points, angles in degrees.
struct GlyphPose {
    var scaleX = 1.0
    var scaleY = 1.0
    var rotation = 0.0
    var x = 0.0
    var y = 0.0
    var flip = 0.0
    var opacity = 1.0

    fileprivate func mixed(with other: GlyphPose, by amount: Double) -> GlyphPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return GlyphPose(
            scaleX: mix(scaleX, other.scaleX),
            scaleY: mix(scaleY, other.scaleY),
            rotation: mix(rotation, other.rotation),
            x: mix(x, other.x),
            y: mix(y, other.y),
            flip: mix(flip, other.flip),
            opacity: mix(opacity, other.opacity)
        )
    }
}

/// How one icon moves, and what flies out of it. Woof Music's like button works the same way:
/// everything is worked out from the time since the tap, so nothing is left running afterwards.
struct GlyphScript {
    struct Key {
        let time: Double
        let pose: GlyphPose

        init(_ time: Double, sx: Double = 1, sy: Double = 1, r: Double = 0, x: Double = 0, y: Double = 0, flip: Double = 0, o: Double = 1) {
            self.time = time
            pose = GlyphPose(scaleX: sx, scaleY: sy, rotation: r, x: x, y: y, flip: flip, opacity: o)
        }

        init(_ time: Double, s: Double, r: Double = 0, x: Double = 0, y: Double = 0, flip: Double = 0, o: Double = 1) {
            self.init(time, sx: s, sy: s, r: r, x: x, y: y, flip: flip, o: o)
        }
    }

    enum Ink {
        case accent
        case color(Color)
    }

    enum BitShape {
        case dot
        case symbol(String)
        case text(String)
    }

    struct Bit {
        var shape = BitShape.dot
        var ink = Ink.accent
        /// 0 points right, and -90 points up.
        var angle = -90.0
        var reach = 24.0
        var delay = 0.0
        var life = 0.7
        var size = 5.0
    }

    struct Ring {
        var ink = Ink.accent
        var delay = 0.0
    }

    let keys: [Key]
    var anchor = UnitPoint.center
    var rings: [Ring] = []
    var bits: [Bit] = []

    var duration: Double {
        let moves = keys.last?.time ?? 0
        let ringsEnd = rings.map { $0.delay + GlyphExtras.ringLife }.max() ?? 0
        let bitsEnd = bits.map { $0.delay + $0.life }.max() ?? 0
        return max(moves, ringsEnd, bitsEnd)
    }

    func pose(at time: Double) -> GlyphPose {
        guard let first = keys.first, let last = keys.last else { return GlyphPose() }
        if time <= first.time { return first.pose }
        if time >= last.time { return last.pose }
        for (start, end) in zip(keys, keys.dropFirst()) where time < end.time {
            let x = (time - start.time) / (end.time - start.time)
            return start.pose.mixed(with: end.pose, by: x * x * (3 - 2 * x))
        }
        return last.pose
    }

    /// Bits spread evenly across an arc, each going a slightly different distance.
    static func burst(
        _ count: Int,
        shape: BitShape = .dot,
        inks: [Ink] = [.accent],
        around angle: Double = -90,
        spread: Double = 360,
        reach: Double = 24,
        delay: Double = 0,
        stagger: Double = 0,
        life: Double = 0.7,
        size: Double = 5
    ) -> [Bit] {
        (0..<count).map { index in
            let share = count > 1 ? Double(index) / Double(spread >= 360 ? count : count - 1) - (spread >= 360 ? 0 : 0.5) : 0
            return Bit(
                shape: shape,
                ink: inks[index % inks.count],
                angle: angle + share * spread,
                reach: reach * (0.8 + Double((index * 37) % 10) / 20),
                delay: delay + Double(index) * stagger,
                life: life,
                size: size
            )
        }
    }
}

// The icons' movements. Pressed often means short, and pressed rarely can celebrate.
extension GlyphScript {
    // Playback
    static let pauseStamp = GlyphScript(keys: [Key(0, s: 1.3, y: -7), Key(0.14, sx: 1.12, sy: 0.82), Key(0.28, s: 1)])
    static let playShoot = GlyphScript(
        keys: [Key(0, sx: 1.25, sy: 0.7, x: -8), Key(0.16, sx: 0.92, sy: 1.1, x: 3), Key(0.3, s: 1)],
        rings: [Ring(ink: .color(.white))]
    )
    static let pullApart = GlyphScript(keys: [Key(0, s: 0.7), Key(0.2, s: 1.28), Key(0.35, s: 1)])
    static let squeezeIn = GlyphScript(keys: [Key(0, s: 1.25), Key(0.2, s: 0.78), Key(0.35, s: 1)])
    static let spinBack = GlyphScript(keys: [Key(0, s: 0.8, r: 0, x: 8), Key(0.25, s: 1.2, r: -300, x: -4), Key(0.42, s: 1, r: -360)])
    static let spinForward = GlyphScript(keys: [Key(0, s: 0.8, r: 0, x: -8), Key(0.25, s: 1.2, r: 300, x: 4), Key(0.42, s: 1, r: 360)])
    static let needleRev = GlyphScript(keys: [Key(0, r: 0), Key(0.08, r: 7), Key(0.16, r: -6), Key(0.24, r: 5), Key(0.32, r: -3), Key(0.42, r: 0)], bits: burst(5, inks: [.color(.orange), .accent], around: 0, spread: 70, reach: 22, delay: 0.1, life: 0.45, size: 3))
    static let captionsOn = GlyphScript(
        keys: [Key(0, s: 0.8), Key(0.18, s: 1.12), Key(0.34, s: 1)],
        bits: [
            Bit(shape: .text("C"), ink: .color(.white), angle: 180, reach: 7, delay: 0.1, life: 0.5, size: 9),
            Bit(shape: .text("C"), ink: .color(.white), angle: 0, reach: 7, delay: 0.26, life: 0.5, size: 9)
        ]
    )
    static let captionsOff = GlyphScript(keys: [Key(0, y: -4), Key(0.12, y: 3), Key(0.26, y: 0)])
    static let qualitySparkle = GlyphScript(
        keys: [Key(0, s: 0.9), Key(0.2, s: 1.08), Key(0.4, s: 1)],
        bits: burst(4, shape: .symbol("sparkle"), inks: [.color(.yellow), .color(.white)], spread: 120, reach: 18, stagger: 0.1, life: 0.55, size: 7)
    )
    static let audioPulse = GlyphScript(keys: [Key(0, sx: 1, sy: 0.5), Key(0.14, sx: 1, sy: 1.3), Key(0.28, sx: 1, sy: 0.8), Key(0.42, sx: 1, sy: 1.12), Key(0.56, s: 1)])
    static let nextCard = GlyphScript(keys: [Key(0, s: 0.85, y: 8), Key(0.22, s: 1.05, y: -3), Key(0.42, s: 1)])
    static let sleepRock = GlyphScript(
        keys: [Key(0, r: -14), Key(0.4, r: 10), Key(0.8, r: -5), Key(1.2, r: 0)],
        bits: [
            Bit(shape: .text("z"), ink: .color(.white), angle: -60, reach: 14, delay: 0.1, life: 0.8, size: 8),
            Bit(shape: .text("z"), ink: .color(.white), angle: -55, reach: 20, delay: 0.35, life: 0.8, size: 10),
            Bit(shape: .text("z"), ink: .color(.white), angle: -50, reach: 26, delay: 0.6, life: 0.8, size: 12)
        ]
    )
    static let quarterTurn = GlyphScript(keys: [Key(0, s: 1), Key(0.14, s: 0.75, r: 60), Key(0.25, s: 1, r: 90)])

    // The video page
    /// A different trick each time, and now and then the emoji of what the video is about.
    static func like(emojis: [String]) -> GlyphScript {
        let inks: [Ink] = [.accent, .color(.orange), .color(.white)]
        let tricks = [
            GlyphScript(
                keys: [Key(0, s: 1), Key(0.16, s: 0.82, r: -32), Key(0.32, s: 1.4, r: 14, y: -3), Key(0.62, s: 1)],
                rings: [Ring()],
                bits: burst(9, inks: inks, reach: 26, delay: 0.2, life: 0.6, size: 4)
            ),
            GlyphScript(keys: [Key(0, s: 0.7), Key(0.5, s: 1.35, flip: 360), Key(0.9, s: 1, flip: 720)]),
            GlyphScript(keys: [Key(0), Key(0.12, sx: 1.4, sy: 0.65), Key(0.3, sx: 0.72, sy: 1.32, y: -3), Key(0.46, sx: 1.18, sy: 0.86), Key(0.62, sx: 0.94, sy: 1.06), Key(0.76)]),
            GlyphScript(
                keys: [Key(0, s: 0.8), Key(0.24, s: 1.3), Key(0.48, s: 1)],
                bits: burst(6, shape: .symbol("hand.thumbsup.fill"), spread: 60, reach: 40, stagger: 0.11, life: 1, size: 10)
            ),
            GlyphScript(keys: [Key(0, sx: 1.2, sy: 0.72), Key(0.3, sx: 0.84, sy: 1.2, y: -10), Key(0.52, sx: 1.2, sy: 0.76), Key(0.7)]),
            GlyphScript(keys: [Key(0, s: 1), Key(0.14, s: 1.45), Key(0.28, s: 1.1), Key(0.42, s: 1.55), Key(0.9, s: 1)], rings: [Ring(), Ring(delay: 0.3)])
        ]
        if !emojis.isEmpty, Int.random(in: 0..<5) == 0 {
            return GlyphScript(
                keys: [Key(0, s: 1), Key(0.1, s: 0, o: 0), Key(1.1, s: 0, o: 0), Key(1.4, s: 1)],
                bits: [Bit(shape: .text(emojis[0]), angle: -90, reach: 4, delay: 0.1, life: 1.1, size: 24)]
                    + (0..<7).map { index in
                        Bit(shape: .text(emojis[index % emojis.count]), angle: -90 + Double(index - 3) * 26, reach: 36, delay: 0.14, life: 0.9, size: 12)
                    }
            )
        }
        return tricks.randomElement() ?? tricks[0]
    }

    static let deflate = GlyphScript(keys: [Key(0, s: 1.1), Key(0.14, s: 0.82), Key(0.26, s: 1)])
    static let dislike = GlyphScript(
        keys: [Key(0, r: -8, y: -12), Key(0.2, sx: 1.22, sy: 0.74, y: 2), Key(0.38, sx: 0.96, sy: 1.05), Key(0.56)],
        bits: burst(5, inks: [.color(.gray)], around: 90, spread: 50, reach: 20, delay: 0.22, stagger: 0.07, life: 0.6, size: 2.5)
    )
    static let rise = GlyphScript(keys: [Key(0, y: 4), Key(0.26)])
    static let subscribed = GlyphScript(
        keys: [Key(0, s: 1), Key(0.14, s: 0.9), Key(0.34, s: 1.12, y: -3), Key(0.56, s: 1)],
        rings: [Ring()],
        bits: burst(12, inks: [.accent, .color(.orange), .color(.green), .color(.blue), .color(.white)], reach: 44, delay: 0.1, life: 0.9, size: 4)
    )
    static let unsubscribed = GlyphScript(keys: [Key(0, r: -3, y: -3), Key(0.18, r: 2), Key(0.3)])
    static let shareLaunch = GlyphScript(
        keys: [Key(0, s: 1), Key(0.1, sx: 1.14, sy: 0.82), Key(0.2, sx: 0.9, sy: 1.1, y: -5), Key(0.34, sx: 1.04, sy: 0.96), Key(0.5)],
        bits: [Bit(shape: .symbol("arrow.up"), ink: .color(.white), angle: -90, reach: 34, delay: 0.06, life: 0.42, size: 12)]
    )
    static let clockForward = GlyphScript(keys: [Key(0, s: 0.92, r: 0), Key(0.7, s: 1, r: 1080)])
    static let clockBack = GlyphScript(keys: [Key(0, s: 0.92, r: 0), Key(0.7, s: 1, r: -1080)])
    static let addToList = GlyphScript(
        keys: [Key(0, y: -4), Key(0.2, s: 1.1, y: 2), Key(0.45, s: 1)],
        bits: [Bit(shape: .symbol("minus"), ink: .color(.white), angle: 180, reach: 22, life: 0.3, size: 12)]
    )
    static let arrowDrop = GlyphScript(keys: [Key(0, y: -12, o: 0), Key(0.18, sx: 1.1, sy: 0.84, y: 2), Key(0.34)])
    static let checkStamp = GlyphScript(
        keys: [Key(0, s: 0.2, o: 0), Key(0.16, s: 1.45), Key(0.32, s: 1)],
        rings: [Ring()],
        bits: burst(7, reach: 22, delay: 0.1, life: 0.5, size: 3)
    )
    static let bubblePop = GlyphScript(
        keys: [Key(0, s: 0.78), Key(0.16, s: 1.14), Key(0.32, s: 1)],
        bits: burst(3, inks: [.color(.white)], around: -90, spread: 44, reach: 22, delay: 0.1, stagger: 0.08, life: 0.4, size: 3.5)
    )
    /// The lens comes up to your face, then settles back.
    static let lensZoom = GlyphScript(keys: [Key(0, s: 1), Key(0.1, s: 0.86, r: -6), Key(0.3, s: 2.6, r: 6, y: 2), Key(0.5, s: 1.9, r: 0, o: 0.65), Key(0.72, s: 1)])

    // Around the app
    static let bellRing = GlyphScript(
        keys: [Key(0, r: 0), Key(0.12, r: 24), Key(0.26, r: -20), Key(0.4, r: 14), Key(0.54, r: -9), Key(0.68, r: 4), Key(0.86, r: 0)],
        anchor: .top,
        rings: [Ring(ink: .color(.gray)), Ring(ink: .color(.gray), delay: 0.2)]
    )
    static let glassesOn = GlyphScript(
        keys: [Key(0, r: -8, y: -12), Key(0.24, r: 3, y: 2), Key(0.44)],
        bits: burst(2, inks: [.color(.white)], spread: 180, reach: 12, delay: 0.26, life: 0.3, size: 2.5)
    )
    static let glassesOff = GlyphScript(keys: [Key(0, y: 4), Key(0.28)])
    static let plusTurn = GlyphScript(keys: [Key(0, s: 0.8, r: 0), Key(0.22, s: 1.2, r: 100), Key(0.4, s: 1, r: 90)])
    static let crossSwap = GlyphScript(keys: [Key(0, sx: 1, sy: -1), Key(0.24, s: 1.12), Key(0.42, s: 1)])
    static let dashAhead = GlyphScript(keys: [Key(0, sx: 1.2, sy: 0.8, x: -10), Key(0.16, x: 3), Key(0.28, x: -1), Key(0.4)])
    static let sunRise = GlyphScript(keys: [Key(0, s: 0.5, r: -90, o: 0.3), Key(0.34, s: 1.14, r: 10), Key(0.56, s: 1)])
    static let moonRise = GlyphScript(keys: [Key(0, s: 0.5, r: -120, o: 0.3), Key(0.34, s: 1.1, r: 10), Key(0.52, s: 1)])
    static let pop = GlyphScript(keys: [Key(0, s: 0.8), Key(0.14, s: 1.16), Key(0.3, s: 1)])

    static func selfCheck() {
        let all: [GlyphScript] = [
            .pauseStamp, .playShoot, .pullApart, .squeezeIn, .spinBack, .spinForward, .needleRev, .captionsOn, .captionsOff,
            .qualitySparkle, .audioPulse, .nextCard, .sleepRock, .like(emojis: []), .deflate, .dislike, .rise, .subscribed,
            .unsubscribed, .shareLaunch, .addToList, .arrowDrop, .checkStamp, .bubblePop, .lensZoom, .bellRing, .glassesOn,
            .glassesOff, .crossSwap, .dashAhead, .sunRise, .moonRise, .pop
        ]
        // Every movement has to land where the icon rests, or it jumps at the end.
        for script in all {
            let end = script.pose(at: script.duration)
            assert(end.scaleX == 1 && end.scaleY == 1 && end.x == 0 && end.y == 0 && end.opacity == 1)
            assert(end.rotation.truncatingRemainder(dividingBy: 360) == 0 && end.flip.truncatingRemainder(dividingBy: 360) == 0)
        }
        let halfway = GlyphScript(keys: [.init(0, s: 0), .init(1, s: 2)]).pose(at: 0.5)
        assert(halfway.scaleX == 1)
    }
}

private struct GlyphRun: Equatable {
    let start: Date
    let script: GlyphScript

    static func == (a: GlyphRun, b: GlyphRun) -> Bool { a.start == b.start }
}

private struct GlyphRunner<Trigger: Equatable>: ViewModifier {
    let script: GlyphScript?
    let trigger: Trigger
    let playsOnAppear: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: GlyphRun?

    func body(content: Content) -> some View {
        // Paused unless it's moving, so a resting icon costs nothing.
        TimelineView(.animation(minimumInterval: nil, paused: run == nil)) { context in
            let time = run.map { context.date.timeIntervalSince($0.start) } ?? 0
            let pose = run?.script.pose(at: time) ?? GlyphPose()
            let anchor = run?.script.anchor ?? .center
            content
                .rotation3DEffect(.degrees(pose.flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: anchor)
                .rotationEffect(.degrees(pose.rotation), anchor: anchor)
                .offset(x: pose.x, y: pose.y)
                .opacity(pose.opacity)
                .overlay {
                    if let run {
                        GlyphExtras(script: run.script, time: time)
                    }
                }
        }
        .onChange(of: trigger) { start() }
        .onAppear { if playsOnAppear { start() } }
        .task(id: run?.start) {
            guard let current = run else { return }
            try? await Task.sleep(for: .seconds(current.script.duration))
            if !Task.isCancelled, run == current { run = nil }
        }
    }

    private func start() {
        guard !reduceMotion, let script else { return }
        run = GlyphRun(start: Date(), script: script)
    }
}

private struct GlyphExtras: View {
    static let ringLife = 0.6
    private static let ringSize: CGFloat = 28

    let script: GlyphScript
    let time: Double

    var body: some View {
        ZStack {
            ForEach(Array(script.rings.enumerated()), id: \.offset) { _, ring in
                let progress = min(max((time - ring.delay) / Self.ringLife, 0), 1)
                Circle()
                    .stroke(style(ring.ink), lineWidth: 1.5)
                    .frame(width: Self.ringSize, height: Self.ringSize)
                    .scaleEffect(0.6 + progress * 1.3)
                    .opacity(progress > 0 && progress < 1 ? 0.8 * (1 - progress) : 0)
            }
            ForEach(Array(script.bits.enumerated()), id: \.offset) { _, bit in
                let progress = min(max((time - bit.delay) / bit.life, 0), 1)
                let reach = bit.reach * (1 - pow(1 - progress, 2))
                let radians = bit.angle * .pi / 180
                shape(of: bit)
                    .foregroundStyle(style(bit.ink))
                    .scaleEffect(0.5 + progress * 0.6)
                    .offset(x: cos(radians) * reach, y: sin(radians) * reach)
                    .opacity(progress > 0 && progress < 1 ? sin(progress * .pi) : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shape(of bit: GlyphScript.Bit) -> some View {
        switch bit.shape {
        case .dot:
            Circle().frame(width: bit.size, height: bit.size)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: bit.size, weight: .bold))
        case .text(let text):
            Text(text).font(.system(size: bit.size, weight: .heavy))
        }
    }

    private func style(_ ink: GlyphScript.Ink) -> AnyShapeStyle {
        switch ink {
        case .accent: AnyShapeStyle(.tint)
        case .color(let color): AnyShapeStyle(color)
        }
    }
}

extension View {
    /// Plays a movement each time `trigger` changes. Without a script it does nothing, and Reduce Motion skips it.
    func glyphMotion<Trigger: Equatable>(_ script: GlyphScript?, trigger: Trigger, playsOnAppear: Bool = false) -> some View {
        modifier(GlyphRunner(script: script, trigger: trigger, playsOnAppear: playsOnAppear))
    }
}

/// Melts an icon into its next shape, such as play into pause.
struct MorphingGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .animation(.snappy, value: systemName)
    }
}

/// A dial whose needle points at the real playback speed.
struct SpeedGauge: View {
    let speed: Double
    var size: CGFloat = 15

    private var needleAngle: Double {
        let range = (Router.speeds.first ?? 0.5)...(Router.speeds.last ?? 2)
        return -110 + 220 * (min(max(speed, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(90))
            Capsule()
                .frame(width: size * 0.12, height: size * 0.42)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(needleAngle))
                .animation(.spring(duration: 0.6, bounce: 0.5), value: speed)
            Circle().frame(width: size * 0.2, height: size * 0.2)
        }
        .frame(width: size, height: size)
        .glyphMotion(speed >= (Router.speeds.last ?? 2) ? .needleRev : nil, trigger: speed)
        .accessibilityHidden(true)
    }
}

extension Double {
    /// Apple's closest gauge symbol, for menus, which can only show a still image.
    var gaugeSymbol: String {
        switch self {
        case ..<0.75: "gauge.with.dots.needle.0percent"
        case ..<1: "gauge.with.dots.needle.33percent"
        case ..<1.5: "gauge.with.dots.needle.50percent"
        case ..<2: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}

/// What a video seems to be about, so a like can turn into its emoji.
enum VideoFlavor {
    // ponytail: reads the title only, in English and Italian. YouTube's own category needs another request per video.
    private static let table: [(emojis: [String], words: Set<String>)] = [
        (["🎮", "🕹️", "👾"], ["game", "games", "gaming", "gameplay", "minecraft", "fortnite", "nintendo", "playstation", "xbox", "speedrun"]),
        (["🎵", "🎶", "🎧"], ["music", "song", "lyrics", "album", "concert", "remix", "musica", "canzone"]),
        (["🍕", "🍳", "😋"], ["recipe", "cooking", "food", "kitchen", "ricetta", "cucina", "pizza", "pasta"]),
        (["🐾", "🐶", "🐱"], ["dog", "dogs", "cat", "cats", "puppy", "kitten", "cane", "gatto", "animals"]),
        (["⚽", "🏆", "🏀"], ["football", "soccer", "goal", "basketball", "nba", "calcio", "highlights"]),
        (["🚗", "🏁", "🏎️"], ["car", "cars", "racing", "f1", "supercar", "auto"]),
        (["✈️", "🌍", "🧳"], ["travel", "trip", "flight", "viaggio", "vlog"]),
        (["📱", "💻", "🔧"], ["iphone", "android", "tech", "review", "apple", "laptop", "coding"]),
        (["🔭", "🚀", "🧪"], ["space", "science", "nasa", "rocket", "physics", "scienza"]),
        (["😂", "🤣", "🎭"], ["funny", "comedy", "meme", "prank", "divertente"])
    ]

    static func emojis(for title: String?) -> [String] {
        let words = Set((title ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return table.first { !$0.words.isDisjoint(with: words) }?.emojis ?? []
    }

    static func selfCheck() {
        assert(emojis(for: "My Minecraft world, part 2").first == "🎮")
        assert(emojis(for: "La RICETTA della nonna").first == "🍕")
        assert(emojis(for: "A quiet walk").isEmpty)
        assert(emojis(for: nil).isEmpty)
    }
}

/// Opens a page by growing it out of what was tapped, as Woof Music does for its covers.
struct ZoomLink<Destination: View, Label: View>: View {
    private let destination: () -> Destination
    private let label: () -> Label
    @Namespace private var space
    private static var sourceId: String { "open" }

    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        NavigationLink {
            destination().navigationTransition(.zoom(sourceID: Self.sourceId, in: space))
        } label: {
            label().matchedTransitionSource(id: Self.sourceId, in: space)
        }
    }
}

extension EnvironmentValues {
    /// Shared by a tab's screens, for pages opened from code rather than from a link.
    @Entry var tabZoomSpace: Namespace.ID?
}

private struct TabZoomSource<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    @Environment(\.tabZoomSpace) private var space

    func body(content: Content) -> some View {
        if let space {
            content.matchedTransitionSource(id: id, in: space)
        } else {
            content
        }
    }
}

extension View {
    /// What a page in the same tab grows out of when it opens with this ID.
    func tabZoomSource<ID: Hashable & Sendable>(_ id: ID) -> some View {
        modifier(TabZoomSource(id: id))
    }
}
