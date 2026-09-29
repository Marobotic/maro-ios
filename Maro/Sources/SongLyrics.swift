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
        let lines = arr.compactMap { $0 as? JSON }.map { LyricLine(t: $0.double("t", -1), text: $0.str("text")) }
        return SongLyrics(trackId: trackId, lines: lines, synced: o.bool("synced") && !lines.isEmpty, source: o.str("source"))
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
