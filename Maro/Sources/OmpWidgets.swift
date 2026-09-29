import SwiftUI
import UIKit

/** Monospace text in the plugin's palette. */
struct OmpText: View {
    @Environment(\.omp) private var m
    let text: String
    var size: CGFloat = Omp.TypeSize.body
    var color: Color = Omp.foreground
    var bold = false
    var maxLines = 1
    var align: TextAlignment = .leading

    init(_ text: String, size: CGFloat = Omp.TypeSize.body, color: Color = Omp.foreground, bold: Bool = false, maxLines: Int = 1, align: TextAlignment = .leading) {
        self.text = text
        self.size = size
        self.color = color
        self.bold = bold
        self.maxLines = maxLines
        self.align = align
    }

    var body: some View {
        Text(text)
            .font(Omp.font(m.pt(size), bold: bold))
            .foregroundColor(color)
            .lineLimit(maxLines)
            .truncationMode(.tail)
            .multilineTextAlignment(align)
    }
}

/** A Nerd Font glyph (play, heart, spotify logo, ...). */
struct OmpIcon: View {
    @Environment(\.omp) private var m
    let icon: String
    var size: CGFloat = Omp.TypeSize.body
    var color: Color = Omp.foreground

    init(_ icon: String, size: CGFloat = Omp.TypeSize.body, color: Color = Omp.foreground) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    var body: some View {
        // Nerd Font glyphs draw wider than their advance; a box a bit wider
        // than the font size keeps the logos from being cut in half.
        Text(icon)
            .font(Omp.font(m.pt(size)))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: m.pt(size) * 1.3)
    }
}

/** Rotating refresh glyph - the plugin's "waiting" spinner. */
struct OmpSpinner: View {
    var size: CGFloat = Omp.TypeSize.caption
    var color: Color = Omp.accent
    @State private var spinning = false

    var body: some View {
        OmpIcon(Omp.Icons.refresh, size: size, color: color)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/** The shared in-panel button: glyph + label, selected state, optional border. */
struct OmpButton: View {
    @Environment(\.omp) private var m
    var icon = ""
    var text = ""
    var selected = false
    var enabled = true
    var foreground: Color = Omp.foreground
    var fontSize: CGFloat = Omp.TypeSize.body
    var vertical: CGFloat = 4
    var horizontal: CGFloat = 8
    var bordered = false
    let action: () -> Void

    var body: some View {
        let tint = enabled ? foreground : foreground.opacity(0.35)
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        Button(action: action) {
            HStack(spacing: m.pt(7)) {
                if !icon.isEmpty { OmpIcon(icon, size: fontSize, color: tint) }
                if !text.isEmpty { OmpText(text, size: fontSize, color: tint) }
            }
            .padding(.horizontal, m.pt(horizontal))
            .padding(.vertical, m.pt(vertical))
            .background(selected ? Omp.selectedFill : Color.clear, in: shape)
            .overlay { if bordered { shape.stroke(tint.opacity(0.40), lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/** Single-line text input matching the panel's TextField. */
struct OmpTextField: View {
    @Environment(\.omp) private var m
    @Binding var text: String
    var placeholder = ""
    var password = false
    var keyboard: UIKeyboardType = .default
    var onSubmit: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        ZStack(alignment: .leading) {
            if text.isEmpty { OmpText(placeholder, color: Omp.muted) }
            Group {
                if password {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text).keyboardType(keyboard)
                }
            }
            .font(Omp.font(m.pt(Omp.TypeSize.body)))
            .foregroundColor(Omp.foreground)
            .tint(Omp.accent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(onSubmit != nil ? .go : .next)
            .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, m.pt(8))
        .frame(height: m.pt(34))
        .background(Omp.cardRaised, in: shape)
        .overlay(shape.stroke(Omp.borderColor, lineWidth: 1))
    }
}

/**
 * The panel's slim slider: a 3pt track, accent fill, small knob. Tap or drag;
 * the value is only reported when the finger lifts, like the panel's.
 */
struct OmpSlider: View {
    @Environment(\.omp) private var m
    let fraction: Double
    var enabled = true
    var glow: Double = 1
    let onDone: (Double) -> Void
    @State private var drag: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let f = min(max(drag ?? fraction, 0), 1)
            let thin = m.pt(3), knob = m.pt(6)
            let fill = Omp.accent.opacity(min(max(glow, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Omp.sliderTrack).frame(height: thin)
                Capsule().fill(fill).frame(width: w * f, height: thin)
                Circle().fill(fill).frame(width: knob, height: knob)
                    .offset(x: min(max(w * f - knob / 2, 0), w - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in if enabled { drag = min(max(v.location.x / w, 0), 1) } }
                    .onEnded { v in
                        guard enabled else { return }
                        drag = nil
                        onDone(min(max(v.location.x / w, 0), 1))
                    }
            )
        }
        .frame(height: m.pt(22))
    }
}

/** A cover from the droplet or the provider CDN, falling back to a source glyph. */
struct CoverArt: View {
    @Environment(\.omp) private var m
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var loader = ArtLoader.shared
    let artKey: String
    let artUrl: String
    let icon: String
    let size: CGFloat
    var radius: CGFloat = Omp.labelGap
    var busy = false
    @State private var image: UIImage? = nil

    var body: some View {
        let side = m.pt(size)
        let px = Int((side * displayScale).rounded())
        let key = loader.key(artKey: artKey, artUrl: artUrl, px: px)
        ZStack {
            Omp.normalFill
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if busy {
                OmpSpinner(size: Omp.TypeSize.bodySmall, color: Omp.muted)
            } else {
                OmpIcon(icon, size: Omp.TypeSize.bodySmall)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: m.pt(radius)))
        .task(id: "\(key)#\(loader.epoch)") {
            image = loader.cached(key)
            guard image == nil, !key.isEmpty else { return }
            for attempt in 0..<3 {
                if let got = await loader.load(artKey: artKey, artUrl: artUrl, px: px) {
                    image = got
                    return
                }
                if Task.isCancelled { return }
                if attempt < 2 { await sleep(seconds: 0.7 * Double(attempt + 1)) }
            }
        }
    }
}

/** The heart: outline when unliked, accent when liked. */
struct HeartButton: View {
    @Environment(\.omp) private var m
    let liked: Bool
    var size: CGFloat = Omp.rowButton
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OmpIcon(liked ? Omp.Icons.likeFull : Omp.Icons.like, size: Omp.TypeSize.body, color: liked ? Omp.like : Omp.foreground)
                .frame(width: m.pt(size), height: m.pt(size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
