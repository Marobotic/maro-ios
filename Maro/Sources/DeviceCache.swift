import CryptoKit
import Foundation

struct CachedPlaylist {
    let tracks: [Track]
    let total: Int
    let hasMore: Bool
}

/**
 * What the phone keeps between launches: opened playlists, the songs saved on
 * the phone, and which YouTube video plays each track. Plain JSON files, as on
 * Android. Every call here does disk IO: call it off the main actor.
 */
final class DeviceCache: @unchecked Sendable {
    private let dir: URL
    private let playlistDir: URL
    private let songsFile: URL
    private let trackMapFile: URL
    private let snapshotFile: URL
    private let localQueueFile: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("device-cache", isDirectory: true)
        playlistDir = dir.appendingPathComponent("playlists", isDirectory: true)
        songsFile = dir.appendingPathComponent("songs.json")
        trackMapFile = dir.appendingPathComponent("track-map.json")
        snapshotFile = dir.appendingPathComponent("snapshot.json")
        localQueueFile = dir.appendingPathComponent("local-queue.json")
        try? FileManager.default.createDirectory(at: playlistDir, withIntermediateDirectories: true)
    }

    func playlist(_ key: String) -> CachedPlaylist? {
        guard let obj = readJSON(playlistFile(key)) as? JSON else { return nil }
        return CachedPlaylist(tracks: Sync.tracks(obj.arr("tracks")), total: obj.int("total"), hasMore: obj.bool("hasMore"))
    }

    func savePlaylist(_ key: String, _ tracks: [Track], total: Int, hasMore: Bool) {
        write(playlistFile(key), ["total": total, "hasMore": hasMore, "tracks": tracks.map { $0.toJSON() }])
    }

    func clearPlaylists() {
        let files = (try? FileManager.default.contentsOfDirectory(at: playlistDir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func downloadedSongs() -> [Track] { Sync.tracks(readJSON(songsFile) as? [Any]) }

    func saveDownloadedSongs(_ songs: [Track]) { write(songsFile, songs.map { $0.toJSON() }) }

    func trackMap() -> [String: String] {
        guard let obj = readJSON(trackMapFile) as? JSON else { return [:] }
        var out: [String: String] = [:]
        for (k, _) in obj { out[k] = obj.str(k) }
        return out
    }

    func saveTrackMap(_ map: [String: String]) { write(trackMapFile, map) }

    /**
     * The account's last good /sync response ({kind, at, snapshot}), so the
     * phone can show the queue, playlists and liked songs it had before the
     * last launch without the network. Written whenever a pull succeeds.
     */
    func saveSnapshot(_ raw: Data) { atomicWrite(snapshotFile, raw) }

    func snapshot() -> Data? { try? Data(contentsOf: snapshotFile) }

    /** The phone's own playback queue (the list shown in standalone mode). */
    func saveLocalQueue(name: String, _ tracks: [Track]) {
        write(localQueueFile, ["name": name, "tracks": tracks.map { $0.toJSON() }])
    }

    /**
     * The saved playback queue, or nil when it has never been saved. An empty
     * list is saved deliberately: the user cleared it and it must stay empty.
     */
    func localQueue() -> (name: String, tracks: [Track])? {
        guard let obj = readJSON(localQueueFile) as? JSON else { return nil }
        return (obj.str("name", "Phone queue"), Sync.tracks(obj.arr("tracks")))
    }

    private func playlistFile(_ key: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return playlistDir.appendingPathComponent(digest + ".json")
    }

    private func readJSON(_ file: URL) -> Any? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return JSONText.parse(data)
    }

    private func write(_ file: URL, _ value: Any) { atomicWrite(file, JSONText.data(value)) }

    private func atomicWrite(_ file: URL, _ data: Data) { try? data.write(to: file, options: .atomic) }
}
