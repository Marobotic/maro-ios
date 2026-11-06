import SwiftUI
import UIKit

/** Monospace text in the redesign's palette. */
struct OmpText: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Omp.foreground
    var bold = false
    var maxLines = 1
    var align: TextAlignment = .leading

    init(_ text: String, size: CGFloat = 12, color: Color = Omp.foreground, bold: Bool = false, maxLines: Int = 1, align: TextAlignment = .leading) {
        self.text = text
        self.size = size
        self.color = color
        self.bold = bold
        self.maxLines = maxLines
        self.align = align
    }

    var body: some View {
        Text(text)
            .font(Omp.font(size, bold: bold))
            .foregroundColor(color)
            .lineLimit(maxLines)
            .truncationMode(.tail)
            .multilineTextAlignment(align)
    }
}

/** The desktop's spinner: a ring with one quarter open, turning. */
struct OmpSpinner: View {
    var size: CGFloat = 10
    var color: Color = Omp.themeAccent
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size * 0.15)))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/** Presses shrink a little and spring back, as the desktop's buttons do. */
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/** A #121212 tile with the #242424 hairline: the redesign's one surface. */
struct TileBackground: ViewModifier {
    var color: Color = Omp.tile
    var border: Color = Omp.line

    func body(content: Content) -> some View {
        content
            .background(color)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
    }
}

extension View {
    func tile(_ color: Color = Omp.tile, border: Color = Omp.line) -> some View {
        modifier(TileBackground(color: color, border: border))
    }
}

/** The desktop's labelled button (.m-btn): normal, primary, danger, ghost or selected; 36 or 32 pt high. */
struct MButton: View {
    enum Kind { case normal, primary, danger, ghost, selected, dark }
    let label: String
    var icon: Glyph? = nil
    var iconSize: CGFloat = 14
    var iconColor: Color? = nil
    var kind: Kind = .normal
    var small = true
    var enabled = true
    var expand = false
    var height: CGFloat? = nil
    let action: () -> Void

    init(_ label: String, icon: Glyph? = nil, iconSize: CGFloat = 14, iconColor: Color? = nil, kind: Kind = .normal,
         small: Bool = true, enabled: Bool = true, expand: Bool = false, height: CGFloat? = nil, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.iconSize = iconSize
        self.iconColor = iconColor
        self.kind = kind
        self.small = small
        self.enabled = enabled
        self.expand = expand
        self.height = height
        self.action = action
    }

    private var bg: Color {
        switch kind {
        case .normal, .selected: return Omp.raise
        case .primary: return Omp.themeAccent
        case .danger, .ghost: return .clear
        case .dark: return Color.black.opacity(0.5)
        }
    }

    private var border: Color {
        switch kind {
        case .normal, .selected, .dark: return Omp.edge
        case .primary: return Omp.themeAccent
        case .danger: return Omp.themeAccent.opacity(0.55)
        case .ghost: return .clear
        }
    }

    private var fg: Color {
        switch kind {
        case .normal, .ghost, .dark: return Omp.foreground
        case .primary, .selected: return .white
        case .danger: return Omp.danger
        }
    }

    var body: some View {
        let side: CGFloat = small ? 32 : 36
        let minW: CGFloat? = label.isEmpty ? side : nil
        let maxW: CGFloat? = expand ? CGFloat.infinity : nil
        let pad: CGFloat = label.isEmpty ? 0 : (small ? 14 : 16)
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Icon(icon, size: iconSize, color: iconColor ?? fg) }
                if !label.isEmpty { OmpText(label, size: small ? 11.5 : 12, color: fg, bold: true) }
            }
            .padding(.horizontal, pad)
            .frame(minWidth: minW)
            .frame(maxWidth: maxW)
            .frame(height: height ?? side)
            .background(bg)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/** The desktop's icon button (.t-btn): a 36 pt square, #B3B3B3, accent-soft when on. */
struct TButton: View {
    let glyph: Glyph
    var size: CGFloat = 16
    var box: CGFloat = 36
    var color: Color = Omp.iconTint
    var on = false
    var enabled = true
    var weight: CGFloat? = nil
    let action: () -> Void

    init(_ glyph: Glyph, size: CGFloat = 16, box: CGFloat = 36, color: Color = Omp.iconTint, on: Bool = false,
         enabled: Bool = true, weight: CGFloat? = nil, action: @escaping () -> Void) {
        self.glyph = glyph
        self.size = size
        self.box = box
        self.color = color
        self.on = on
        self.enabled = enabled
        self.weight = weight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(glyph, size: size, color: on ? Omp.soft : color, weight: weight)
                .frame(width: box, height: box)
                .background(on ? Omp.pill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/** The old in-panel button, kept for the sign-in sheet: now the desktop's small .m-btn. */
struct OmpButton: View {
    var text = ""
    var selected = false
    var enabled = true
    var foreground: Color = Omp.foreground
    let action: () -> Void

    var body: some View {
        MButton(text, kind: selected ? .selected : .normal, enabled: enabled, action: action)
    }
}

/** A single-line field: square, #0D0D0D, #333 border (the desktop's .field). */
struct OmpTextField: View {
    @Binding var text: String
    var placeholder = ""
    var password = false
    var keyboard: UIKeyboardType = .default
    var height: CGFloat = 42
    var onSubmit: (() -> Void)?

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty { OmpText(placeholder, size: 12, color: Omp.t3) }
            Group {
                if password {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text).keyboardType(keyboard)
                }
            }
            .font(Omp.font(12))
            .foregroundColor(Omp.foreground)
            .tint(Omp.themeAccent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(onSubmit != nil ? .go : .next)
            .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(Omp.page)
        .overlay(Rectangle().strokeBorder(Omp.edge, lineWidth: 1))
    }
}

/** The playing row's bars: four 2.5 pt bars in accent-soft, bouncing while it plays. */
struct EqBars: View {
    var color: Color = Omp.soft
    var size: CGFloat = 14

    private static let speeds: [Double] = [0.52, 0.82, 0.62, 0.72]
    private static let delays: [Double] = [0.08, 0.22, 0.04, 0.18]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    // The desktop's eqB keyframes: .2 → .95 → .35 of the height, alternating.
                    let period = Self.speeds[i] * 2
                    let phase = ((t + Self.delays[i]).truncatingRemainder(dividingBy: period)) / period
                    let tri = phase < 0.5 ? phase * 2 : 2 - phase * 2
                    let k = tri < 0.5 ? 0.2 + (0.95 - 0.2) * (tri * 2) : 0.95 - (0.95 - 0.35) * ((tri - 0.5) * 2)
                    Rectangle().fill(color).frame(width: 2.5, height: size * k)
                }
            }
            .frame(width: size, height: size, alignment: .bottom)
        }
    }
}

/** The saved-offline mark: a check in the song's service colour. */
struct SavedCheck: View {
    let color: Color

    var body: some View {
        Icon(.check, size: 11, color: color)
    }
}

/** A cover from the droplet or the provider CDN, falling back to the service's icon. Square. */
struct CoverArt: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var loader = ArtLoader.shared
    /** A song: its one picture from the droplet, scaled to exactly this box. */
    var track: Track? = nil
    /** A playlist tile: its sleeve, by the droplet's key or a CDN URL. */
    var artKey: String = ""
    var artUrl: String = ""
    let icon: Glyph
    let size: CGFloat
    var busy = false
    @State private var image: UIImage? = nil

    var body: some View {
        let side = size
        let px = Int((side * displayScale).rounded())
        let key = track.map { loader.songKey($0, px: px) } ?? loader.key(artKey: artKey, artUrl: artUrl, px: px)
        // What memory holds is drawn in this very frame: the lists' covers are
        // decoded ahead (ArtLoader.prefetch), and waiting for .task left every
        // row blank for a frame - a whole screen of blanks while flinging.
        let quickKey = track.map { loader.key(artKey: "", artUrl: $0.artUrl, px: px) } ?? ""
        let shown = loader.cached(key) ?? (quickKey.isEmpty ? nil : loader.cached(quickKey)) ?? image
        ZStack {
            Color(hex: 0x171717)
            if let image = shown {
                Image(uiImage: image).resizable().scaledToFill()
            } else if busy {
                OmpSpinner(size: 12, color: Omp.t2)
            } else {
                Icon(icon, size: max(12, min(28, side * 0.32)), color: Omp.t2)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: "\(key)#\(loader.epoch)#\(track?.artUrl ?? "")") {
            let quickKey = track.map { loader.key(artKey: "", artUrl: $0.artUrl, px: px) } ?? ""
            image = loader.cached(key) ?? (quickKey.isEmpty ? nil : loader.cached(quickKey))
            if let track {
                if size == Omp.rowArt { loader.rowPx = px }
                let big = size > 80
                let have = loader.hasSong(track)
                // The picture the song came with: its service's own, at this
                // box's size, from the disk or straight from Spotify's or
                // Google's image servers (tens of milliseconds).
                if image == nil && !have && !track.artUrl.isEmpty {
                    let quick = await loader.load(artKey: "", artUrl: track.artUrl, px: px)
                    // A row scrolled away meanwhile shows another song now:
                    // this picture is not its.
                    if Task.isCancelled { return }
                    if let quick { image = quick }
                }
                // A row is done once it shows that. The droplet's chosen
                // cover is a 1200 px picture: fetched for every row on 4G it
                // crowded out the rows and the music, so only a big box (the
                // full-screen cover, a card) asks for it, or a row whose copy
                // is on the phone already.
                if image != nil && !big && !have { return }
                guard !key.isEmpty, loader.cached(key) == nil else { return }
                for attempt in 0..<3 {
                    let got = await loader.loadSong(track, px: px)
                    if Task.isCancelled { return }
                    if let got {
                        image = got
                        return
                    }
                    await sleep(seconds: 2 * Double(attempt + 1))
                }
                return
            }
            guard image == nil, !key.isEmpty else { return }
            for attempt in 0..<3 {
                let got = await loader.load(artKey: artKey, artUrl: artUrl, px: px)
                if Task.isCancelled { return }
                if let got {
                    image = got
                    return
                }
                if attempt < 2 { await sleep(seconds: 0.7 * Double(attempt + 1)) }
            }
        }
    }
}

/**
 * The heart, one for every list and the player: an outline in #A0A0A0, filled
 * #E05263 when liked, with the desktop's pop (1 → 1.45 → .86 → 1) and six
 * small squares flying out, only when liking.
 */
struct HeartButton: View {
    let liked: Bool
    var size: CGFloat = 15
    var box: CGFloat = 34
    var color: Color = Omp.t2
    var enabled = true
    let action: () -> Void
    @State private var pop: CGFloat = 1
    @State private var burst = false

    var body: some View {
        Button {
            if !liked { celebrate() }
            action()
        } label: {
            ZStack {
                if burst { HeartBurst() }
                Icon(.heart, size: size, color: liked ? Omp.like : color, filled: liked)
                    .scaleEffect(pop)
            }
            .frame(width: box, height: box)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func celebrate() {
        withAnimation(.easeOut(duration: 0.12)) { pop = 1.45 }
        withAnimation(.easeInOut(duration: 0.13).delay(0.12)) { pop = 0.86 }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5).delay(0.25)) { pop = 1 }
        burst = true
        Task {
            await sleep(seconds: 0.6)
            burst = false
        }
    }
}

/** Six 4 pt squares flying out of the heart. */
private struct HeartBurst: View {
    @State private var out = false
    private static let dirs: [CGSize] = [
        CGSize(width: 0, height: -18), CGSize(width: 15, height: -9), CGSize(width: 15, height: 9),
        CGSize(width: 0, height: 18), CGSize(width: -15, height: 9), CGSize(width: -15, height: -9),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Rectangle().fill(Omp.like)
                    .frame(width: 4, height: 4)
                    .scaleEffect(out ? 0.4 : 1)
                    .offset(out ? Self.dirs[i] : .zero)
                    .opacity(out ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.55)) { out = true } }
        .allowsHitTesting(false)
    }
}

/**
 * The volume slider: a 3 pt #333 track, #F5F5F5 fill, a 10 pt round knob.
 * Tap or drag; the value is reported when the finger lifts.
 */
struct VolumeSlider: View {
    let fraction: Double
    let onDone: (Double) -> Void
    @State private var drag: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let f = min(max(drag ?? fraction, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(Omp.edge).frame(height: 3)
                Rectangle().fill(Omp.foreground).frame(width: w * f, height: 3)
                Circle().fill(Omp.foreground).frame(width: 10, height: 10)
                    .scaleEffect(drag != nil ? 1.15 : 1)
                    .offset(x: min(max(w * f - 5, 0), w - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in drag = min(max(v.location.x / w, 0), 1) }
                    .onEnded { v in
                        drag = nil
                        onDone(min(max(v.location.x / w, 0), 1))
                    }
            )
        }
        .frame(height: 24)
    }
}

/**
 * The seek bar as the desktop draws it: forty bars whose heights come from the
 * song's ids (the same seed and envelope as ui/main.ts drawWaveform), white up
 * to the playhead, #333 after it, and a 2 pt white playhead line.
 */
struct WaveSeek: View {
    let key: String
    let fraction: Double
    var enabled = true
    var loading = false
    let onSeek: (Double) -> Void
    @State private var drag: Double? = nil

    static func heights(_ key: String, count: Int = 40) -> [Double] {
        var seed: UInt32 = 2166136261
        for unit in key.utf16 { seed = (seed ^ UInt32(unit)) &* 16777619 }
        var out: [Double] = []
        for i in 0..<count {
            seed = seed &* 1664525 &+ 1013904223
            let envelope = 0.42 + 0.58 * sin(Double(i) / Double(max(1, count - 1)) * Double.pi)
            let h = ((18 + Double(seed) / Double(UInt32.max) * 82) * envelope).rounded()
            out.append(h / 100)
        }
        return out
    }

    var body: some View {
        let bars = Self.heights(key)
        let shown: Double = min(max(drag ?? fraction, 0), 1)
        GeometryReader { geo in
            let layout = WaveLayout(width: geo.size.width, height: geo.size.height, count: bars.count)
            ZStack(alignment: .leading) {
                WaveBars(bars: bars, layout: layout, fraction: shown)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Omp.foreground)
                    .frame(width: 2, height: layout.height)
                    .offset(x: layout.playhead(shown))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in if enabled { drag = layout.fraction(at: v.location.x) } }
                    .onEnded { v in
                        guard enabled else { return }
                        drag = nil
                        onSeek(layout.fraction(at: v.location.x))
                    }
            )
        }
        .frame(height: 26)
        .opacity(loading ? 0.55 : 1)
    }
}

/** Where the waveform's bars sit in its box. */
private struct WaveLayout {
    let width: CGFloat
    let height: CGFloat
    let count: Int
    let gap: CGFloat = 2

    var barWidth: CGFloat {
        let n = CGFloat(max(count, 1))
        let room: CGFloat = max(width, 1) - gap * (n - 1)
        return max(1, min(4, room / n))
    }

    var used: CGFloat {
        let n = CGFloat(max(count, 1))
        return barWidth * n + gap * (n - 1)
    }

    var left: CGFloat { (max(width, 1) - used) / 2 }

    func playhead(_ f: Double) -> CGFloat {
        let x: CGFloat = used * CGFloat(f) - 1
        return left + min(max(x, 0), used - 2)
    }

    func fraction(at x: CGFloat) -> Double {
        let t: CGFloat = (x - left) / max(used, 1)
        return Double(min(max(t, 0), 1))
    }
}

private struct WaveBars: View {
    let bars: [Double]
    let layout: WaveLayout
    let fraction: Double

    var body: some View {
        HStack(alignment: .center, spacing: layout.gap) {
            ForEach(0..<bars.count, id: .self) { i in
                bar(i)
            }
        }
        .frame(width: layout.used, height: layout.height)
    }

    private func bar(_ i: Int) -> some View {
        let done: Bool = (Double(i) + 0.5) / Double(bars.count) <= fraction
        let h: CGFloat = max(2, layout.height * CGFloat(bars[i]))
        return Rectangle()
            .fill(done ? Omp.foreground : Omp.edge)
            .frame(width: layout.barWidth, height: h)
    }
}

/** The desktop's settings switch: a 42 x 24 square track, a 14 pt square knob. */
struct SquareSwitch: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Rectangle().fill(on ? Omp.themeAccent : Color(hex: 0x2D2D2D))
            Rectangle().fill(Color(hex: 0xE6E6E6)).frame(width: 14, height: 14).padding(4)
        }
        .frame(width: 42, height: 24)
        .overlay(Rectangle().strokeBorder(on ? Omp.themeAccent : Color(hex: 0x3A3A3A), lineWidth: 1))
        .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.16), value: on)
    }
}
