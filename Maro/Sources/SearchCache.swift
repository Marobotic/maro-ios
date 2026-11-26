import CryptoKit
import Foundation

private func digest(_ key: String) -> String {
    Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
}

// -- search answers, kept ---------------------------------------------------------

/**
 * Search results by query (trimmed, lowercased) and source: the newest 200 in
 * memory, 500 on disk for a week. A kept query draws at once.
 */
private let searchMemoryMax = 200
private let searchDiskMax = 500
private let searchDiskAge: Double = 7 * 24 * 3600

@MainActor
final class SearchCache {
    static let shared = SearchCache()

    struct Hit {
        let tracks: [Track]
        let at: Double
    }

    private var memory: [String: Hit] = [:]
    private var order: [String] = []
    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("search", isDirectory: true)
    }()

    init() {
        let folder = dir
        Task.detached(priority: .background) { Self.prune(folder) }
    }

    static func key(_ query: String, source: String) -> String {
        source + "|" + query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func get(_ key: String) -> Hit? {
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        let file = dir.appendingPathComponent(digest(key) + ".json")
        guard let data = try? Data(contentsOf: file), let o = JSONText.parse(data) as? JSON,
              Date().timeIntervalSince1970 - o.double("at") < searchDiskAge else { return nil }
        let hit = Hit(tracks: Sync.tracks(o.arr("tracks")), at: o.double("at"))
        remember(key, hit)
        return hit
    }

    /** Whether a query is kept, without reading it. */
    func has(_ key: String) -> Bool {
        memory[key] != nil || FileManager.default.fileExists(atPath: dir.appendingPathComponent(digest(key) + ".json").path)
    }

    func put(_ key: String, _ tracks: [Track]) {
        let hit = Hit(tracks: tracks, at: Date().timeIntervalSince1970)
        remember(key, hit)
        let file = dir.appendingPathComponent(digest(key) + ".json"), folder = dir
        let data = JSONText.data(["at": hit.at, "tracks": tracks.map { $0.toJSON() }] as JSON)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func remember(_ key: String, _ hit: Hit) {
        memory[key] = hit
        touch(key)
        while order.count > searchMemoryMax {
            memory.removeValue(forKey: order.removeFirst())
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /** A week at most, and the newest 500. */
    nonisolated private static func prune(_ dir: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let now = Date()
        let dated = files.map { f -> (URL, Date) in
            (f, (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (i, (file, date)) in dated.enumerated() where i >= searchDiskMax || now.timeIntervalSince(date) > searchDiskAge {
            try? fm.removeItem(at: file)
        }
    }
}
