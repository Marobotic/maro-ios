import Foundation

/**
 * Models for the state the engine synchronises to the droplet (/sync snapshot)
 * and the events it pushes to the phone (/relay/phone).
 *
 * Track dicts carry whatever keys the engine set: source, id, sourceId,
 * videoId, title, artist, album, duration, played_at. Every access opts out
 * rather than requiring the key, like org.json's opt* on Android.
 */
typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String, _ fallback: String = "") -> String {
        switch self[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return fallback
        }
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        switch self[key] {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? fallback
        default: return fallback
        }
    }

    func int64(_ key: String, _ fallback: Int64 = 0) -> Int64 {
        (self[key] as? NSNumber)?.int64Value ?? fallback
    }

    func double(_ key: String, _ fallback: Double = 0) -> Double {
        switch self[key] {
        case let n as NSNumber:
            let v = n.doubleValue
            return v.isNaN ? fallback : v
        case let s as String: return Double(s) ?? fallback
        default: return fallback
        }
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        (self[key] as? NSNumber)?.boolValue ?? fallback
    }

    func obj(_ key: String) -> JSON? { self[key] as? JSON }

    func arr(_ key: String) -> [Any]? { self[key] as? [Any] }
}

enum JSONText {
    static func parse(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    static func object(_ text: String) -> JSON? { parse(Data(text.utf8)) as? JSON }

    static func data(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }

    static func string(_ value: Any) -> String { String(decoding: data(value), as: UTF8.self) }
}

/**
 * One song is one object: it knows whether its audio is on this phone, so any
 * row can just read `track.saved`. The view model keeps this set in sync with
 * the files on disk (and the songs that map to them) in one place.
 */
enum OnPhoneSongs {
    private static let lock = NSLock()
    private static var ids: Set<String> = []

    static func sync(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        self.ids = ids
    }

    static func has(_ track: Track) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return track.trackIds.contains { ids.contains($0) }
    }
}

struct Track: Equatable, Hashable {
    var source = ""
    var id = ""
    var sourceId = ""
    var videoId = ""
    var title = ""
    var artist = ""
    var album = ""
    var artUrl = ""
    var duration: Double = 0
    var playedAt: Int64 = 0
    var viaYoutube = false

    /** One song reaches the panel under several ids; all of them are this song. */
    var trackIds: [String] {
        var out: [String] = []
        if !id.isEmpty { out.append(id) }
        if !videoId.isEmpty && !out.contains(videoId) { out.append(videoId) }
        if !sourceId.isEmpty && !out.contains(sourceId) { out.append(sourceId) }
        return out
    }

    /** The id a cover is filed under (the engine's art store key). */
    var artKey: String { sourceId.ifEmpty(id) }

    /** Whether this song's audio is on this phone right now. */
    var saved: Bool { OnPhoneSongs.has(self) }

    func sameAs(_ other: Track?) -> Bool {
        guard let other else { return false }
        return id == other.id || other.trackIds.contains(id) || trackIds.contains(other.id)
    }

    func with(videoId: String) -> Track {
        var t = self
        t.videoId = videoId
        return t
    }

    func toJSON() -> JSON {
        [
            "source": source, "id": id, "sourceId": sourceId, "videoId": videoId,
            "title": title, "artist": artist, "album": album, "art": artUrl,
            "duration": duration, "viaYoutube": viaYoutube,
        ]
    }

    static func from(_ o: JSON?) -> Track {
        guard let o else { return Track() }
        return Track(
            source: o.str("source"),
            id: o.str("id"),
            sourceId: o.str("sourceId"),
            videoId: o.str("videoId"),
            title: o.str("title").ifEmpty(o.str("name")),
            artist: o.str("artist").ifEmpty(o.str("author")),
            album: o.str("album"),
            // "artUrl" is what older device caches wrote.
            artUrl: o.str("art").ifEmpty(o.str("artUrl")),
            duration: o.double("duration"),
            playedAt: o.int64("played_at"),
            viaYoutube: o.bool("viaYoutube")
        )
    }
}

/** One row of the Playlists tab's library: a section header or a playlist. */
struct LibraryRow: Equatable, Hashable {
    var isHeader = false
    var source = ""
    var label = ""
    var count = 0
    var name = ""
    var id = ""
    var art = ""
    var available = true
}

/** A sign-in the engine started for this phone: open the page, or show the code. */
struct LoginPrompt: Equatable {
    var service: String
    var url = ""
    var code = ""
    var error = ""
}

struct Device: Equatable, Hashable {
    var id: String
    var name = ""
    var kind: String
    var connected: Bool
    var isPlayback: Bool
    /** Plays on its own ("this device only"): not part of the shared player. */
    var solo = false
}

/** Progress of a "Download playlist" job, keyed by its playlist id. */
struct DownloadJob: Equatable {
    var total = 0
    var done = 0
    var failed = 0
    var running = false

    var finished: Bool { !running && total > 0 && done + failed >= total }
    var fraction: Double { total > 0 ? Double(done + failed) / Double(total) : 0 }
}

enum PlaybackMode: String {
    case remoteDesktop = "REMOTE_DESKTOP"
    case standalonePhone = "STANDALONE_PHONE"
}

/** Seconds on a monotonic clock, like SystemClock.elapsedRealtime on Android. */
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/**
 * Where the playhead is, anchored to a moment on the monotonic clock, so the
 * seek bar can run on its own between updates. Kept out of [UiState]: it
 * changes constantly and only the seek row and lyrics need it.
 */
struct Progress: Equatable {
    var position: Double = 0
    var duration: Double = 0
    var playing = false
    var anchor: Double = 0

    func at(_ now: Double) -> Double {
        let live = playing ? position + (now - anchor) : position
        return duration > 0 ? min(max(live, 0), duration) : max(live, 0)
    }
}

struct UiState: Equatable {
    var signedIn = false
    var email = ""
    var selectedAccount = "maro"
    var busy = false
    var error: String?
    var devices: [Device] = []
    var playbackTarget = ""
    // This phone's relay id and the name it shows up under.
    var myDeviceId = ""
    var deviceName = ""
    // "Play music on this device only": out of the shared player.
    var solo = false

    // Player (desktop)
    var track: Track?
    var playing = false
    var queueIndex = -1
    var queue: [Track] = []
    var queueName = ""
    var volume = 100
    var `repeat` = "off"
    var shuffle = false
    var origin = ""
    var loadingKey = ""
    var loadingStage = ""

    // Settings
    var quality = "normal"
    var downloadQuality = "max"
    var savingOffline = true
    var playbackSource = "auto"
    var gateText = ""

    // Collections
    var recent: [Track] = []
    var songs: [Track] = []
    var likedKeys: Set<String> = []
    var likedIds: Set<String> = []
    var library: [LibraryRow] = []
    var selectedPlaylist: LibraryRow?
    var playlistTracks: [Track] = []
    var playlistLoading = false
    var playlistLoadingMore = false
    var playlistHasMore = false
    var playlistTotal = 0
    var playlistError = ""

    // Phone storage
    var phoneAvailableBytes: Int64 = 0
    var phoneTotalBytes: Int64 = 0
    var phoneMusicBytes: Int64 = 0
    var phoneMusicCount = 0
    var phoneCacheBytes: Int64 = 0
    var artworkProgress: [String: Int] = [:]

    // Connectivity & offline behaviour
    var online = false
    var localAvailable: Set<String> = []
    var downloads: [String: DownloadJob] = [:]

    // Provider sessions observed on the active desktop
    var spotifyConnected = false
    var spotifyApiConnected = false
    var spotifyAccountName = ""
    var ytmConnected = false
    var ytmAccountName = ""

    // Player (this phone)
    var playbackMode: PlaybackMode = .remoteDesktop
    var localTrack: Track?
    var localPlaying = false
    var localQueue: [Track] = []
    var localQueueIndex = -1
    var localQueueName = "Phone queue"
    var localRepeat = "off"
    var localShuffle = false
    var localPreparing = false
    var localError = ""

    // Search
    var searchText = ""
    var searchSource = ""
    var searchResults: [Track] = []
    var searching = false

    // View
    var view = Sync.viewQueue
    var settingsOpen = false

    // Status footer
    var statusMsg = ""
    var statusKind = "info"

    // A Spotify / YouTube Music sign-in waiting on the user.
    var loginPrompt: LoginPrompt?

    var isCurrent: Bool { track != nil }

    var playlists: [LibraryRow] { library.filter { !$0.isHeader } }

    func isLiked(_ t: Track?) -> Bool {
        guard let t, !t.id.isEmpty else { return false }
        if !t.source.isEmpty && likedKeys.contains(t.source + ":" + t.id) { return true }
        return t.trackIds.contains { likedIds.contains($0) }
    }

    /** Online everything is playable; offline only the songs actually on this phone are. */
    func canPlay(_ t: Track?) -> Bool {
        guard let t, !t.id.isEmpty else { return false }
        if online { return true }
        return t.trackIds.contains { localAvailable.contains($0) }
    }

    func downloadOf(_ row: LibraryRow) -> DownloadJob? { downloads["v3:" + row.source + ":" + row.id] }

    /** The device whose speakers the music comes out of. */
    var playingDeviceId: String {
        if playbackMode == .standalonePhone { return myDeviceId }
        if !playbackTarget.isEmpty && devices.contains(where: { $0.id == playbackTarget && $0.connected }) { return playbackTarget }
        return devices.first { $0.kind == "desktop" && $0.connected }?.id ?? ""
    }

    var playingDeviceName: String {
        let id = playingDeviceId
        if id == myDeviceId { return deviceName }
        return devices.first { $0.id == id }?.name.ifBlank("Desktop") ?? "Desktop"
    }

    /**
     * What the device picker offers: every device connected right now, this
     * phone first. This phone is always there, even before the account has
     * heard its first poll.
     */
    func pickerDevices() -> [Device] {
        let playing = playingDeviceId
        let others = devices
            .filter { $0.connected && !$0.solo && $0.id != myDeviceId }
            .map { d -> Device in
                var d = d
                d.isPlayback = d.id == playing
                return d
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return [Device(id: myDeviceId, name: deviceName, kind: "phone", connected: true, isPlayback: playing == myDeviceId)] + others
    }

    func displayState() -> UiState {
        guard playbackMode == .standalonePhone else { return self }
        var s = self
        s.track = localTrack
        s.playing = localPlaying
        s.queue = localQueue
        s.queueIndex = localQueueIndex
        s.queueName = localQueueName
        s.repeat = localRepeat
        s.shuffle = localShuffle
        s.origin = "phone"
        s.loadingKey = localPreparing ? (localTrack?.id ?? "") : ""
        s.loadingStage = localPreparing ? "Preparing on this phone" : ""
        s.gateText = localError
        return s
    }
}

enum Sync {
    static let viewQueue = "queue"
    static let viewLyrics = "lyrics"
    static let viewPlaylists = "playlists"
    static let viewSongs = "songs"
    static let viewRecent = "recent"
    static let viewSearch = "search"

    static func tracks(_ arr: [Any]?) -> [Track] {
        guard let arr else { return [] }
        return arr.map { Track.from($0 as? JSON) }.filter { !$0.title.isEmpty || !$0.id.isEmpty }
    }

    static func likedKeys(_ arr: [Any]?) -> Set<String> {
        guard let arr else { return [] }
        var out = Set<String>()
        for case let t as JSON in arr {
            let src = t.str("source"), id = t.str("id")
            if !src.isEmpty && !id.isEmpty { out.insert("\(src):\(id)") }
        }
        return out
    }

    /**
     * Flatten the library dict {"liked":[...],"spotify":[...],"ytm":[...],
     * "local":[...]} into header rows + playlist rows, in the same order the
     * panel's flattenLibrary uses: Liked, Spotify, YouTube Music, My Playlists.
     */
    static func library(_ dict: JSON?) -> [LibraryRow] {
        guard let dict else { return [] }
        var out: [LibraryRow] = []
        func group(_ key: String, _ label: String) {
            guard let entries = dict.arr(key), !entries.isEmpty else { return }
            out.append(LibraryRow(isHeader: true, source: key, label: label, count: entries.count))
            for case let e as JSON in entries {
                out.append(LibraryRow(
                    source: e.str("source", key),
                    label: e.str("name", e.str("label")),
                    count: e.int("count"),
                    name: e.str("name"),
                    id: e.str("id"),
                    art: e.str("art", e.str("cover")),
                    available: e.bool("available", true)
                ))
            }
        }
        group("liked", "Liked")
        group("spotify", "Spotify")
        group("ytm", "YouTube Music")
        group("local", "My Playlists")
        return out
    }
}

/** Parse helpers for the /relay/phone events. */
enum Relay {
    static func trackFromNowPlaying(_ p: JSON?) -> Track {
        guard let p else { return Track() }
        return Track(
            source: p.str("source"),
            id: p.str("id"),
            sourceId: p.str("sourceId"),
            videoId: p.str("videoId"),
            title: p.str("title"),
            artist: p.str("artist"),
            album: p.str("album"),
            duration: p.double("duration")
        )
    }
}
