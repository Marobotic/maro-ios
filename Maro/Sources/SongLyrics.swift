import Foundation

struct LyricLine: Equatable {
    let t: Double
    let text: String
}

/** One song's lyrics, as the desktop engine shapes them. */
struct SongLyrics: Equatable {
    var trackId = ""
    var lines: [LyricLine] = []
    var synced = false
    var source = ""
    var loading = false

    /** The line being sung at [position] seconds: the last that has started. */
    func indexAt(_ position: Double) -> Int {
        guard synced, !lines.isEmpty else { return -1 }
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].t <= position {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    static func from(_ trackId: String, _ o: JSON?) -> SongLyrics? {
        guard let arr = o?.arr("lines"), let o else { return nil }
        let raw = arr.compactMap { $0 as? JSON }.map { LyricLine(t: $0.double("t", -1), text: $0.str("text")) }
        let lines = o.bool("synced") ? raw : withoutPageText(raw)
        return SongLyrics(trackId: trackId, lines: lines, synced: o.bool("synced") && !lines.isEmpty, source: o.str("source"))
    }

    private static func matches(_ pattern: String, _ text: String, caseless: Bool = false) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : []) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let alsoLike = "You might also like"

    /**
     * Plain lyrics scraped from a Genius page carry the page's own text:
     * "19 Contributors", "Translations" and the languages, "<Title> Lyrics"
     * (and a "... Read More" blurb) glued before the first line, "You might
     * also like" between lines and "<N>Embed" after the last. Only those go;
     * a header is only taken off when it starts with the contributors count.
     * (Android's Lyrics.kt withoutPageText, line for line.)
     */
    static func withoutPageText(_ lines: [LyricLine]) -> [LyricLine] {
        if lines.isEmpty { return lines }
        var out = lines
        if matches(#"^\d+\s*Contributors?"#, out[0].text.trimmingCharacters(in: .whitespaces), caseless: true) {
            // The header block: the contributors line, any Translations /
            // "<Title> Lyrics" / "Read More" lines right after it.
            var i = 0
            var first = true
            while i < out.count && i < 4 {
                let t = out[i].text.trimmingCharacters(in: .whitespaces)
                let header = first || matches(#"^Translations?(?=\p{Lu}|\s|$)"#, t) || t.hasSuffix(" Lyrics") || t.hasSuffix("Read More")
                if !header { break }
                first = false
                // Real words glued after "... Lyrics" stay as the first line.
                var rest = ""
                if let at = t.range(of: "Lyrics", options: .backwards) {
                    rest = String(t[at.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                if !rest.isEmpty && !rest.hasSuffix("Read More") {
                    out[i] = LyricLine(t: out[i].t, text: rest)
                    i += 1
                    break
                }
                out.remove(at: i)
            }
        }
        // "You might also like" on its own line, or glued in front of the next one.
        var cleaned: [LyricLine] = out.compactMap { l in
            let t = l.text.trimmingCharacters(in: .whitespaces)
            if t == alsoLike { return nil }
            if t.hasPrefix(alsoLike) && t.count > alsoLike.count && t[t.index(t.startIndex, offsetBy: alsoLike.count)].isUppercase {
                return LyricLine(t: l.t, text: String(t.dropFirst(alsoLike.count)))
            }
            return l
        }
        // "42Embed" after the last line, alone or glued to it.
        if let lastLine = cleaned.last {
            let last = lastLine.text.trimmingCharacters(in: .whitespaces)
            if matches(#"\d*\s*Embed$"#, last) && (last == "Embed" || matches(#"\dEmbed$"#, last)) {
                let rest = last.replacingOccurrences(of: #"\d*\s*Embed$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    cleaned.removeLast()
                } else {
                    cleaned[cleaned.count - 1] = LyricLine(t: lastLine.t, text: rest)
                }
            }
        }
        return cleaned
    }

    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)]"#)

    /** An LRC file to lines, for the phone's own LRCLib fallback. */
    static func parseLrc(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let stamps = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = stamps.last else { continue }
            var words = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            if words == "♪" { words = "" }
            for m in stamps {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(t: min * 60 + sec, text: words))
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    static func plain(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(t: -1, text: $0) }
    }

    static func json(_ lines: [LyricLine], synced: Bool, source: String) -> JSON {
        ["synced": synced, "source": source, "lines": lines.map { ["t": $0.t, "text": $0.text] as JSON }]
    }
}
