import SwiftUI
import UIKit

/**
 * The design tokens of the Windows app's redesign (ui/app.css :root): a
 * near-black page, #121212 tiles with a #242424 hairline, #A0A0A0 / #8C8C8C
 * secondary text and the red accent #B14242. Square corners everywhere;
 * menus and popovers 4 pt. Sizes are the desktop's px at phone width, 1:1.
 */
enum Omp {
    // Surfaces
    static let page = Color(hex: 0x0D0D0D)
    static let tile = Color(hex: 0x121212)
    static let line = Color(hex: 0x242424)
    static let raise = Color(hex: 0x1A1A1A)
    static let hover = Color(hex: 0x1F1F1F)
    static let pill = Color(hex: 0x262626)
    static let row = Color(hex: 0x161616)
    static let popup = Color(hex: 0x141414)
    static let edge = Color(hex: 0x333333)
    // Text
    static let t2 = Color(hex: 0xA0A0A0)
    static let t3 = Color(hex: 0x8C8C8C)
    static let iconTint = Color(hex: 0xB3B3B3)
    static let soft = Color(hex: 0xFF9494)
    static let danger = Color(hex: 0xFF8A8A)
    static let headRed = Color(hex: 0xE06C6C)
    static let ok = Color(hex: 0x4A8B8B)

    static let background = page
    static let foreground = Color(hex: 0xF5F5F5)
    /** The neutral highlight (spinners, selected text); the red accent is `themeAccent`. */
    static let accent = Color(hex: 0xF5F5F5)
    static let like = Color(hex: 0xE05263)
    static let urgent = Color(hex: 0xE06C6C)
    static let muted = Color(hex: 0x949494)
    static let spotify = Color(hex: 0x1DB954)
    static let ytm = Color(hex: 0xFF0033)
    static let sc = Color(hex: 0xFF5500)
    static let maro = Color(hex: 0x8A63D2)
    // The playing copy's bitrate against the tier chosen in Settings: at it,
    // or below it while the droplet fetches it. The same colours as desktop.
    static let qualityGood = Color(hex: 0x6FBF73)
    static let qualityWait = Color(hex: 0xE0B252)

    /**
     * The one colour scale for a bitrate, wherever one is shown: how good the
     * number is, whichever service it came from. Same steps on every client.
     */
    private static let kbpsScale: [(Int, Color)] = [
        (320, Color(hex: 0x4FD1C5)),   // Spotify 320 and up
        (256, Color(hex: 0x6FBF73)),   // very high
        (192, Color(hex: 0xA5C85A)),   // high
        (128, Color(hex: 0xE0B252)),   // normal
        (96, Color(hex: 0xE8833A)),    // low
        (1, Color(hex: 0xE5534B)),     // very low
    ]

    static func kbpsColor(_ kbps: Int) -> Color {
        kbpsScale.first { kbps >= $0.0 }?.1 ?? muted
    }

    /** The redesign's red accent. */
    static let themeAccent = Color(hex: 0xB14242)
    /** The mockup's red: the saved check and a page's kind label. */
    static let markRed = Color(hex: 0xE5323F)
    /** Outlined buttons' border. */
    static let outline = Color(hex: 0x2A2A2A)
    /** An album page's artist links. */
    static let link = Color(hex: 0x6FC3B2)

    static let card = row
    static let cardRaised = raise
    static let softDk = edge
    static let sliderTrack = edge
    static let borderColor = edge
    static let normalFill = foreground.opacity(0.04)
    static let selectedFill = pill

    static let labelGap: CGFloat = 6
    static let spacing: CGFloat = 8
    static let panelSpacing: CGFloat = 14
    static let gatesGap: CGFloat = 24
    static let rowButton: CGFloat = 26
    static let queueMarkWidth: CGFloat = 18
    static let rowArt: CGFloat = 44
    static let nowArt: CGFloat = 56
    static let panelWidth: CGFloat = 420

    enum TypeSize {
        static let caption: CGFloat = 10
        static let bodySmall: CGFloat = 11
        static let body: CGFloat = 12
        static let subtitle: CGFloat = 13
        static let title: CGFloat = 13
        static let display: CGFloat = 18
    }

    /** JetBrains Mono, bundled: the desktop's "JB" face. */
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "JetBrainsMonoNF-Bold" : "JetBrainsMonoNF-Regular", fixedSize: size)
    }

    /** The name picked under Settings > Device name; blank means the default. */
    static var customPhoneName = ""

    /** What this phone is called in device lists. */
    static var phoneName: String { customPhoneName.ifBlank(defaultPhoneName) }

    /**
     * The name before anyone renames it. iOS only hands apps the generic
     * "iPhone" for the device name, so use the model instead.
     */
    static let defaultPhoneName: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let models = [
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,7": "iPhone 14", "iPhone15,4": "iPhone 15", "iPhone17,3": "iPhone 16",
        ]
        return models[machine] ?? UIDevice.current.model
    }()

    /** Where audio is really coming from, for the meta line under the title. */
    static func originLabel(_ origin: String) -> String {
        switch origin {
        case "spotify": return "Spotify"
        case "offline": return "Offline"
        case "ytm": return "YouTube Music"
        case "ytm-guest": return "YouTube · guest"
        // "phone" says nothing: this phone playing is the normal case, and the
        // line under the title is for where the audio comes from otherwise.
        case "phone": return ""
        default: return ""
        }
    }

    static func sourceLabel(_ src: String) -> String {
        switch src {
        case "spotify": return "Spotify"
        case "ytm": return "YouTube Music"
        case "sc": return "SoundCloud"
        default: return src.isBlank ? "Queue" : src
        }
    }

    static func sourceColor(_ src: String) -> Color {
        switch src {
        case "spotify": return spotify
        case "ytm": return ytm
        case "sc": return sc
        default: return themeAccent
        }
    }

    static func sourceGlyph(_ src: String) -> Glyph {
        switch src {
        case "spotify": return .spotify
        case "ytm": return .ytm
        case "sc": return .sc
        default: return .note
        }
    }

    static let qualityOptions: [(String, String)] = [
        ("low", "Low  ·  ~64 kbps"),
        ("normal", "Normal  ·  ~128 kbps"),
        ("high", "High  ·  ~137 kbps"),
        ("max", "Very high  ·  up to 256 kbps"),
    ]

    /// Streaming has one tier more: Spotify at 320, YouTube's best as the fallback.
    static let streamQualityOptions: [(String, String)] = qualityOptions + [("spotify", "Spotify  ·  320 kbps")]

    static let sourceOptions: [(String, String)] = [
        ("auto", "Whichever is available"),
        ("spotify", "Prefer Spotify  ·  320 kbps"),
        ("ytm", "Prefer YouTube Music"),
        ("sc", "Prefer SoundCloud"),
    ]

    static func fmtTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func fmtBytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        let units: [(Double, String)] = [(1024, "KB"), (1_048_576, "MB"), (1_073_741_824, "GB"), (1_099_511_627_776, "TB")]
        for (i, (div, unit)) in units.enumerated() where i == units.count - 1 || Double(n) < div * 1024 {
            return String(format: "%.1f %@", Double(n) / div, unit)
        }
        return "\(n) B"
    }

    static func agoText(_ ts: Int64) -> String {
        if ts <= 0 { return "" }
        let secs = max(0, Int64(Date().timeIntervalSince1970) - ts)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    /**
     * A Spotify link for one song: the exact track when its id is known, a
     * Spotify search for the title and artist when it is not, so a YouTube
     * Music song still gets a link that lands on the right record.
     */
    static func spotifyShareUrl(id: String, query: String) -> String {
        if !id.isEmpty { return "https://open.spotify.com/track/\(id)" }
        if !query.isEmpty { return "https://open.spotify.com/search/" + urlEncode(query) }
        return ""
    }

    /** The same idea for YouTube Music. */
    static func youtubeShareUrl(videoId: String, query: String) -> String {
        if !videoId.isEmpty { return "https://music.youtube.com/watch?v=\(videoId)" }
        if !query.isEmpty { return "https://music.youtube.com/search?q=" + urlEncode(query) }
        return ""
    }

    /// Percent-encodes a whole UTF-8 string, which is what a search path wants.
    private static func urlEncode(_ s: String) -> String {
        var out = ""
        for b in Array(s.utf8) { out += String(format: "%%%02X", b) }
        return out
    }
}

/** Everything on screen is sized for a 420 pt panel and scaled to the column it sits in. */
struct OmpMetrics: Equatable {
    var scale: CGFloat = 1
    func pt(_ v: CGFloat) -> CGFloat { v * scale }
}

private struct OmpMetricsKey: EnvironmentKey {
    static let defaultValue = OmpMetrics()
}

extension EnvironmentValues {
    var omp: OmpMetrics {
        get { self[OmpMetricsKey.self] }
        set { self[OmpMetricsKey.self] = newValue }
    }
}

extension Color {
    /** CSS color-mix(in srgb, a t, b): a share t of a, the rest b. */
    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let k = CGFloat(t)
        return Color(.sRGB, red: Double(ar * k + br * (1 - k)), green: Double(ag * k + bg * (1 - k)),
                     blue: Double(ab * k + bb * (1 - k)), opacity: Double(aa * k + ba * (1 - k)))
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func ifEmpty(_ other: @autoclosure () -> String) -> String { isEmpty ? other() : self }
    func ifBlank(_ other: @autoclosure () -> String) -> String { isBlank ? other() : self }
}
