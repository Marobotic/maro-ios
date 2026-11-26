import Combine
import Foundation

/**
 * One entry of the playback log (round 2 M.1): when, how bad, what wrote it,
 * the service it is about, the song, and longer details shown when opened.
 */
struct ConsoleEntry: Identifiable, Equatable {
    enum Level: String {
        case error = "E", warning = "W", info = "I"
        var label: String { self == .error ? "Error" : self == .warning ? "Warning" : "Info" }
    }

    let id: Int
    let at: Double
    let level: Level
    /** What wrote it: Playback, Player, Spotify, Devices, Network, MaroClient... */
    let area: String
    /** spotify, ytm, sc or jukebox (the server, this phone, the app). */
    let source: String
    let message: String
    /** "Title - Artist" of the song it is about, empty when none. */
    var song = ""
    /** The song's "source:id". */
    var songKey = ""
    var details = ""

    var line: String { ConsoleLog.line(self) }
}

/**
 * The playback log: every play, the source chosen and why, the stream, starts,
 * stalls, interruptions, network changes, errors with their exact text, skips
 * and stops. The last 2000 entries are kept on disk across restarts (one JSON
 * line each). Request bodies, keyed addresses and credentials never go in here.
 */
final class ConsoleLog: ObservableObject {
    static let shared = ConsoleLog()
    static let capacity = 2000

    @Published private(set) var entries: [ConsoleEntry] = []
    private let lock = NSLock()
    private var stored: [ConsoleEntry] = []
    private var nextId = 1
    private var fileLines = 0
    private let disk = DispatchQueue(label: "console-log")
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("console.jsonl")
    }()

    private static let clock: DateFormatter = formatter("HH:mm:ss")
    private static let stamp: DateFormatter = formatter("yyyy-MM-dd HH:mm:ss.SSS")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private init() {
        // What the last runs kept.
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let all = text.split(separator: "\n")
        stored = all.suffix(Self.capacity).compactMap { Self.parse(String($0)) }
        fileLines = all.count
        nextId = (stored.map(\.id).max() ?? 0) + 1
        entries = stored
        if all.count > Self.capacity { disk.async { self.compact() } }
    }

    /** The old call: an info line, or a warning when it reads like a failure. */
    @discardableResult
    func log(_ tag: String, _ message: String) -> Int {
        let m = message.lowercased()
        let failure = ["failed", "refused", "timed out", "timeout", "http 4", "http 5", "could not", "unavailable", "did not"]
            .contains { m.contains($0) }
        return add(failure ? .warning : .info, tag, Self.sourceOf(tag), message)
    }

    @discardableResult
    func info(_ area: String, _ message: String, _ track: Track? = nil, source: String? = nil, details: String = "") -> Int {
        add(.info, area, source ?? Self.serviceOf(track), message, track, details: details)
    }

    @discardableResult
    func warn(_ area: String, _ message: String, _ track: Track? = nil, source: String? = nil, details: String = "") -> Int {
        add(.warning, area, source ?? Self.serviceOf(track), message, track, details: details)
    }

    @discardableResult
    func error(_ area: String, _ message: String, _ track: Track? = nil, source: String? = nil, details: String = "") -> Int {
        add(.error, area, source ?? Self.serviceOf(track), message, track, details: details)
    }

    @discardableResult
    func add(_ level: ConsoleEntry.Level, _ area: String, _ source: String, _ message: String, _ track: Track? = nil, details: String = "") -> Int {
        lock.lock()
        let entry = ConsoleEntry(
            id: nextId,
            at: Date().timeIntervalSince1970,
            level: level,
            area: area,
            source: source.isEmpty ? "jukebox" : source,
            message: message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
            song: track.map(Self.songOf) ?? "",
            songKey: track.map(Self.keyOf) ?? "",
            details: details.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        nextId += 1
        stored.append(entry)
        if stored.count > Self.capacity { stored.removeFirst(stored.count - Self.capacity) }
        let snapshot = stored
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.entries = snapshot }
        append(entry)
        return entry.id
    }

    func clear() {
        lock.lock()
        stored.removeAll(keepingCapacity: true)
        fileLines = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.entries = [] }
        disk.async { try? Data().write(to: self.file) }
    }

    // -- helpers ----------------------------------------------------------

    static func songOf(_ t: Track) -> String {
        [t.title.isEmpty ? t.id : t.title, t.artist].filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
    }

    static func keyOf(_ t: Track) -> String { t.id.isEmpty ? "" : "\(t.source):\(t.id)" }

    /** spotify / ytm / sc for a song from that service; jukebox for the rest. */
    static func serviceOf(_ t: Track?) -> String { serviceOf(source: t?.source ?? "") }

    static func serviceOf(source: String) -> String {
        switch source {
        case "spotify": return "spotify"
        case "ytm", "youtube": return "ytm"
        case "sc": return "sc"
        default: return "jukebox"
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "spotify": return "Spotify"
        case "ytm": return "YouTube Music"
        case "sc": return "SoundCloud"
        default: return "Jukebox"
        }
    }

    private static func sourceOf(_ tag: String) -> String {
        if tag.hasPrefix("Spotify") { return "spotify" }
        if tag.hasPrefix("YouTube") || tag.hasPrefix("Ytm") { return "ytm" }
        if tag.hasPrefix("SoundCloud") { return "sc" }
        return "jukebox"
    }

    static func clockOf(_ e: ConsoleEntry) -> String { clock.string(from: Date(timeIntervalSince1970: e.at)) }

    static func stampOf(_ e: ConsoleEntry) -> String { stamp.string(from: Date(timeIntervalSince1970: e.at)) }

    static func line(_ e: ConsoleEntry) -> String {
        var s = "\(stampOf(e))  \(e.level.rawValue)  \(sourceLabel(e.source))  \(e.area)  \(e.message)"
        if !e.song.isEmpty { s += "  [\(e.song) \u{B7} \(e.songKey)]" }
        if !e.details.isEmpty { s += "\n      " + e.details.replacingOccurrences(of: "\n", with: "\n      ") }
        return s
    }

    /** The given entries as plain text, for Copy and Share. */
    static func text(_ list: [ConsoleEntry]) -> String { list.map(line).joined(separator: "\n") }

    // -- disk ---------------------------------------------------------------

    private static func json(_ e: ConsoleEntry) -> String {
        let o: [String: Any] = ["id": e.id, "at": e.at, "l": e.level.rawValue, "a": e.area, "s": e.source,
                                "m": e.message, "song": e.song, "k": e.songKey, "d": e.details]
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ line: String) -> ConsoleEntry? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let id = (o["id"] as? NSNumber)?.intValue else { return nil }
        return ConsoleEntry(
            id: id,
            at: (o["at"] as? NSNumber)?.doubleValue ?? 0,
            level: ConsoleEntry.Level(rawValue: o["l"] as? String ?? "") ?? .info,
            area: o["a"] as? String ?? "",
            source: o["s"] as? String ?? "jukebox",
            message: o["m"] as? String ?? "",
            song: o["song"] as? String ?? "",
            songKey: o["k"] as? String ?? "",
            details: o["d"] as? String ?? ""
        )
    }

    private func append(_ e: ConsoleEntry) {
        let text = Self.json(e) + "\n"
        disk.async {
            if let h = try? FileHandle(forWritingTo: self.file) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: self.file)
            }
            self.lock.lock()
            self.fileLines += 1
            let n = self.fileLines
            self.lock.unlock()
            if n > Self.capacity + Self.capacity / 4 { self.compact() }
        }
    }

    /** Rewrite the file with the entries in memory (the last 2000). Runs on the disk queue. */
    private func compact() {
        lock.lock()
        let keep = stored
        lock.unlock()
        let body = keep.map { Self.json($0) + "\n" }.joined()
        try? Data(body.utf8).write(to: file, options: .atomic)
        lock.lock()
        fileLines = keep.count
        lock.unlock()
    }
}
