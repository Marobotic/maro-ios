import Foundation

/**
 * Telling whether two rows from different services are the same song: the
 * desktop engine's norm_words / word_overlap / VERSION_WORDS, so the phone
 * picks the same SoundCloud copy and merges the same search results.
 */
enum Match {
    static let noise: Set<String> = [
        "feat", "featuring", "ft", "with", "the", "a", "an", "official", "video",
        "audio", "lyrics", "lyric", "hd", "hq", "remaster", "remastered", "version",
        "explicit", "radio", "edit", "mix",
    ]

    /** Words that make a recording a different version of the song its title names. */
    static let versionWords = ["remix", "edit", "cover", "bootleg", "flip", "mashup", "sped up",
                               "slowed", "nightcore", "instrumental", "acapella", "a cappella",
                               "live", "rework", "vip", "karaoke", "8d", "extended", "acoustic",
                               "demo"]

    private static func alnum(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /** Comparable word set: lowercase, bracketed asides and "feat. ..." removed. */
    static func words(_ text: String) -> Set<String> {
        var t = text.lowercased()
        // Spotify's " - 2004 Remaster", " - Remastered 2011", " - Mono": the
        // same recording, which YouTube Music titles without it.
        t = t.replacingOccurrences(of: #"\s+-\s+[^-]*\b(remaster|remastered|mono|stereo)\b[^-]*$"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(feat|ft|featuring)\b.*"#, with: " ", options: .regularExpression)
        let all = alnum(t)
        let kept = all.filter { !noise.contains($0) }
        return Set(kept.isEmpty ? all : kept)
    }

    /** " word word " - for checking whole-word markers like " remix ". */
    static func spaced(_ text: String) -> String { " " + alnum(text).joined(separator: " ") + " " }

    static func versionMarks(_ title: String) -> Set<String> {
        let s = spaced(title)
        return Set(versionWords.filter { s.contains(" \($0) ") })
    }

    /** How much of `want` appears in `got`, 0...1. */
    static func overlap(_ want: Set<String>, _ got: Set<String>) -> Double {
        want.isEmpty ? 1 : Double(want.intersection(got).count) / Double(want.count)
    }

    /**
     * The same recording on two services: the titles agree, the artists agree,
     * neither is a version the other is not, and the lengths are within a few
     * seconds when both are known.
     */
    static func sameSong(_ a: Track, _ b: Track) -> Bool {
        if versionMarks(a.title) != versionMarks(b.title) { return false }
        let ta = words(a.title), tb = words(b.title)
        guard overlap(ta, tb) >= 0.8 && overlap(tb, ta) >= 0.8 else { return false }
        let aa = words(a.artist), ab = words(b.artist)
        if !aa.isEmpty && !ab.isEmpty && overlap(aa, ab) < 0.5 && overlap(ab, aa) < 0.5 { return false }
        if a.duration > 0 && b.duration > 0 && abs(a.duration - b.duration) > 4 { return false }
        return true
    }
}
