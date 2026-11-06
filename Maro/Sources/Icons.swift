import SwiftUI

/**
 * The desktop's icons: the same inline SVG paths (24-unit viewBox, square
 * caps, miter joins), parsed once and drawn with Canvas, so every icon on the
 * phone is the very shape the Windows app draws, not an SF Symbol or a font
 * glyph.
 */
enum Glyph: Hashable {
    case info, wifi, gear, back, chevronUp, chevronDown, chevronRight
    case restart, prev, next, play, playSmall, pause
    case shuffle, shuffleAlt, repeatAll
    case volume, volumeLow, volumeMute, expand
    case trash, trashSmall, refresh, refreshAlt, addQueue, search, close, plus
    case heart, check, radio, download, link, bell
    case spotify, ytm, sc, cloud, clear, edit, warning, note, brush, user, disc
}

/** One piece of a glyph: drawn as a line, filled, or both (the desktop's fill + stroke polygons). */
private struct GlyphPart {
    let path: Path
    let fill: Bool
    let stroke: Bool
}

private struct GlyphSpec {
    let parts: [GlyphPart]
    let weight: CGFloat
}

private enum PartMode { case stroke, fill, both }

enum GlyphBook {
    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> String {
        "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(2 * r) 0a\(r) \(r) 0 1 0 \(-2 * r) 0Z"
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> String {
        "M\(x) \(y)h\(w)v\(h)h\(-w)Z"
    }

    static let heartD = "M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"
    private static let speaker = "M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3v8h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"
    private static let cloudD = "M7 18h11a4 4 0 0 0 .4-8A6.5 6.5 0 0 0 6 9.5 4.3 4.3 0 0 0 7 18Z"

    private static func raw(_ g: Glyph) -> ([(String, PartMode)], CGFloat) {
        switch g {
        case .info: return ([(circle(12, 12, 10), .stroke), ("M12 16v-4", .stroke), ("M12 8h.01", .stroke)], 2)
        case .wifi:
            return ([("M12 20h.01", .stroke), ("M2 8.82a15 15 0 0 1 20 0", .stroke),
                     ("M5 12.859a10 10 0 0 1 14 0", .stroke), ("M8.5 16.429a5 5 0 0 1 7 0", .stroke)], 2.2)
        case .gear:
            return ([("M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z", .stroke),
                     (circle(12, 12, 3), .stroke)], 2)
        case .back: return ([("m12 19-7-7 7-7", .stroke), ("M19 12H5", .stroke)], 2.2)
        case .chevronUp: return ([("m6 15 6-6 6 6", .stroke)], 2.2)
        case .chevronDown: return ([("m6 9 6 6 6-6", .stroke)], 2.2)
        case .chevronRight: return ([("m9 18 6-6-6-6", .stroke)], 2)
        case .restart: return ([("M19 20L9 12L19 4L19 20Z", .both), ("M5 19L5 5", .stroke)], 2)
        case .prev: return ([("M11 19L2 12L11 5L11 19Z", .both), ("M22 19L13 12L22 5L22 19Z", .both)], 1.5)
        case .next: return ([("M2 19L13 12L2 5L2 19Z", .both), ("M13 19L22 12L13 5L13 19Z", .both)], 1.5)
        case .play: return ([("M6 4L20 12L6 20Z", .fill)], 2)
        case .playSmall: return ([("M6 3L20 12L6 21L6 3Z", .fill)], 2)
        case .pause: return ([(rect(6, 4, 4, 16), .fill), (rect(14, 4, 4, 16), .fill)], 2)
        case .shuffle:
            return ([("M16 3L21 3L21 8", .stroke), ("M4 20L21 3", .stroke), ("M21 16L21 21L16 21", .stroke),
                     ("M15 15L21 21", .stroke), ("M4 4L9 9", .stroke)], 2)
        case .shuffleAlt:
            return ([("m18 14 4 4-4 4", .stroke), ("M18 2l4 4-4 4", .stroke),
                     ("M2 18h2.5a6 6 0 0 0 4.2-1.7L17.3 7.7A6 6 0 0 1 21.5 6H22", .stroke),
                     ("M2 6h2.5a6 6 0 0 1 4.2 1.7l1.4 1.4", .stroke),
                     ("m14.5 14.5 2.8 2.8a6 6 0 0 0 4.2 1.7h.5", .stroke)], 2)
        case .repeatAll:
            return ([("M17 1L21 5L17 9", .stroke), ("M3 11V9a4 4 0 0 1 4-4h14", .stroke),
                     ("M7 23L3 19L7 15", .stroke), ("M21 13v2a4 4 0 0 1-4 4H3", .stroke)], 2)
        case .volume: return ([(speaker, .stroke), ("M16 9a5 5 0 0 1 0 6", .stroke), ("M19.364 5.636a9 9 0 0 1 0 12.728", .stroke)], 2)
        case .volumeLow: return ([(speaker, .stroke), ("M16 9a5 5 0 0 1 0 6", .stroke)], 2)
        case .volumeMute: return ([(speaker, .stroke), ("M22 9L16 15", .stroke), ("M16 9L22 15", .stroke)], 2)
        case .expand:
            return ([("M15 3L21 3L21 9", .stroke), ("M9 21L3 21L3 15", .stroke),
                     ("M21 3L14 10", .stroke), ("M3 21L10 14", .stroke)], 2)
        case .trash:
            return ([("M3 6h18", .stroke), ("M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6", .stroke),
                     ("M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2", .stroke), ("M10 11L10 17", .stroke), ("M14 11L14 17", .stroke)], 2)
        case .trashSmall:
            return ([("M3 6h18", .stroke), ("M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6", .stroke),
                     ("M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2", .stroke)], 2)
        case .refresh:
            return ([("M20 7v5h-5", .stroke), ("M4 17v-5h5", .stroke),
                     ("M5.6 9a7 7 0 0 1 11.6-2L20 12M4 12l2.8 5a7 7 0 0 0 11.6-2", .stroke)], 2)
        case .refreshAlt: return ([("M21.5 2v6h-6M2.5 22v-6h6M2 11.5a10 10 0 0 1 18.8-4.3M22 12.5a10 10 0 0 1-18.8 4.3", .stroke)], 2)
        case .addQueue:
            return ([("M11 12H3", .stroke), ("M16 6H3", .stroke), ("M16 18H3", .stroke), ("M18 9v6", .stroke), ("M21 12h-6", .stroke)], 2)
        case .search: return ([(circle(11, 11, 8), .stroke), ("m21 21-4.3-4.3", .stroke)], 2)
        case .close: return ([("M18 6 6 18", .stroke), ("m6 6 12 12", .stroke)], 2.6)
        case .plus: return ([("M12 5v14", .stroke), ("M5 12h14", .stroke)], 2.2)
        case .heart: return ([(heartD, .stroke)], 2)
        case .check: return ([("M4 12.5 9.5 18 20 6.5", .stroke)], 3.4)
        case .radio: return ([(circle(12, 12, 9), .stroke), (circle(12, 12, 2), .stroke), ("M12 3v4", .stroke)], 2)
        case .download: return ([("M12 3v12m-5-5 5 5 5-5M5 21h14", .stroke)], 2)
        case .link:
            return ([("M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71", .stroke)], 2)
        case .bell: return ([("M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4", .stroke)], 2)
        case .spotify:
            return ([(circle(12, 12, 9), .stroke),
                     ("M6.5 9.5c4-1 7.4-.5 10.5 1M7 12.5c3.2-.7 6-.3 8.7.9M7.6 15.3c2.5-.5 4.7-.2 6.8.8", .stroke)], 2)
        case .ytm: return ([(rect(3, 5, 18, 14), .stroke), ("m10 9 5 3-5 3z", .fill)], 2)
        case .sc: return ([(cloudD, .stroke), ("M8 21h2m2-2v2m3-2v2", .stroke)], 2)
        case .cloud: return ([(cloudD, .stroke)], 2)
        case .clear: return ([("M3 6h18M19 6l-1 14H6L5 6M8 6V4h8v2M10 10v6M14 10v6", .stroke)], 2)
        // The desktop menus draw these from the font; drawn here in the same
        // stroke style so no font glyph is left.
        case .edit: return ([("M4 20h4L19 9l-4-4L4 16z", .stroke), ("M13 7l4 4", .stroke)], 2)
        case .warning: return ([("M12 3 2 21h20z", .stroke), ("M12 10v5", .stroke), ("M12 18h.01", .stroke)], 2)
        case .note: return ([("M9 18V5l12-2v13", .stroke), (circle(6, 18, 3), .stroke), (circle(18, 16, 3), .stroke)], 2)
        case .brush: return ([("M18 3l3 3-9 9-3-3z", .stroke), ("M9 12c-3 0-5 2-5 5 0 1-1 2-2 2 2 2 7 2 9-1 1-1.5 1-3.5 1-3", .stroke)], 2)
        case .user: return ([("M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2", .stroke), (circle(12, 7, 4), .stroke)], 2)
        case .disc: return ([(circle(12, 12, 10), .stroke), (circle(12, 12, 2), .stroke)], 2)
        }
    }

    private static var cache: [Glyph: GlyphSpec] = [:]

    fileprivate static func spec(_ g: Glyph) -> GlyphSpec {
        if let hit = cache[g] { return hit }
        let (parts, weight) = raw(g)
        let spec = GlyphSpec(parts: parts.map { d, mode in
            GlyphPart(path: SvgPath.parse(d), fill: mode != .stroke, stroke: mode != .fill)
        }, weight: weight)
        cache[g] = spec
        return spec
    }

    /** The heart's outline as a path in a 24-unit box, for shapes that need it. */
    static func path(_ g: Glyph) -> Path {
        var out = Path()
        for part in spec(g).parts { out.addPath(part.path) }
        return out
    }
}

/** A desktop icon at `size` points, stroked in `color` (`filled` also fills it, as a liked heart). */
struct Icon: View {
    let glyph: Glyph
    var size: CGFloat = 16
    var color: Color = Omp.t2
    var weight: CGFloat? = nil
    var filled = false

    init(_ glyph: Glyph, size: CGFloat = 16, color: Color = Omp.t2, weight: CGFloat? = nil, filled: Bool = false) {
        self.glyph = glyph
        self.size = size
        self.color = color
        self.weight = weight
        self.filled = filled
    }

    var body: some View {
        let spec = GlyphBook.spec(glyph)
        let width = weight ?? spec.weight
        let fillAll = filled
        Canvas { ctx, box in
            let k = box.width / 24
            let scale = CGAffineTransform(scaleX: k, y: k)
            let style = StrokeStyle(lineWidth: width * k, lineCap: .square, lineJoin: .miter)
            for part in spec.parts {
                let p = part.path.applying(scale)
                if part.fill || fillAll { ctx.fill(p, with: .color(color)) }
                if part.stroke { ctx.stroke(p, with: .color(color), style: style) }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/**
 * SVG path data to a SwiftUI Path: M L H V C S Q T A Z in both cases, implicit
 * repeats, the compact number forms (".5.5", "-1.2-.4", exponents) and arcs
 * converted to cubic curves.
 */
enum SvgPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d.utf8)
        let n = chars.count
        var i = 0
        var cmd: UInt8 = 0
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint? = nil
        var lastQuad: CGPoint? = nil

        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 44 || c == 9 || c == 10 || c == 13 }
        func skip() { while i < n && isSpace(chars[i]) { i += 1 } }
        func isLetter(_ c: UInt8) -> Bool {
            ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) && c != 101 && c != 69
        }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func number() -> CGFloat? {
            skip()
            let s = i
            if i < n && (chars[i] == 43 || chars[i] == 45) { i += 1 }
            var digits = false
            var dot = false
            while i < n {
                let c = chars[i]
                if isDigit(c) {
                    digits = true
                    i += 1
                } else if c == 46 && !dot {
                    dot = true
                    i += 1
                } else {
                    break
                }
            }
            if digits && i < n && (chars[i] == 101 || chars[i] == 69) {
                var j = i + 1
                if j < n && (chars[j] == 43 || chars[j] == 45) { j += 1 }
                if j < n && isDigit(chars[j]) {
                    i = j
                    while i < n && isDigit(chars[i]) { i += 1 }
                }
            }
            if !digits {
                i = s
                return nil
            }
            let text = String(decoding: chars[s..<i], as: UTF8.self)
            return CGFloat(Double(text) ?? 0)
        }
        func flag() -> Bool? {
            skip()
            guard i < n else { return nil }
            let c = chars[i]
            if c == 48 || c == 49 {
                i += 1
                return c == 49
            }
            return nil
        }

        while true {
            skip()
            if i >= n { break }
            if isLetter(chars[i]) {
                cmd = chars[i]
                i += 1
            } else if cmd == 0 || cmd == UInt8(ascii: "Z") || cmd == UInt8(ascii: "z") {
                break
            }
            let rel = cmd >= 97
            let up = rel ? cmd - 32 : cmd
            let base = rel ? cur : .zero
            var ok = true
            switch up {
            case UInt8(ascii: "M"):
                if let x = number(), let y = number() {
                    cur = CGPoint(x: base.x + x, y: base.y + y)
                    start = cur
                    path.move(to: cur)
                    cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
                } else { ok = false }
                lastCubic = nil
                lastQuad = nil
            case UInt8(ascii: "L"):
                if let x = number(), let y = number() {
                    cur = CGPoint(x: base.x + x, y: base.y + y)
                    path.addLine(to: cur)
                } else { ok = false }
                lastCubic = nil
                lastQuad = nil
            case UInt8(ascii: "H"):
                if let x = number() {
                    cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y)
                    path.addLine(to: cur)
                } else { ok = false }
                lastCubic = nil
                lastQuad = nil
            case UInt8(ascii: "V"):
                if let y = number() {
                    cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y)
                    path.addLine(to: cur)
                } else { ok = false }
                lastCubic = nil
                lastQuad = nil
            case UInt8(ascii: "C"):
                if let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() {
                    let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
                    let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                    cur = CGPoint(x: base.x + x, y: base.y + y)
                    path.addCurve(to: cur, control1: c1, control2: c2)
                    lastCubic = c2
                } else { ok = false }
                lastQuad = nil
            case UInt8(ascii: "S"):
                if let x2 = number(), let y2 = number(), let x = number(), let y = number() {
                    let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                    cur = CGPoint(x: base.x + x, y: base.y + y)
                    path.addCurve(to: cur, control1: c1, control2: c2)
                    lastCubic = c2
                } else { ok = false }
                lastQuad = nil
            case UInt8(ascii: "Q"):
                if let x1 = number(), let y1 = number(), let x = number(), let y = number() {
                    let c = CGPoint(x: base.x + x1, y: base.y + y1)
                    cur = CGPoint(x: base.x + x, y: base.y + y)
                    path.addQuadCurve(to: cur, control: c)
                    lastQuad = c
                } else { ok = false }
                lastCubic = nil
            case UInt8(ascii: "T"):
                if let x = number(), let y = number() {
                    let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    cur = CGPoint(x: base.x + x, y: base.y + y)
                    path.addQuadCurve(to: cur, control: c)
                    lastQuad = c
                } else { ok = false }
                lastCubic = nil
            case UInt8(ascii: "A"):
                if let rx = number(), let ry = number(), let rot = number(), let large = flag(), let sweep = flag(),
                   let x = number(), let y = number() {
                    let to = CGPoint(x: base.x + x, y: base.y + y)
                    arc(&path, from: cur, rx: rx, ry: ry, degrees: rot, large: large, sweep: sweep, to: to)
                    cur = to
                } else { ok = false }
                lastCubic = nil
                lastQuad = nil
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                cur = start
                lastCubic = nil
                lastQuad = nil
            default:
                ok = false
            }
            if !ok { break }
        }
        return path
    }

    /** An SVG elliptical arc (endpoint form) as cubic curves of at most 90 degrees each. */
    private static func arc(_ path: inout Path, from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, degrees: CGFloat,
                            large: Bool, sweep: Bool, to p: CGPoint) {
        if p0 == p { return }
        var rx = abs(rx0)
        var ry = abs(ry0)
        if rx == 0 || ry == 0 {
            path.addLine(to: p)
            return
        }
        let phi = Double(degrees) * Double.pi / 180
        let cs = CGFloat(cos(phi))
        let sn = CGFloat(sin(phi))
        let dx2 = (p0.x - p.x) / 2
        let dy2 = (p0.y - p.y) / 2
        let x1p = cs * dx2 + sn * dy2
        let y1p = -sn * dx2 + cs * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let k = sqrt(lambda)
            rx *= k
            ry *= k
        }
        let rx2 = rx * rx
        let ry2 = ry * ry
        let num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coef: CGFloat = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cs * cxp - sn * cyp + (p0.x + p.x) / 2
        let cy = sn * cxp + cs * cyp + (p0.y + p.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 {
            delta -= 2 * .pi
        } else if sweep && delta < 0 {
            delta += 2 * .pi
        }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + cs * rx * x - sn * ry * y, y: cy + sn * rx * x + cs * ry * y)
        }
        var theta = theta1
        for _ in 0..<segments {
            let c1 = cos(theta), s1 = sin(theta)
            let theta2 = theta + step
            let c2 = cos(theta2), s2 = sin(theta2)
            path.addCurve(to: map(c2, s2),
                          control1: map(c1 - t * s1, s1 + t * c1),
                          control2: map(c2 + t * s2, s2 - t * c2))
            theta = theta2
        }
    }
}
