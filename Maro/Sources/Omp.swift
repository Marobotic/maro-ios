import SwiftUI
import UIKit

/**
 * One-to-one translation of Jukebox's design tokens, the
 * same ones the Android app uses.
 *
 * Colour values come from the plugin's Color.qml defaults and Panel.qml:
 *   foreground #cacccc, background #101315, urgent #a55555, muted #707880,
 *   spotify #1DB954, ytm #FF0033, maro #8A63D2.
 * Sizes mirror Style.space(n) at scale 1.0 and Style.font sizes
 * (caption 10, bodySmall 11, body 12, subtitle 13).
 */
enum Omp {
    static let background = Color(hex: 0x101315)
    static let foreground = Color(hex: 0xCACCCC)
    static let accent = Color(hex: 0xCACCCC)
    static let like = Color(hex: 0xE05263)
    static let urgent = Color(hex: 0xA55555)
    static let muted = Color(hex: 0x707880)
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

    /** Accent of the running Omarchy theme (Dotrb). */
    static let themeAccent = Color(hex: 0xB14242)

    static let card = Color(hex: 0x16191D)
    static let cardRaised = foreground.opacity(0.06)
    static let softDk = Color(hex: 0x2A2F35)

    /** Qt.darker(foreground, 2.6): the slider track. */
    static let sliderTrack = Color(hex: 0x4E4E4E)

    static let borderColor = foreground.opacity(0.40)
    static let normalFill = foreground.opacity(0.04)
    static let selectedFill = foreground.opacity(0.18)

    static let labelGap: CGFloat = 6
    static let spacing: CGFloat = 8
    static let panelSpacing: CGFloat = 14
    static let gatesGap: CGFloat = 24
    static let rowButton: CGFloat = 26
    static let queueMarkWidth: CGFloat = 18
    static let rowArt: CGFloat = 30
    static let nowArt: CGFloat = 68
    static let panelWidth: CGFloat = 420

    enum TypeSize {
        static let caption: CGFloat = 10
        static let bodySmall: CGFloat = 11
        static let body: CGFloat = 12
        static let subtitle: CGFloat = 13
        static let title: CGFloat = 13
        static let display: CGFloat = 18
    }

    /** The bar's monospace font, bundled so the Nerd Font glyphs actually render. */
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "JetBrainsMonoNF-Bold" : "JetBrainsMonoNF-Regular", fixedSize: size)
    }

    enum Icons {
        static let play = "\u{F04B}"
        static let pause = "\u{F04C}"
        static let prev = "\u{F04A}"
        static let next = "\u{F04E}"
        static let restart = "\u{F048}"
        static let clear = "\u{F014}"
        static let refresh = "\u{F021}"
        static let back = "\u{F177}"
        static let close = "\u{F00D}"
        static let note = "\u{F001}"
        static let list = "\u{F03A}"
        static let add = "\u{F067}"
        static let like = "\u{F08A}"
        static let likeFull = "\u{F004}"
        static let check = "\u{F00C}"
        static let volHigh = "\u{F028}"
        static let volLow = "\u{F027}"
        static let volMute = "\u{F026}"
        static let more = "\u{22EE}"
        static let signin = "\u{F090}"
        static let spotify = "\u{F1BC}"
        static let ytm = "\u{F16A}"
        static let sc = "\u{F1BE}"
        static let gear = "\u{F013}"
        static let bell = "\u{F0F3}"
        static let cloud = "\u{F0C2}"
        static let link = "\u{F0C1}"
        static let shuffle = "\u{F074}"
        static let `repeat` = "\u{F01E}"
        static let repeat1 = "\u{F0E2}"
        static let grid = "\u{F0C7}"
        static let wifi = "\u{F012}"
        static let warning = "\u{F071}"
        static let trash = "\u{F1F8}"
        static let edit = "\u{F044}"
        static let paintbrush = "\u{F1FC}"
        static let broadcast = "\u{F1EB}"
        static let question = "\u{F059}"
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
        default: return accent
        }
    }

    static func sourceIcon(_ src: String) -> String {
        switch src {
        case "spotify": return Icons.spotify
        case "ytm": return Icons.ytm
        case "sc": return Icons.sc
        default: return Icons.note
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
