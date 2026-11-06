import Foundation
import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.marobotic.maro", category: "MaroPlay")

/** Consecutive can't-play songs before the queue stops instead of skipping forever. */
private let skipStreakMax = 6

/** Songs asked for at once while downloading a playlist (bounds the engine's busy threads). */
private let downloadBatch = 4

/** After a clear, adopt an empty account queue for this long instead of holding the old one. */
private let queueClearWindow: Double = 10 * 60

private let audioExtensions: Set<String> = ["m4a", "mp3", "ogg", "webm", "aac", "flac", "opus"]

/** Why the phone asked the engine to put a song on the droplet. */
private enum Purpose {
    case play(tag: Int)
    case warm
    case save
    /** One track of a "Download playlist" job: map it, upload it, copy it to the phone. */
    case download(key: String)
}

private struct Pending {
    let track: Track
    let purpose: Purpose
}

/** One downloaded track finished: [ready] uploads exist on the droplet, [track] is what to save. */
private struct Downloaded {
    let ready: Bool
    let track: Track
    /** The engine's reason when it could not (a removed video says so). */
    var error = ""
}

func sleep(seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

@MainActor
final class MaroViewModel: ObservableObject, PhonePlayerEvents {
    private let client = MaroClient()
    private let deviceCache = DeviceCache()
    private let prefs = UserDefaults.standard

    /** "Play music on this device only": out of the shared player (see there). */
    private var solo = UserDefaults.standard.bool(forKey: "playSolo")

    @Published var state = UiState() {
        didSet { stateChanged(from: oldValue) }
    }

    /** Lyrics for the song on screen (this phone's, or the desktop's when it is the remote). */
    @Published private(set) var lyrics = SongLyrics() {
        // Round 2 L: no lyrics once the lookup is done (or nothing playing) hides the Lyrics tab.
        didSet {
            let none = !lyrics.loading && lyrics.lines.isEmpty
            if state.noLyrics != none { state.noLyrics = none }
        }
    }

    /** The playhead, apart from [state]: only the seek row and lyrics read it. */
    @Published private(set) var progress = Progress()

    /** Bumped to open the full-screen view (the launch route's "jam"). */
    @Published private(set) var jamRequest = 0

    private var lyricsMem: [String: SongLyrics] = [:]
    private var lyricsOrder: [String] = []
    private var lyricsTask: Task<Void, Never>?

    private var phoneId = ""
    private var pump: Task<Void, Never>?
    private var pumpStop = false
    private var syncTask: Task<Void, Never>?
    private var lastSyncAt = ""
    // Service playlists saved on the account ("source:id" -> entry with its
    // tracks): opened straight from here, with no desktop to ask.
    private var savedPlaylists: [String: JSON] = [:]
    /**
     * Every liked song, from the account's snapshot (the list the hearts come
     * from). The Liked playlist is drawn from this: asked page by page, it
     * came from the cloud engine's own copy, which had fallen behind, and
     * stopped at its first 50.
     */
    private var likedTracks: [Track] = []
    /**
     * Until when (uptime) songs skip Spotify: it just failed to start one
     * (a connection dying on the way from Wi-Fi to 4G, or Spotify refusing
     * keys). Meanwhile they play from YouTube at once instead of each one
     * waiting for Spotify to fail again.
     */
    private var spotifyRestUntil: Double = 0
    private static let spotifyRest: Double = 180

    // Which YouTube video plays each track, and what the droplet and phone hold.
    private var trackMap: [String: String] = [:]
    private var serverCached: Set<String> = []
    private var serverMapLoaded = false
    private var localFiles: [String: URL] = [:]
    /** Every song played here, kept in the caches folder (the system may reclaim it). */
    private var keptFiles: [String: URL] = [:]
    private var trackMapSave: Task<Void, Never>?

    private var pending: [String: Pending] = [:]
    private var warmAsked: [String: Double] = [:]
    private var phonePlayer: PhonePlayer?
    private var nowPlaying: NowPlaying?
    private var playTag = 0
    private var retriedTag = 0
    private var tapAt: Double = 0
    private var playRoute = ""
    private var loggedTag = 0
    private var saveTask: Task<Void, Never>?
    private var playWhenLoaded: String?
    private var failStreak = 0
    /** The last play that really started (onStarted), for the start watchdog. */
    private var startedTag = 0
    private let network = NetworkWatch()

    // When the user last cleared the queue, so an empty account snapshot can
    // be adopted instead of the merge guard holding onto the old songs.
    private var queueClearedAt: Double = -.infinity

    // Whether the phone has played anything yet. The playback queue on disk
    // is only written once it is: until then, an empty file would shadow the
    // account queue when the phone switches to standalone.
    private var localDirty = false
    private var localQueueOnDisk = false
    private var localQueueSave: Task<Void, Never>?

    // One track finished uploading per element, consumed by the playlist download.
    private var downloadInbox: [Downloaded] = []

    /** Where the queue window last sent to the desktop starts; its indices are relative to it. */
    private var reportedOffset = 0
    private var pendingSeek: Double = 0

    private var artFetched: Set<String> = []

    private var phone: PhonePlayer {
        if let phonePlayer { return phonePlayer }
        let p = PhonePlayer(events: self)
        p.volume = Float(state.volume) / 100
        phonePlayer = p
        nowPlaying = NowPlaying(.init(
            play: { [weak self] in self?.phonePlayer?.play() },
            pause: { [weak self] in self?.phonePlayer?.pause() },
            toggle: { [weak self] in self?.playPause() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] in self?.seek($0) }
        ))
        return p
    }

    private var isPhone: Bool { state.playbackMode == .standalonePhone }

    init() {
        state.gone = UserDefaults.standard.dictionary(forKey: "goneSongs") as? [String: String] ?? [:]
        AudioCache.session = { [client] in client.session }
        client.onSessionRejected = { [weak self] in Task { @MainActor in self?.sessionRejected() } }
        AudioCache.client = client
        AudioCache.tier = { [weak self] in self?.state.quality ?? "max" }
        ArtLoader.shared.client = client
        PageStore.client = client
        // Sign in once, every device works (round 2 I): this phone's link to the others.
        DeviceLink.shared.client = client
        DeviceLink.shared.host = self
        DeviceLink.shared.deviceId = deviceId()
        DeviceLink.shared.deviceName = Omp.phoneName
        // This phone's own YouTube Music session: restored, read, kept fresh (round 2 H).
        Task { await YtmDevice.shared.start() }
        // Covers changed on the account (Fix artwork on another device, a
        // song's first proper cover): checked now and every two minutes.
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await ArtLoader.shared.syncChanges()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
        Omp.customPhoneName = prefs.string(forKey: "deviceName") ?? ""
        var s = UiState()
        s.myDeviceId = deviceId()
        s.deviceName = Omp.phoneName
        s.signedIn = client.session != nil
        s.email = client.email ?? ""
        s.selectedAccount = prefs.string(forKey: "selectedAccount") ?? "maro"
        s.playbackMode = solo || prefs.string(forKey: "playbackMode") == PlaybackMode.standalonePhone.rawValue ? .standalonePhone : .remoteDesktop
        s.solo = solo
        s.savingOffline = prefs.object(forKey: "savingOffline") as? Bool ?? true
        s.songsLimitGb = prefs.integer(forKey: "songsLimitGb")
        // The account's preferred source as last read (the account's copy wins once it answers).
        s.playbackSource = prefs.string(forKey: "preferredSource") ?? "auto"
        // Into the app at once when this phone already went in once; else the
        // splash until the account's services are known (round 2 F).
        s.listenGate = prefs.bool(forKey: "listenIn") ? "in" : "checking"
        state = s
        applyLaunchRoute()
        Task {
            await loadDeviceState()
            await restoreSnapshot()
            publishLocalAvailable()
            if state.signedIn {
                ensurePhonePump()
                Task { await refreshServices(); await decideListenGate() }
                gateDeadline()
                await pullAccount()
                await pullSync()
                await syncPlayer()
                await refreshTrackMap()
                await sleep(seconds: 1.5)
                await pullAccount()
            }
        }
        startConnectivityWatch()
        network.onChange = { [weak self] old, new in self?.networkChanged(old, new) }
        network.start()
        Spotify.shared.onReconnected = { [weak self] ok in
            guard let self else { return }
            log.info("spotify reconnected: \(ok)")
            // A fresh connection is worth trying on the next song, rather
            // than three minutes of YouTube.
            if ok { self.spotifyRestUntil = 0 }
            if ok && self.isPhone && self.phonePlayer?.onSpotify == true { self.phonePlayer?.reloadSpotify() }
        }
        // Sessions signed in to (or out of) on another client arrive here
        // without a restart.
        Task { [weak self] in
            while true {
                await sleep(seconds: 300)
                guard let self else { return }
                if self.state.signedIn { await self.refreshServices() }
            }
        }
        Task { [weak self] in
            while true {
                await sleep(seconds: 5)
                guard let self else { return }
                if self.isPhone && self.state.localPlaying { self.savePlayheadNow() }
            }
        }
    }

    /** What SwiftUI's didSet sees: the Android view model's state collectors, in one place. */
    private func stateChanged(from old: UiState) {
        let shownOld = old.displayState().track, shown = state.displayState().track
        if shownOld?.id != shown?.id { loadLyrics(shown) }
        if old.localQueue != state.localQueue || old.localQueueName != state.localQueueName {
            persistLocalQueueSoon(state.localQueue, name: state.localQueueName)
        }
        if isPhone && (old.localTrack != state.localTrack || old.localPlaying != state.localPlaying) {
            updateNowPlaying()
        }
        // A list that arrived or changed: its covers onto the phone before
        // they are scrolled to.
        for (name, was, list) in [("playlist", old.playlistTracks, state.playlistTracks), ("discover", old.discoverTracks, state.discoverTracks),
                                  ("search", old.searchResults, state.searchResults), ("queue", old.localQueue, state.localQueue),
                                  ("recent", old.recent, state.recent)]
        where was.count != list.count || was.first?.id != list.first?.id {
            ArtLoader.shared.prefetch(list, list: name)
        }
        // The library: every playlist kept on the phone, read once.
        if old.library.count != state.library.count && !NetworkWatch.expensive { prefetchLibraryArt(state.library) }
        // And their kept song lists counted, so each row shows what we hold.
        if old.library != state.library { loadKeptCounts(state.library) }
        // A service signed in from "How do you want to listen?": into the app.
        if (state.listenGate == "pick" || (state.listenGate == "checking" && !state.unreachableServices.isEmpty)) && !state.services.isEmpty { setGate("in") }
        // Round 2 L: never left on a hidden tab - an empty queue or no lyrics lands on Library.
        if (state.view == Sync.viewQueue && state.displayState().queue.isEmpty) || (state.view == Sync.viewLyrics && state.noLyrics) {
            state.view = Sync.viewPlaylists
        }
    }

    private func prefetchLibraryArt(_ rows: [LibraryRow]) {
        let keys = rows.filter { !$0.isHeader && !$0.id.isEmpty }.map { playlistKey($0) }
        let cache = deviceCache
        Task.detached(priority: .utility) {
            for key in keys {
                if let kept = cache.playlist(key) { ArtLoader.shared.prefetch(kept.tracks, list: "kept:" + key, onDisk: true) }
            }
        }
    }

    private func updateNowPlaying() {
        guard let nowPlaying else { return }
        nowPlaying.update(track: state.localTrack, position: progress.at(uptime()), duration: progress.duration, playing: state.localPlaying)
    }

    // -- device state -------------------------------------------------------

    private func deviceId() -> String {
        if phoneId.isEmpty {
            if let saved = prefs.string(forKey: "phoneId") {
                phoneId = saved
            } else {
                phoneId = "phone-" + UUID().uuidString.lowercased().prefix(8)
                prefs.set(phoneId, forKey: "phoneId")
            }
        }
        return phoneId
    }

    private func ensurePhonePump() {
        if pump != nil { return }
        pumpStop = false
        startStateReports()
        ensureLikedSync()
        pump = client.phonePump(
            deviceId: deviceId(),
            deviceName: { await MainActor.run { Omp.phoneName } },
            solo: { [weak self] in await self?.solo ?? false },
            stop: { [weak self] in await self?.pumpShouldStop() ?? true },
            onEvent: { [weak self] msg in await self?.onRelayMessage(msg) }
        )
    }

    private func pumpShouldStop() -> Bool { pumpStop || !state.signedIn }

    // -- liked songs ----------------------------------------------------------
    //
    // The droplet holds the account's Liked list. A heart here goes there at
    // once (and shows here at once); a heart on any other device arrives
    // through this long-poll the moment it is made. Newest on top.

    private var likedSync: Task<Void, Never>?

    private func ensureLikedSync() {
        if likedSync != nil { return }
        likedSync = Task { [weak self] in
            var rev = -1
            while !Task.isCancelled {
                guard let self, self.state.signedIn, !self.pumpStop else { break }
                switch await self.client.likedPoll(after: rev, wait: rev < 0 ? 0 : 25) {
                case .list(let r, let items):
                    rev = r
                    self.applyLiked(items.compactMap { ($0 as? JSON)?.obj("track") })
                case .same: break
                case .failed: await sleep(seconds: 5)
                }
            }
            self?.likedSync = nil
        }
    }

    private func applyLiked(_ arr: [Any]) {
        let tracks = Sync.tracks(arr).map(giveVideoId)
        likedKnown = true
        if tracks.map(\.id) == likedTracks.map(\.id) { return }
        var s = state
        s.likedKeys = Sync.likedKeys(arr)
        likedTracks = tracks
        s.likedIds = Set(tracks.flatMap(\.trackIds))
        if s.selectedPlaylist?.source == "liked" {
            s.playlistTracks = likedTracks
            s.playlistTotal = likedTracks.count
        }
        applyCounts(&s)
        state = s
    }

    /** Whether the liked list itself has arrived (from the snapshot or the long-poll). */
    private var likedKnown = false

    /** When the app last went to the background (round 2 I.5), nil while in front. */
    var backgroundedAt: Date?

    /**
     * Songs held per playlist ("source:id" -> how many), for lists not on the
     * account: the phone's own complete copies (device cache, or fetched from
     * Spotify here). The account's saved lists are counted in `savedCounts`.
     */
    private var keptCounts: [String: Int] = [:]
    /** Each saved list's songs, counted once as it arrives (the same rows heldTracks gives). */
    private var savedCounts: [String: Int] = [:]

    /** How many songs we hold for a row, or nil when no list is held yet. */
    private func heldCount(_ row: LibraryRow) -> Int? {
        if row.source == "liked" { return likedKnown ? likedTracks.count : nil }
        let key = "\(row.source):\(row.id)"
        // The account's stored copy (its latest), then one held here.
        if let n = accountIndex[key]?.count, n > 0 { return n }
        if let n = savedCounts[key], n > 0 { return n }
        return keptCounts[key]
    }

    /**
     * The one count rule (round 2 A): every library row's count is the
     * number of songs we hold for it - Liked is the liked list (the library
     * snapshot's own count lagged: 62 there, 82 in the list), a service
     * playlist is its stored song list. Only with no list held yet does the
     * service's count show, marked as syncing. UiState.countFor reads these.
     */
    private func applyCounts(_ s: inout UiState) {
        func fixed(_ row: LibraryRow) -> LibraryRow {
            guard !row.isHeader else { return row }
            var r = row
            if let n = heldCount(row) {
                r.count = n
                r.syncing = false
            } else {
                r.syncing = row.source == "spotify"
            }
            return r
        }
        let liked: Int? = likedKnown ? likedTracks.count : nil
        if s.likedTotal != liked { s.likedTotal = liked }
        let rows = s.library.map(fixed)
        if rows != s.library { s.library = rows }
        if let open = s.selectedPlaylist {
            let f = fixed(open)
            if f != open { s.selectedPlaylist = f }
        }
    }

    /** applyCounts on the live state. */
    private func recount() {
        var s = state
        applyCounts(&s)
        if s != state { state = s }
    }

    /**
     * Saved lists from the account, merged over the ones held here: the newer
     * copy of each wins (one this phone just read from Spotify can be newer
     * than the account's).
     */
    private func mergeSaved(_ incoming: [String: JSON]) {
        for (key, entry) in incoming {
            if let mine = savedPlaylists[key] {
                let a = Self.savedAt(mine), b = Self.savedAt(entry)
                // Ours is newer, or it is the same copy again: nothing to do.
                if a > b { continue }
                if a == b && savedCounts[key] != nil && mine.arr("tracks")?.count == entry.arr("tracks")?.count { continue }
            }
            savedPlaylists[key] = entry
            savedCounts[key] = Sync.tracks(entry.arr("tracks")).count
        }
    }

    /** A saved list's "savedAt" in seconds, whichever way its writer put it (s, ms or ISO). */
    static func savedAt(_ entry: JSON) -> Double {
        var v = entry.double("savedAt")
        if v == 0, let d = ISO8601DateFormatter.flexible(entry.str("savedAt")) { v = d.timeIntervalSince1970 }
        return v > 100_000_000_000 ? v / 1000 : v
    }

    /** The rows whose kept copies were last counted, so they are read once per change. */
    private var keptCountKeys: Set<String> = []

    /** The phone's own complete copies of the library's playlists, counted (off the main thread). */
    private func loadKeptCounts(_ rows: [LibraryRow]) {
        let wanted = rows.filter { !$0.isHeader && !$0.id.isEmpty && $0.source != "liked" }
        let keys = Set(wanted.map { "\($0.source):\($0.id)" })
        if keys == keptCountKeys { return }
        keptCountKeys = keys
        let items = wanted.map { ("\($0.source):\($0.id)", playlistKey($0)) }
        let cache = deviceCache
        Task {
            let found = await Task.detached(priority: .utility) { () -> [String: Int] in
                var out: [String: Int] = [:]
                for (key, file) in items {
                    if let kept = cache.playlist(file), !kept.hasMore, !kept.tracks.isEmpty { out[key] = kept.tracks.count }
                }
                return out
            }.value
            keptCounts.merge(found) { _, new in new }
            recount()
        }
    }

    /**
     * The songs held for a playlist right now: Liked is the liked list, a
     * service playlist its saved list, an opened one that is all here its
     * songs. nil when none is held.
     */
    private func heldTracks(_ row: LibraryRow) -> [Track]? {
        if row.source == "liked" { return likedKnown ? likedTracks : nil }
        if let entry = savedPlaylists["\(row.source):\(row.id)"] {
            let tracks = Sync.tracks(entry.arr("tracks")).map(giveVideoId)
            if !tracks.isEmpty { return tracks }
        }
        let s = state
        if let open = s.selectedPlaylist, open.source == row.source, open.id == row.id,
           !s.playlistTracks.isEmpty, !s.playlistHasMore, !s.playlistLoading {
            return s.playlistTracks
        }
        return nil
    }

    private func musicDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Maro", isDirectory: true)
    }

    private func keptDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kept", isDirectory: true)
    }

    private func indexKeptFiles() -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: keptDirectory(), includingPropertiesForKeys: nil)) ?? []
        var out: [String: URL] = [:]
        for f in files where audioExtensions.contains(f.pathExtension) && ArtLoader.size(of: f) > 0 {
            out[f.deletingPathExtension().lastPathComponent] = f
        }
        return out
    }

    private func indexLocalFiles() -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: musicDirectory(), includingPropertiesForKeys: nil)) ?? []
        var out: [String: URL] = [:]
        for f in files where audioExtensions.contains(f.pathExtension) && ArtLoader.size(of: f) > 0 {
            out[f.deletingPathExtension().lastPathComponent] = f
        }
        return out
    }

    private func videoIdOf(_ t: Track) -> String {
        if !t.videoId.isEmpty { return t.videoId }
        return t.source == "ytm" ? t.id : (trackMap[t.id] ?? "")
    }

    private func loadDeviceState() async {
        let cache = deviceCache
        let (map, songs) = await Task.detached { (cache.trackMap(), cache.downloadedSongs()) }.value
        trackMap.merge(map) { _, new in new }
        localFiles = indexLocalFiles()
        keptFiles = indexKeptFiles()
        state.songs = songs.filter { localFiles[videoIdOf($0)] != nil }
    }

    private func refreshTrackMap() async {
        guard let fresh = await client.trackMap() else { return }
        trackMap.merge(fresh.map) { _, new in new }
        serverCached = fresh.cached
        serverMapLoaded = true
        saveTrackMapSoon()
    }

    private func learn(_ trackId: String, _ videoId: String) {
        if trackId.isEmpty || videoId.isEmpty || trackId == videoId { return }
        if trackMap.updateValue(videoId, forKey: trackId) != videoId { saveTrackMapSoon() }
    }

    private func saveTrackMapSoon() {
        if trackMapSave != nil { return }
        trackMapSave = Task {
            await sleep(seconds: 2)
            let map = trackMap, cache = deviceCache
            await Task.detached { cache.saveTrackMap(map) }.value
            trackMapSave = nil
        }
    }

    private func refreshPhoneStorage() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let music = (try? FileManager.default.contentsOfDirectory(at: musicDirectory(), includingPropertiesForKeys: nil)) ?? []
        state.phoneAvailableBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        state.phoneTotalBytes = Int64(values?.volumeTotalCapacity ?? 0)
        state.phoneMusicBytes = music.reduce(0) { $0 + ArtLoader.size(of: $1) }
        state.phoneMusicCount = music.count
        state.phoneCacheBytes = ArtLoader.shared.diskBytes()
        let kept = ((try? FileManager.default.contentsOfDirectory(at: keptDirectory(), includingPropertiesForKeys: nil)) ?? [])
            .filter { audioExtensions.contains($0.pathExtension) }
        state.phoneKeptBytes = kept.reduce(0) { $0 + ArtLoader.size(of: $1) }
        state.phoneKeptCount = kept.count
        state.playlistCacheCount = deviceCache.playlistCount()
    }

    func setSongsLimit(_ gb: Int) {
        state.songsLimitGb = gb
        prefs.set(gb, forKey: "songsLimitGb")
        trimKeptSongs()
        showStatus(gb == 0 ? "Songs on disk: unlimited" : "Songs on disk: up to \(gb) GB", "ok")
    }

    /**
     * Over the limit for songs on disk, the songs this phone kept as they
     * played go, the ones played longest ago first. Songs you saved stay.
     */
    private func trimKeptSongs() {
        let gb = state.songsLimitGb
        guard gb > 0 else { return }
        let limit = Int64(gb) * 1_073_741_824
        let keptDir = keptDirectory(), musicDir = musicDirectory()
        Task {
            let removed = await Task.detached(priority: .utility) { () -> [String] in
                let fm = FileManager.default
                let saved = ((try? fm.contentsOfDirectory(at: musicDir, includingPropertiesForKeys: nil)) ?? [])
                    .reduce(Int64(0)) { $0 + ArtLoader.size(of: $1) }
                let kept = ((try? fm.contentsOfDirectory(at: keptDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                    .map { f -> (URL, Int64, Date) in
                        (f, ArtLoader.size(of: f), (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    }
                    .sorted { $0.2 < $1.2 }
                var total = saved + kept.reduce(Int64(0)) { $0 + $1.1 }
                var gone: [String] = []
                for entry in kept where total > limit {
                    try? fm.removeItem(at: entry.0)
                    total -= entry.1
                    gone.append(entry.0.deletingPathExtension().lastPathComponent)
                }
                return gone
            }.value
            for id in removed { keptFiles.removeValue(forKey: id) }
            if !removed.isEmpty { refreshPhoneStorage() }
        }
    }

    /**
     * Which song ids on this phone play without the network: the files saved
     * in the music directory plus whatever maps to them. Kept on the state so
     * rows can grey out songs that will not play.
     */
    private func publishLocalAvailable() {
        var available = Set(localFiles.keys)
        for t in state.songs {
            let v = videoIdOf(t)
            if !v.isEmpty { available.insert(v) }
        }
        // One song, several ids: search results come back keyed by the source
        // id while the file is keyed by its video id, so register every id
        // that pipes back into a file we already hold.
        for (sourceId, vid) in trackMap where available.contains(vid) { available.insert(sourceId) }
        OnPhoneSongs.sync(available)
        if state.localAvailable != available { state.localAvailable = available }
        // The desktop's saved-set is the phone's business to tell, whichever
        // device is playing, so it is pushed here on connect and every change.
        if state.signedIn && !available.isEmpty {
            let body: JSON = ["device": deviceId(), "name": Omp.phoneName, "saved": available.sorted()]
            Task { _ = await client.postAction("phone.state", body) }
        }
    }

    private func persistLocalQueueSoon(_ tracks: [Track], name: String) {
        if !localDirty { return }
        localQueueSave?.cancel()
        localQueueSave = Task {
            await sleep(seconds: 1)
            if Task.isCancelled { return }
            let cache = deviceCache
            await Task.detached { cache.saveLocalQueue(name: name, tracks) }.value
            localQueueOnDisk = true
        }
    }

    /**
     * Offline start-up: show the last account snapshot and playback queue from
     * disk before the first /sync has a chance to (or fails to) arrive, so a
     * restart never looks like everything was cleared.
     */
    private func restoreSnapshot() async {
        let cache = deviceCache
        let (raw, local, head) = await Task.detached { (cache.snapshot(), cache.localQueue(), cache.playhead()) }.value
        if let raw, let data = JSONText.parse(raw) as? JSON, let snap = data.obj("snapshot") {
            let at = data.str("at")
            if !at.isEmpty { lastSyncAt = at }
            state = parseSnapshot(snap, base: state)
        }
        // The phone's own queue. A saved one (even empty) wins; otherwise the
        // account queue becomes it, so the phone is never stranded at zero.
        if let local {
            localQueueOnDisk = true
            state.localQueue = local.tracks
            if local.tracks.isEmpty { state.localQueueIndex = -1 }
            state.localQueueName = local.name
            // Back where it was, paused: the song and the second it was at.
            if let head, local.tracks[safe: head.index]?.id == head.id {
                let track = local.tracks[head.index]
                state.localQueueIndex = head.index
                state.localTrack = track
                state.localPlaying = false
                if isPhone { progress = Progress(position: head.position, duration: track.duration, playing: false, anchor: uptime()) }
            }
        } else if !state.queue.isEmpty {
            state.localQueue = state.queue
        }
    }

    // A relay or pull succeeded, so the droplet is reachable.
    private func markOnline(_ up: Bool) {
        if state.online != up { state.online = up }
    }

    /**
     * On/off, and who else is around. Probe the droplet every so often; the
     * answer is the account's device list, so the picker shows a phone that
     * came online after this one without a restart.
     */
    private func startConnectivityWatch() {
        Task { [weak self] in
            while true {
                await sleep(seconds: 10)
                guard let self else { return }
                let account = await self.client.account()
                self.markOnline(account != nil)
                if let account { self.applyAccount(account) }
            }
        }
    }

    // -- state pull ---------------------------------------------------------

    private func pullAccount() async {
        if let account = await client.account() { applyAccount(account) }
    }

    private func applyAccount(_ response: JSON) {
        guard let a = response.obj("account") else { return }
        let devices = (a.arr("devices") ?? []).compactMap { $0 as? JSON }.map {
            Device(id: $0.str("device"), name: $0.str("name"), kind: $0.str("kind"), connected: $0.bool("connected"), isPlayback: $0.bool("playback"), solo: $0.bool("solo"))
        }
        state.devices = devices
        state.playbackTarget = a.str("playback")
    }

    // -- the shared player ---------------------------------------------------
    //
    // One queue, one song and one playhead per account, held by the droplet,
    // like Spotify Connect. Exactly one device makes the sound; every other
    // one shows the same state and its presses go to that device. Picking a
    // device only moves the sound: the new one carries on with the same queue
    // at the same second. "Play music on this device only" (solo) leaves this
    // phone out of it: its own queue, its own playback, hidden from the lists.

    private var playerDoc: JSON?
    private var playerQueue: [Track] = []
    private var playerQueueRev = -1
    private var playerActive = false
    private var lastPublishedKey: [AnyHashable] = []
    private var lastPublishedQueue: [Track]?
    private var lastPublishedPos: Double = 0
    private var lastPublishedAt: Double = 0
    private var lastPublishedPlaying = false
    private var publishedOnce = false

    /** What the shared player is doing right now. */
    private func syncPlayer() async {
        if solo { return }
        if let doc = await client.getPlayer() { await applyPlayer(doc) }
        // The account's preferences moved on while this phone wasn't listening.
        if client.prefsRev > prefsRev { await pullPrefs(force: true) }
    }

    private func applyPlayer(_ incoming: JSON) async {
        if solo { return }
        var doc = incoming
        if doc["queue"] == nil && doc.int("queueRev") != playerQueueRev, let full = await client.getPlayer() {
            doc = full                          // a queue change we did not get the list for
        }
        if let prev = playerDoc, doc.int("rev") < prev.int("rev") { return }
        if doc["queue"] != nil {
            playerQueue = Sync.tracks(doc.arr("queue")).map(giveVideoId)
            playerQueueRev = doc.int("queueRev")
        }
        playerDoc = doc
        let device = doc.str("device")
        let active = device == deviceId()
        let wasActive = playerActive
        playerActive = active
        let queue = playerQueue
        let index = doc.int("index", -1)
        let playing = doc.bool("playing")
        let lag = max(0, doc.double("serverNow") - doc.double("positionAt")) / 1000
        let position = doc.double("position") + (playing ? lag : 0)
        let track = queue[safe: index]
        let name = doc.str("name")
        // The shared state: what every device shows while another one plays.
        var s = state
        s.queue = queue
        s.queueIndex = index
        s.queueName = name
        s.track = track
        s.playing = playing
        s.repeat = doc.str("repeat", "off")
        s.shuffle = doc.bool("shuffle")
        s.volume = doc.int("volume", s.volume)
        s.playbackTarget = device
        s.origin = ""
        state = s
        if active {
            if !wasActive { takeOver(queue, index, name, doc, position, playing) }
        } else {
            // Another device makes the sound: this phone is its remote, and
            // shows the bitrate of the copy that device is playing.
            if let a = doc.obj("audio"), !a.str("videoId").isEmpty {
                setSounding(a.str("videoId"), copy: a.str("copy"), kbps: a.int("kbps"),
                            inTier: a["inTier"] as? Bool, route: "remote")
            } else {
                // The playing device did not say: nothing, not the last song's number.
                setSounding("", copy: "", kbps: 0, inTier: nil)
            }
            if isPhone { setPlaybackMode(.remoteDesktop) }
            phonePlayer?.pause()
            progress = Progress(position: position, duration: track?.duration ?? 0, playing: playing, anchor: uptime())
        }
    }

    /** The sound moved here: carry on with the shared queue, at its second. */
    private func takeOver(_ queue: [Track], _ index: Int, _ name: String, _ doc: JSON, _ position: Double, _ playing: Bool) {
        if !isPhone { setPlaybackMode(.standalonePhone) }
        localDirty = true
        publishedOnce = false
        log.info("the music moved here: \(queue.count) tracks at \(Int(position)) s")
        state.localRepeat = doc.str("repeat", "off")
        state.localShuffle = doc.bool("shuffle")
        if queue.isEmpty { return }
        let start = min(max(index, 0), queue.count - 1)
        if playing {
            pendingSeek = position
            playLocalQueue(queue, start, name: name)
        } else {
            // Paused where the other device left it; play starts it here.
            phonePlayer?.stop()
            var s = state
            s.localQueue = queue
            s.localQueueIndex = start
            s.localQueueName = name
            s.localTrack = queue[start]
            s.localPlaying = false
            s.localPreparing = false
            state = s
            progress = Progress(position: position, duration: queue[start].duration, playing: false, anchor: uptime())
        }
    }

    /**
     * Report what this phone plays to the shared player: on any change, on a
     * jump of the playhead, and every 15 s while playing.
     */
    private func publishPlayer(force: Bool = false) async {
        guard !solo, state.signedIn, isPhone else { return }
        let owner = playerDoc?.str("device") ?? ""
        if !owner.isEmpty && owner != deviceId() { return }
        let s = state
        if owner.isEmpty && !s.localPlaying && !force { return }
        let now = uptime()
        let pos = progress.at(now)
        let key: [AnyHashable] = [s.localQueueIndex, s.localPlaying, s.localShuffle, s.localRepeat, s.volume, s.localQueueName,
                                  s.audioVideoId, s.audioCopy]
        let queueChanged = !publishedOnce || lastPublishedQueue != s.localQueue
        let expected = lastPublishedPos + (lastPublishedPlaying ? now - lastPublishedAt : 0)
        let due = force || !publishedOnce || key != lastPublishedKey || queueChanged
            || abs(pos - expected) > 3 || (s.localPlaying && now - lastPublishedAt > 15)
        if !due { return }
        publishedOnce = true
        lastPublishedKey = key
        lastPublishedQueue = s.localQueue
        lastPublishedPos = pos
        lastPublishedAt = now
        lastPublishedPlaying = s.localPlaying
        var body: JSON = [
            "device": deviceId(), "index": s.localQueueIndex, "name": s.localQueueName,
            "playing": s.localPlaying, "shuffle": s.localShuffle, "repeat": s.localRepeat,
            "volume": s.volume, "position": pos,
        ]
        if !s.audioVideoId.isEmpty {
            // Which copy is sounding here, so every other device can show its
            // live bitrate too.
            body["audio"] = ["videoId": s.audioVideoId, "copy": s.audioCopy, "kbps": s.audioKbps,
                             "tier": AudioCache.rung(), "inTier": s.audioInTier.map { $0 as Any } ?? NSNull()]
        }
        if queueChanged { body["queue"] = s.localQueue.map { $0.toJSON() } }
        playerActive = true
        guard let out = await client.putPlayer(body) else {
            ConsoleLog.shared.log("SharedPlayer", "PUT /player returned no response")
            publishedOnce = false               // try again next pass
            return
        }
        if !out.bool("ok"), let moved = out.obj("player") {
            ConsoleLog.shared.log("SharedPlayer", "PUT /player rejected: playback moved to another device")
            await applyPlayer(moved)            // the sound moved elsewhere meanwhile
        } else if out.bool("ok") {
            playerQueueRev = out.int("queueRev", playerQueueRev)
            var doc = playerDoc ?? [:]
            doc["device"] = deviceId()
            doc["rev"] = out.int("rev")
            playerDoc = doc
        }
    }

    /** Play music on this phone only, or join the shared player again. */
    func setSolo(_ enabled: Bool) {
        solo = enabled
        prefs.set(enabled, forKey: "playSolo")
        state.solo = enabled
        if enabled {
            playerDoc = nil
            playerActive = false
            setPlaybackMode(.standalonePhone)
            showStatus("Playing on this phone only", "ok")
        } else {
            publishedOnce = false
            Task { await syncPlayer() }
            showStatus("Back on the shared player", "ok")
        }
    }

    /**
     * A press while another device makes the sound: the droplet hands it to
     * that device, or to this phone when that one has gone away.
     */
    private func remote(_ action: String, _ payload: JSON = [:]) {
        let client = client, me = deviceId()
        Task {
            if !(await client.playerCommand(action, payload, from: me)) {
                showStatus("Could not reach the playing device", "error")
            }
        }
    }

    /** Play `tracks` from `index`, here or on whichever device plays. */
    private func playList(_ tracks: [Track], _ index: Int, name: String?) {
        if tracks.isEmpty { return }
        if isPhone { return playLocalQueue(tracks, index, name: name) }
        let start = min(max(index, 0), tracks.count - 1)
        showRemote(tracks[start], start)
        state.queue = tracks
        if let name { state.queueName = name }
        remote("playtracks", ["tracks": tracks.map { $0.toJSON() }, "index": start, "name": name ?? ""])
    }

    private func pullSync(force: Bool = false) async {
        guard let data = await client.sync() else { return }
        markOnline(true)
        // The stored song lists' index (counts, and which held copies are behind).
        await refreshAccountIndex(force: force)
        let at = data.str("at")
        if !force && !at.isEmpty && at == lastSyncAt { return }
        lastSyncAt = at
        guard let snap = data.obj("snapshot") else { return }
        let incoming = parseSnapshot(snap, base: state)
        let current = state
        let adopted = !incoming.queue.isEmpty || current.queue.isEmpty || uptime() - queueClearedAt < queueClearWindow
        if adopted {
            state = incoming
        } else {
            var merged = incoming
            merged.queue = current.queue
            merged.queueIndex = current.queueIndex
            state = merged
        }
        // A standalone phone with no playback yet mirrors the account queue, so
        // the shared queue is never invisible. Once it plays something, its own
        // queue is its own, and the engine mirrors it back the other way.
        if isPhone && !localDirty && !localQueueOnDisk && state.localQueue.isEmpty && !state.queue.isEmpty {
            state.localQueue = state.queue
            state.localQueueIndex = state.queueIndex
        }
        // Keep the on-disk copy in sync with whatever the app actually shows,
        // so a restart offline lands on the same queue as the screen.
        var persisted = data
        if !adopted, var snap2 = persisted.obj("snapshot") {
            snap2["queue"] = current.queue.map { $0.toJSON() }
            snap2["queueIndex"] = current.queueIndex
            persisted["snapshot"] = snap2
        }
        let bytes = JSONText.data(persisted), cache = deviceCache
        Task.detached { cache.saveSnapshot(bytes) }
        if state.playbackMode == .remoteDesktop && progress.anchor == 0 {
            progress = Progress(position: snap.double("position"), duration: state.track?.duration ?? 0, playing: state.playing, anchor: uptime())
        }
        // Spotify lists the account holds no recent copy of, read here.
        syncSpotifyLists()
    }

    /** One song reaches the panel as a Spotify id; the saved copy lives under
     *  the resolved video id. Stick that on the track so the row knows it is
     *  on this phone (and playback does not resolve it twice). */
    private func giveVideoId(_ t: Track) -> Track {
        if !t.videoId.isEmpty { return t }
        let v = videoIdOf(t)
        return v.isEmpty ? t : t.with(videoId: v)
    }

    private func parseSnapshot(_ snap: JSON, base: UiState) -> UiState {
        let cur = Track.from(snap.obj("current"))
        let likedArr = snap.arr("liked")
        let providers = snap.obj("providers")
        let spotify = providers?.obj("spotify")
        let ytm = providers?.obj("youtubeMusic")
        let recent = Sync.tracks(snap.arr("recent"))
        var s = base
        // On the shared player, the queue and song come from it, not from the
        // desktop's snapshot.
        let shared = playerDoc != nil && !solo
        if !shared {
            s.queue = Sync.tracks(snap.arr("queue")).map(giveVideoId)
            s.queueIndex = snap.int("queueIndex", base.queueIndex)
            s.queueName = snap.str("queueName", base.queueName)
        }
        if base.playbackMode == .remoteDesktop { s.volume = snap.int("volume", base.volume) }
        if !shared && (!cur.title.isEmpty || !cur.id.isEmpty) { s.track = cur }
        if !recent.isEmpty { s.recent = recent }
        s.likedKeys = Sync.likedKeys(likedArr)
        likedTracks = Sync.tracks(likedArr).map(giveVideoId)
        if likedArr != nil { likedKnown = true }
        s.likedIds = Set(likedTracks.flatMap(\.trackIds))
        if s.selectedPlaylist?.source == "liked" {
            s.playlistTracks = likedTracks
            s.playlistTotal = likedTracks.count
        }
        // The saved song lists first: the rows' counts are their lengths.
        mergeSaved(Sync.savedPlaylists(snap.obj("savedPlaylists")))
        s.library = Sync.library(snap.obj("playlists"))
        applyCounts(&s)
        // What the desktop streams and downloads at: its setting, shared.
        if let quality = snap.obj("quality") {
            s.quality = quality.str("stream", s.quality).ifEmpty(s.quality)
            s.downloadQuality = quality.str("download", s.downloadQuality).ifEmpty(s.downloadQuality)
        }
        if let spotify {
            s.spotifyConnected = spotify.bool("connected")
            s.spotifyApiConnected = spotify.bool("apiConnected")
            s.spotifyAccountName = spotify.str("accountName")
        }
        if let ytm {
            s.ytmConnected = ytm.bool("connected")
            s.ytmAccountName = ytm.str("accountName")
        }
        // A sign-in that has just gone through closes its prompt.
        if let prompt = s.loginPrompt,
           (prompt.service == "spotify" && s.spotifyConnected) || (prompt.service == "ytm" && s.ytmConnected) {
            s.loginPrompt = nil
        }
        return s
    }

    /** Relay events arrive in bursts; one /sync after the burst is enough. */
    private func scheduleSync() {
        if syncTask != nil { return }
        syncTask = Task {
            await sleep(seconds: 0.8)
            await pullSync()
            syncTask = nil
        }
    }

    // -- relay events -------------------------------------------------------

    private func onRelayMessage(_ msg: JSON) {
        let p = msg.obj("payload") ?? [:]
        switch msg.str("type") {
        case "player":
            let doc = p
            Task { await applyPlayer(doc) }
            return
        case "nowPlaying":
            // The shared player says what plays; this is the old way.
            if playerDoc != nil && !solo { return }
            let t = Relay.trackFromNowPlaying(p)
            if !t.id.isEmpty || !t.title.isEmpty { state.track = t }
            state.playing = p.bool("playing", state.playing)
            if state.playbackMode == .remoteDesktop {
                progress = Progress(
                    position: p.double("position"),
                    duration: t.duration > 0 ? t.duration : state.track?.duration ?? 0,
                    playing: state.playing,
                    anchor: uptime()
                )
            }
        case "cloud.audio":
            onCloudAudio(p)
            return
        case "lyrics":
            // The desktop engine's answer to "lyrics.get".
            let id = p.str("trackId")
            if let found = SongLyrics.from(id, p.obj("lyrics")) {
                remember(found, id)
                if lyrics.trackId == id { lyrics = found }
            }
            return
        case "control":
            // The pump starts from the droplet's whole backlog, so a command
            // from a while ago must not replay on launch.
            let sent = ISO8601DateFormatter.flexible(msg.str("sentAt"))
            if let sent, Date().timeIntervalSince(sent) < 30 { onControl(p) }
            return
        case "login":
            let prompt = LoginPrompt(service: p.str("service"), url: p.str("url"), code: p.str("code"), error: p.str("error"))
            // Spotify's page does the whole sign-in; YouTube Music needs its
            // code shown first.
            if prompt.error.isEmpty && prompt.code.isEmpty && !prompt.url.isEmpty { openUrl(prompt.url) }
            state.loginPrompt = prompt
            return
        case "session.request", "session.offer", "ytm.request", "ytm.result", "ytm.pending",
             "ytm.handover", "ytm.handover.ack", "devices.changed", "ytm.holder":
            // Between this account's devices (round 2 I).
            DeviceLink.shared.handle(msg)
            return
        case "prefs":
            // Another device changed the account's preferences.
            applyPrefs(p)
            return
        case "playlist.tracks":
            onPlaylistPage(p)
        case "search":
            break       // searches are answered on this phone itself now
        default:
            break
        }
        scheduleSync()
    }

    private func onPlaylistPage(_ p: JSON) {
        guard let selected = state.selectedPlaylist, selected.source == p.str("source"), selected.id == p.str("id") else { return }
        let offset = p.int("offset")
        let page = Sync.tracks(p.arr("tracks"))
        let before = state.playlistTracks
        var seen = Set<String>()
        let merged = (Array(before.prefix(offset)) + page + Array(before.dropFirst(offset + page.count)))
            .filter { seen.insert($0.id.ifEmpty($0.title)).inserted }
        let total = p.int("total"), hasMore = p.bool("hasMore")
        state.playlistTracks = merged
        state.playlistLoading = false
        state.playlistLoadingMore = false
        state.playlistHasMore = hasMore
        state.playlistTotal = total
        state.playlistError = p.bool("restricted") ? p.str("hint") : p.str("error")
        let key = playlistKey(selected), cache = deviceCache
        Task.detached { cache.savePlaylist(key, merged, total: total, hasMore: hasMore) }
        // Every page here: the row counts the list it now holds.
        if !hasMore && !merged.isEmpty {
            keptCounts["\(selected.source):\(selected.id)"] = merged.count
            recount()
        }
        if playWhenLoaded == selected.id && !merged.isEmpty {
            playWhenLoaded = nil
            playList(merged, 0, name: selected.name)
        }
    }

    private func onCloudAudio(_ p: JSON) {
        let ready = p.str("state") == "ready"
        let videoId = p.str("videoId")
        let job = pending.removeValue(forKey: p.str("requestId"))
        if ready && !videoId.isEmpty {
            serverCached.insert(videoId)
            learn(p.str("trackId").ifEmpty(job?.track.id ?? ""), videoId)
        }
        guard let job else { return }
        let error = p.str("error").ifBlank("Cloud audio is unavailable")
        switch job.purpose {
        case .play(let tag):
            if tag != playTag || startedTag == tag { return }
            if ready {
                playRoute = "engine"
                playStreamAtTier(videoId, tag: tag, duration: job.track.duration)
            } else {
                // No match on either provider, or the upload failed: skip
                // this song rather than leave the player paused on it.
                log.warning("cloud.audio failed for \(job.track.title, privacy: .public): \(error, privacy: .public)")
                skipCurrent()
            }
        case .warm:
            if ready { AudioCache.precache(videoId) }
        case .save:
            if ready { saveLocal(job.track, videoId, announce: true) } else { showStatus(error, "error") }
        case .download:
            // Hand the finished upload to the downloader, which counts it and
            // copies it to the phone in its own time.
            downloadInbox.append(Downloaded(ready: ready, track: job.track.with(videoId: videoId.ifEmpty(job.track.videoId)), error: p.str("error")))
        }
    }

    // -- phone playback -----------------------------------------------------

    /** Play [queue] from [index] on the phone. The UI updates first; audio follows. */
    private func playLocalQueue(_ queue: [Track], _ index: Int, name: String?) {
        if queue.isEmpty { return }
        localDirty = true
        persistLocalQueueSoon(queue, name: name ?? state.localQueueName)
        var start = min(max(index, 0), queue.count - 1)
        if !state.online && !canPlayOffline(queue[start]) {
            // Offline and this song is not on the phone: skip to the nearest
            // saved song instead of failing the queue on it.
            var skipped = 0
            while skipped < queue.count && !canPlayOffline(queue[start]) {
                start = (start + 1) % queue.count
                skipped += 1
            }
            if skipped >= queue.count {
                state.localPreparing = false
                state.localPlaying = false
                state.localError = "Offline and no saved songs on this phone"
                phonePlayer?.stop()
                return
            }
        }
        let track = queue[start]
        var s = state
        s.localQueue = queue
        s.localQueueIndex = start
        if let name { s.localQueueName = name }
        s.localTrack = track
        s.localPlaying = false
        s.localPreparing = true
        s.localError = ""
        state = s
        startTrack(track)
        warm((1...3).compactMap { queue[safe: start + $0] })
    }

    private func canPlayOffline(_ track: Track) -> Bool {
        let v = videoIdOf(track)
        return !v.isEmpty && localFiles[v] != nil
    }

    private func startTrack(_ track: Track) {
        playTag += 1
        let tag = playTag
        tapAt = uptime()
        watchStart(tag, track)
        saveTask?.cancel()
        progress = Progress(position: 0, duration: track.duration, playing: false, anchor: tapAt)
        sounding = nil
        // "Play on SoundCloud" for this one song, or "Prefer SoundCloud" in
        // Settings. Picked by hand, a full upload by someone else will do and
        // a saved copy is skipped (as on the desktop); the standing setting
        // only takes the artist's own upload.
        let oneOff = oneOffPrefer.removeValue(forKey: track.id)
        let prefer = oneOff ?? state.playbackSource
        // The saved choice stays as it is; this phone just can't follow it now.
        if oneOff == nil && prefer == "spotify" && track.source == "spotify" && !Spotify.shared.hasLogin && !preferNoteShown {
            preferNoteShown = true
            showStatus("Spotify isn't signed in on this device - playing from YouTube Music", "info")
        }
        log.info("tap \(track.title, privacy: .public) (\(track.source, privacy: .public)) prefer=\(prefer, privacy: .public) spotifyLogin=\(Spotify.shared.hasLogin) spotifyReady=\(Spotify.shared.ready)")
        if prefer == "spotify" && track.source == "spotify" && Spotify.shared.hasLogin {
            if !spotifyCanStart() { return playYouTubeInstead(track, tag: tag) }
            return playSpotifyHere(track, tag: tag)
        }
        if oneOff == "spotify" && track.source != "spotify" && Spotify.shared.hasLogin {
            playRoute = "spotify"
            Task { @MainActor in
                let found = await Spotify.shared.search("\(track.title) \(track.artist)")
                guard tag == playTag else { return }
                if let alt = found.first(where: { Match.sameSong($0, track) }) {
                    playSpotifyHere(alt, tag: tag, display: track)
                } else {
                    showStatus("Spotify doesn't have this song - playing it the usual way", "info")
                    startUsual(track, tag: tag)
                }
            }
            return
        }
        if prefer == "sc" && track.source != "sc" {
            playRoute = "soundcloud"
            Task { @MainActor in
                let alt = await SoundCloud.shared.equivalent(of: track, loose: oneOff != nil)
                guard tag == playTag else { return }
                if let alt {
                    playSoundCloud(alt, tag: tag, fallback: track)
                } else {
                    if oneOff != nil { showStatus("SoundCloud has no full-length copy of this song - playing it the usual way", "info") }
                    startUsual(track, tag: tag)
                }
            }
            return
        }
        startUsual(track, tag: tag)
    }

    private func startUsual(_ track: Track, tag: Int) {
        let videoId = videoIdOf(track)
        let saved = (localFiles[videoId] ?? keptFiles[videoId]).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if !saved, track.source == "ytm", let why = state.gone[videoId] {
            state.localError = "Skipped \(track.title): \(why)"
            return skipCurrent()
        }
        if let file = localFiles[videoId] ?? keptFiles[videoId], FileManager.default.fileExists(atPath: file.path) {
            playRoute = "file"
            // Played now: the last a limit on songs on disk lets go.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            // A saved song's rate is its size over its length: the file is the
            // whole song, so that is exactly what is being heard.
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.doubleValue ?? 0
            let kbps = track.duration > 1 ? Int(bytes * 8 / track.duration / 1000) : 0
            // Saved from one of the droplet's copies; the one that measures the
            // same is the one whose timeline describes it.
            var copy = ""
            if let v = AudioCache.variant(videoId), abs(v.kbps - kbps) < 20, v.name.contains(".") { copy = v.name }
            setSounding(videoId, copy: copy, kbps: kbps, inTier: kbps > 0 ? AudioCache.inTier(kbps) : nil)
            phone.playFile(file, tag: tag, duration: track.duration)
            // A saved file is on the phone already: count it now, for free,
            // when the droplet has no graph of that copy.
            Task { @MainActor in
                guard let line = await RateMeter.shared.measure(key: "file:" + file.lastPathComponent, file: file),
                      tag == playTag, state.audioTimeline.isEmpty else { return }
                state.audioTimeline = line
            }
        } else if track.source == "spotify" && Spotify.shared.hasLogin {
            if spotifyCanStart() { playSpotifyHere(track, tag: tag) } else { playYouTubeInstead(track, tag: tag) }
        } else if track.source == "sc" {
            playRoute = "soundcloud"
            playSoundCloud(track, tag: tag, fallback: nil)
        } else if !videoId.isEmpty && (serverCached.contains(videoId) || !serverMapLoaded) {
            playRoute = AudioCache.isWarm(videoId) ? "warm asset" : "stream"
            playStreamAtTier(videoId, tag: tag, duration: track.duration)
        } else if !videoId.isEmpty {
            playYouTubeDirect(videoId, track: track, tag: tag)
        } else {
            playRoute = "engine"
            phone.stop()
            requestCloud(videoId.isEmpty ? track : track.with(videoId: videoId), .play(tag: tag))
        }
    }

    /**
     * A SoundCloud song from SoundCloud itself, this phone's own request. One
     * it will not stream (DRM, preview only) goes the way it always went.
     */
    private func playSoundCloud(_ track: Track, tag: Int, fallback: Track?) {
        Task { @MainActor in
            do {
                let stream = try await SoundCloud.shared.resolve(track.id)
                guard tag == playTag else { return }
                let copy = "sc:" + track.id
                sounding = (copy, stream.url, stream.hls)
                setSounding("", copy: copy, kbps: stream.kbps, inTier: nil, route: "soundcloud")
                state.audioRoute = "soundcloud"
                // SoundCloud's own statement of the length beats whatever the
                // queue row carried; the player never invents one.
                let length = stream.duration > 0 ? stream.duration : track.duration
                phone.playURL(stream.url, tag: tag, duration: length)
                if state.statsOpen { measureSounding() }
            } catch {
                guard tag == playTag else { return }
                log.info("soundcloud \(track.id) not playable here: \(String(describing: error))")
                // A stand-in that will not play: the row's own song, the usual way.
                if let fallback { return startUsual(fallback, tag: tag) }
                // The engine has no SoundCloud of its own, so the same song is
                // played from YouTube as the desktop does.
                phone.stop()
                playYouTubeInstead(track, tag: tag)
            }
        }
    }

    /**
     * A YouTube song the droplet has no copy of: straight from YouTube, the
     * guest stream. Nothing is asked of any other device.
     */
    private func playYouTubeDirect(_ videoId: String, track: Track, tag: Int) {
        playRoute = "youtube"
        Task { @MainActor in
            do {
                let stream = try await YouTubeDirect.shared.audio(videoId)
                guard tag == playTag else { return }
                let copy = "yt:" + videoId
                sounding = (copy, stream.url, false)
                setSounding(videoId, copy: copy, kbps: stream.kbps, inTier: AudioCache.inTier(stream.kbps), route: "youtube")
                phone.playYouTube(stream.url, videoId: videoId, tag: tag, duration: track.duration)
                if state.statsOpen { measureSounding() }
            } catch let gone as YouTubeDirect.Gone {
                markGone(videoId, gone.reason)
                guard tag == playTag else { return }
                phone.stop()
                state.localError = "Skipped \(track.title): \(gone.reason)"
                skipCurrent()
            } catch {
                guard tag == playTag else { return }
                log.info("youtube \(videoId) direct refused: \(String(describing: error))")
                playRoute = "engine"
                phone.stop()
                requestCloud(track.with(videoId: videoId), .play(tag: tag))
            }
        }
    }

    /**
     * Whether a tap should go to Spotify: only when its player is connected
     * and not resting after a failure. A Spotify that is still connecting (or
     * cannot) used to cost every tap 4 s of silence before YouTube took over;
     * now the YouTube copy plays at once and Spotify is woken behind it.
     */
    private func spotifyCanStart() -> Bool {
        if uptime() < spotifyRestUntil { return false }
        if Spotify.shared.ready { return true }
        Spotify.shared.start()
        return false
    }

    /**
     * A song Spotify did not start (or is resting from): its YouTube copy,
     * straight from YouTube on this phone - the droplet's map first, else a
     * YouTube Music search here. The engine only when neither finds it.
     */
    private func playYouTubeInstead(_ track: Track, tag: Int) {
        playRoute = "youtube"
        Task { @MainActor in
            var vid = videoIdOf(track)
            if vid.isEmpty {
                let found = await YouTubeDirect.shared.search("\(track.title) \(track.artist.split(separator: ",").first.map(String.init) ?? "")")
                vid = found.first(where: { Match.sameSong($0, track) })?.id ?? ""
            }
            guard tag == playTag else { return }
            if vid.isEmpty {
                playRoute = "engine"
                requestCloud(track, .play(tag: tag))
                return
            }
            learn(track.id, vid)
            if serverCached.contains(vid) {
                // The droplet's copy: Premium, and usually loaded ahead.
                playRoute = AudioCache.isWarm(vid) ? "warm asset" : "stream"
                playStreamAtTier(vid, tag: tag, duration: track.duration)
                return
            }
            playYouTubeDirect(vid, track: track, tag: tag)
        }
    }

    /**
     * A Spotify song on this phone's own Spotify player (Spotify.swift), at
     * 320 kbps. `display` is the row on screen when it is a stand-in for a
     * song from another service.
     */
    private func playSpotifyHere(_ track: Track, tag: Int, display: Track? = nil) {
        playRoute = "spotify"
        Spotify.shared.start()
        sounding = nil
        setSounding("", copy: "", kbps: 0, inTier: nil, route: "spotify")
        state.audioRoute = "spotify"
        phone.onSpotifyRate = { [weak self] line, kbps, nominal in
            guard let self, tag == self.playTag else { return }
            self.state.audioTimeline = line
            self.state.audioKbps = kbps
            self.state.audioInTier = nominal > 0 ? nominal >= 320 : nil
        }
        phone.playSpotify("spotify:track:" + track.id, tag: tag,
                          duration: track.duration > 0 ? track.duration : (display?.duration ?? 0))
        // The queue's next Spotify song waits loaded on a standby player.
        let q = state.localQueue, i = state.localQueueIndex
        if let next = q[safe: i + 1], next.source == "spotify", !next.id.isEmpty {
            phone.stageSpotify("spotify:track:" + next.id)
        }
    }

    /**
     * No song may load forever. A route that has not started the song in
     * time is given up on: Spotify gets a new connection and one more try,
     * then the song goes the way a song Spotify will not play goes (your
     * server finds it on YouTube); a stream that hangs goes the failed-stream
     * way. Whatever took over gets 40 seconds, then the song is skipped.
     */
    private func watchStart(_ tag: Int, _ track: Track) {
        Task { @MainActor [weak self] in
            // Spotify starts a song in about a second: past 4 s it is not
            // going to (it waited 22 s here, then went the slow way).
            await sleep(seconds: 4)
            guard let self, tag == self.playTag, self.startedTag != tag, self.isPhone else { return }
            if self.playRoute == "spotify" {
                ConsoleLog.shared.log("Playback", "Spotify start timed out; trying YouTube")
                log.warning("spotify did not start \(track.title, privacy: .public) in 4 s; YouTube instead, new connection behind it")
                self.onFailed(tag: tag, notOnServer: true, message: "Spotify did not start the song")
            }
            await sleep(seconds: 6)
            guard tag == self.playTag, self.startedTag != tag else { return }
            if self.playRoute != "engine" && self.playRoute != "spotify" {
                // (The server fetching a song it has never had takes a while: that one is only waited for.)
                await sleep(seconds: 5)
                guard tag == self.playTag, self.startedTag != tag else { return }
                ConsoleLog.shared.log("Playback", "\(track.source) stream start timed out")
                self.onFailed(tag: tag, notOnServer: false, message: "The stream did not start")
            }
            await sleep(seconds: 40)
            guard tag == self.playTag, self.startedTag != tag else { return }
            log.warning("gave up on \(track.title, privacy: .public): nothing started it")
            self.showStatus("Couldn't start \(track.title) - skipped it", "error")
            self.skipCurrent()
        }
    }

    /**
     * Wi-Fi to 4G, or back. Connections and addresses from the old network
     * are dead: YouTube's stream addresses (tied to the old address), songs
     * half-loaded ahead, and the Spotify player's connection - which gets a
     * new one, and the song it was on is loaded again where it was. Going
     * from 4G onto Wi-Fi leaves the 4G connection working, so a Spotify song
     * playing then is left alone.
     */
    private func networkChanged(_ old: String, _ new: String) {
        log.info("network \(old, privacy: .public) -> \(new, privacy: .public)")
        Task { await YouTubeDirect.shared.forgetStreams() }
        AudioCache.clear()
        let playingSpotify = isPhone && state.localPlaying && phonePlayer?.onSpotify == true
        if old == "cellular" && new == "wifi" && playingSpotify { return }
        Spotify.shared.reconnect()
    }

    // -- where a song plays from -----------------------------------------

    /** "Play on..." for one press: the service picked for that song. */
    private var oneOffPrefer: [String: String] = [:]
    /** A stream this phone plays straight from a service, for the meter. */
    private var sounding: (copy: String, url: URL, hls: Bool)?

    /**
     * Play this song from the service picked. Here, SoundCloud plays from
     * SoundCloud and YouTube from YouTube; Spotify's own player comes to the
     * phone in a later update, so it is YouTube's copy until then. On the
     * desktop, the desktop does exactly what its own menu does.
     */
    func playOn(_ t: Track, _ service: String) {
        if !isPhone {
            remote("playtrack", ["track": t.toJSON(), "prefer": service])
            return
        }
        if service == "spotify" && !Spotify.shared.hasLogin {
            showStatus("Sign in to Spotify on the desktop first - playing YouTube Music's copy", "info")
        }
        oneOffPrefer[t.id] = service
        playTrack(t)
    }

    /** Count the stream playing now, once: for the "?" panel's graph. */
    private func measureSounding() {
        guard let s = sounding else { return }
        Task { @MainActor in
            guard let line = await RateMeter.shared.measure(key: s.copy, stream: s.url, hls: s.hls) else { return }
            timelines["/" + s.copy] = line
            if state.audioCopy == s.copy { state.audioTimeline = line }
        }
    }

    /**
     * Fix artwork: the droplet chooses the song's cover again from the best
     * source there is, and every device - this one first - gets the new one.
     * Straight to the droplet: no desktop needs to be on.
     */
    func fixArtwork(_ t: Track) {
        let key = t.artKey
        if key.isEmpty || state.artworkProgress[key] != nil { return }
        state.artworkProgress[key] = 5
        showStatus("Fixing the artwork for \(t.title)…", "info")
        Task {
            let ok = await ArtLoader.shared.refresh(t)
            state.artworkProgress[key] = nil
            showStatus(ok ? "Artwork fixed" : "No better artwork was found", ok ? "ok" : "error")
        }
    }

    /**
     * Stream the copy at the tier chosen in Settings - or the best below it,
     * which is what the droplet answers when it has nothing at the tier yet.
     * A song seen on screen has been asked already; one that has not waits at
     * most a moment for the answer, then plays the original.
     */
    private func playStreamAtTier(_ videoId: String, tag: Int, duration: Double) {
        func go() {
            guard tag == playTag else { return }
            let v = AudioCache.variant(videoId)
            let copy = (v?.name.contains(".") ?? false) ? v!.name : ""
            setSounding(videoId, copy: copy, kbps: v?.kbps ?? 0, inTier: v?.inTier)
            phone.playStream(videoId, tag: tag, duration: duration)
        }
        if AudioCache.variant(videoId) != nil { return go() }
        Task { @MainActor in
            let ask = Task { @MainActor in await AudioCache.lookup([videoId]) }
            let timeout = Task { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            // Whichever finishes first: the answer, or a second and a half.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await ask.value }
                group.addTask { await timeout.value }
                await group.next()
                group.cancelAll()
            }
            timeout.cancel()
            go()
        }
    }

    private var timelines: [String: [Int]] = [:]

    /**
     * Say which copy is sounding, and fetch its per-second bitrate from the
     * droplet once. Called for this phone's own playback and, from the shared
     * player, for whatever another device is playing.
     */
    private func setSounding(_ videoId: String, copy: String, kbps: Int, inTier: Bool?, route: String? = nil) {
        let key = videoId + "/" + copy
        let known = timelines[key] ?? []
        let how = videoId.isEmpty ? "" : (route ?? playRoute)
        if state.audioRoute != how { state.audioRoute = how }
        if state.audioVideoId != videoId || state.audioCopy != copy || state.audioKbps != kbps
            || state.audioInTier != inTier || state.audioTimeline != known {
            state.audioVideoId = videoId
            state.audioCopy = copy
            state.audioKbps = kbps
            state.audioInTier = inTier
            state.audioTimeline = known
        }
        if videoId.isEmpty || !known.isEmpty { return }
        let client = client
        Task { @MainActor in
            guard let line = await client.timeline(videoId, copy: copy) else { return }
            timelines[key] = line
            if timelines.count > 64 { timelines.removeAll() ; timelines[key] = line }
            if state.audioVideoId == videoId && state.audioCopy == copy { state.audioTimeline = line }
        }
    }

    private func requestCloud(_ track: Track, _ purpose: Purpose) {
        let requestId = UUID().uuidString.lowercased()
        pending[requestId] = Pending(track: track, purpose: purpose)
        send("cloud.prepare", ["requestId": requestId, "track": track.toJSON()])
    }

    /**
     * Get the start of these songs onto the phone before anyone taps them.
     * Songs the droplet has are loaded straight away; the rest are handed to
     * the engine to upload, and loaded when it says they are ready.
     */
    private func warm(_ tracks: [Track], ahead: Bool = true) {
        let now = uptime()
        var ask: [JSON] = []
        var onDroplet: [Track] = []
        for t in tracks where !t.id.isEmpty {
            let videoId = videoIdOf(t)
            if !videoId.isEmpty && localFiles[videoId] != nil { continue }
            if !videoId.isEmpty && serverCached.contains(videoId) {
                onDroplet.append(t.with(videoId: videoId))
                continue
            }
            // Asked once: the engine works through every ask and the droplet
            // keeps what it stores, so asking again only repeats the work.
            if warmAsked[t.id] != nil { continue }
            warmAsked[t.id] = now
            let requestId = UUID().uuidString.lowercased()
            let track = videoId.isEmpty ? t : t.with(videoId: videoId)
            pending[requestId] = Pending(track: track, purpose: .warm)
            ask.append(["requestId": requestId, "track": track.toJSON()])
        }
        if !ask.isEmpty { send("cloud.prepare", ["priority": "warm", "tracks": ask]) }
        if !onDroplet.isEmpty { warmAtTier(onDroplet, ahead: ahead) }
        warmDirect(Array(tracks.filter { t in
            let v = videoIdOf(t)
            return !t.id.isEmpty && t.source != "sc" && !(!v.isEmpty && (localFiles[v] != nil || serverCached.contains(v)))
        }.prefix(Self.directAhead)))
    }

    private static let directAhead = 12
    private var directAsked: [String: Double] = [:]
    private var noYouTubeMatch: Set<String> = []
    private var directRunning = 0
    private var directWaiting: [Track] = []

    /**
     * Songs on screen (or next in the queue) the droplet has no copy of: what
     * a tap would do - find it on YouTube Music, ask YouTube for its address,
     * start loading it - done before the tap, two at a time, so the tap
     * plays at once. On mobile data only the finding and the address.
     */
    private func warmDirect(_ tracks: [Track]) {
        let now = uptime()
        for t in tracks {
            // Again after half an hour: YouTube's addresses last a few hours.
            if let last = directAsked[t.id], now - last < 1800 { continue }
            directAsked[t.id] = now
            directWaiting.append(t)
        }
        while directRunning < 2, !directWaiting.isEmpty {
            let t = directWaiting.removeFirst()
            directRunning += 1
            Task { @MainActor in
                await readyFromYouTube(t)
                directRunning -= 1
                warmDirect([])
            }
        }
    }

    private func readyFromYouTube(_ t: Track) async {
        var vid = videoIdOf(t)
        if vid.isEmpty {
            if noYouTubeMatch.contains(t.id) { return }
            let found = await YouTubeDirect.shared.search("\(t.title) \(t.artist.split(separator: ",").first.map(String.init) ?? "")")
            vid = found.first(where: { Match.sameSong($0, t) })?.id ?? ""
            if vid.isEmpty {
                noYouTubeMatch.insert(t.id)
                return
            }
            learn(t.id, vid)
        }
        if serverCached.contains(vid) || localFiles[vid] != nil || state.gone[vid] != nil { return }
        do {
            let stream = try await YouTubeDirect.shared.audio(vid)
            AudioCache.prefetchYouTubeHead(stream.url)
        } catch let gone as YouTubeDirect.Gone {
            markGone(vid, gone.reason)
        } catch {}
    }

    /**
     * Songs the droplet already holds: find which copy each plays as at the
     * chosen tier, have the droplet fetch the tier for any below it, and warm
     * whichever copy plays now. Seen songs only - the rows on screen and the
     * next few in the queue.
     */
    /** `ahead`: the next songs in the queue, whose audio starts loading too (rows on screen: only the tier). */
    private func warmAtTier(_ tracks: [Track], ahead: Bool) {
        Task { @MainActor in
            await AudioCache.lookup(tracks.map { $0.videoId })
            let rung = AudioCache.rung()
            var below: [JSON] = []
            for t in tracks where AudioCache.variant(t.videoId)?.inTier == false {
                let mark = t.id + ":" + rung
                if warmAsked[mark] != nil { continue }
                warmAsked[mark] = uptime()
                below.append(["requestId": UUID().uuidString.lowercased(), "track": t.toJSON()])
            }
            if !below.isEmpty { send("cloud.prepare", ["priority": "warm", "quality": rung, "tracks": below]) }
            if ahead, let next = tracks.first { AudioCache.precache(next.videoId) }
            // The start of each song on screen (and next): a tap then plays from memory.
            AudioCache.prefetchHeads(tracks.prefix(12).map { $0.videoId })
        }
    }

    private var wantAt: Double = 0
    private var wantSent: [String: Double] = [:]

    /**
     * The rows on screen go to the droplet (POST /cache/audio/want, 30 at most,
     * not more often than every 1.5 s) so it holds their audio before a tap.
     * A song asked in the last ten minutes is not asked again.
     */
    private func wantVisible(_ tracks: [Track]) {
        let now = uptime()
        guard now - wantAt >= 1.5 else { return }
        // The songs, not just their YouTube ids: the droplet needs the source,
        // the id and the title to fetch one it has never had.
        var songs: [JSON] = []
        var asked: [String] = []
        for t in tracks where t.source != "sc" {
            let v = videoIdOf(t)
            if v.isEmpty || localFiles[v] != nil || keptFiles[v] != nil || serverCached.contains(v) { continue }
            if let last = wantSent[v], now - last < 600 { continue }
            songs.append(["source": t.source, "id": t.id, "videoId": v,
                          "title": t.title, "artist": t.artist, "duration": t.duration])
            asked.append(v)
            if songs.count == 30 { break }
        }
        guard !songs.isEmpty else { return }
        wantAt = now
        for v in asked { wantSent[v] = now }
        let client = client
        Task { await client.wantAudio(songs) }
    }

    /** The rows on screen settled: get them ready to play at a tap. */
    func prefetchVisible(_ tracks: [Track]) {
        // Whatever is on screen gets ready on the droplet, whichever device
        // plays: a tap from here, or on the one playing, should start at once.
        guard state.signedIn else { return }
        wantVisible(tracks)
        warm(Array(tracks.prefix(40)), ahead: false)
    }

    func onStarted(tag: Int) {
        if tag != playTag { return }
        startedTag = tag
        if pendingSeek > 1 {
            phone.seek(to: pendingSeek)
            pendingSeek = 0
        }
        log.info("ready \(Int((uptime() - self.tapAt) * 1000)) ms after tap via \(self.playRoute, privacy: .public)")
        failStreak = 0
        // Played, so the droplet keeps it for good.
        if let track = state.localTrack {
            let vid = videoIdOf(track), client = client
            if !vid.isEmpty { Task { await client.markPlayed(vid) } }
        }
        state.localPreparing = false
        state.localError = ""
        guard let track = state.localTrack else { return }
        let videoId = videoIdOf(track)
        if !videoId.isEmpty && localFiles[videoId] == nil {
            // Keep a copy once it has played a while: in the music folder when
            // saving offline, else in the caches folder so a replay is local.
            let offline = state.savingOffline
            saveTask = Task {
                await sleep(seconds: 10)
                guard !Task.isCancelled && tag == playTag else { return }
                if offline { saveLocal(track, videoId, announce: false) } else { await keepNow(videoId) }
            }
        }
    }

    func onProgress(position: Double, duration: Double, playing: Bool) {
        progress = Progress(position: position, duration: duration > 0 ? duration : state.localTrack?.duration ?? 0, playing: playing, anchor: uptime())
        if playing && loggedTag != playTag {
            loggedTag = playTag
            log.info("playing \(Int((uptime() - self.tapAt) * 1000)) ms after tap via \(self.playRoute, privacy: .public)")
        }
        if state.localPlaying != playing {
            state.localPlaying = playing
            if !playing { savePlayheadNow() }
        }
        updateNowPlaying()
    }

    private var lastPlayhead = ""

    /** Remember the song and second, so killing the app only pauses it. */
    private func savePlayheadNow() {
        guard let track = state.localTrack, localDirty || localQueueOnDisk else { return }
        let index = state.localQueueIndex, position = progress.at(uptime())
        let key = "\(index)|\(track.id)|\(Int(position))"
        if key == lastPlayhead { return }
        lastPlayhead = key
        let cache = deviceCache, id = track.id
        Task.detached { cache.savePlayhead(index: index, trackId: id, position: position) }
    }

    func onEnded() { advance(auto: true) }

    /**
     * A song that cannot play must not hold the queue hostage: after one
     * engine-assisted retry the player moves on to the next track. Consecutive
     * misses are capped so a queue of broken songs ends quietly.
     */
    /** YouTube took this song down: greyed out in the lists with the reason, never asked again. */
    private func markGone(_ videoId: String, _ reason: String) {
        guard !videoId.isEmpty, state.gone[videoId] != reason else { return }
        log.info("gone \(videoId, privacy: .public): \(reason, privacy: .public)")
        state.gone[videoId] = reason
        UserDefaults.standard.set(state.gone, forKey: "goneSongs")
    }

    func skipCurrent() {
        failStreak += 1
        state.localPreparing = false
        if failStreak >= skipStreakMax && state.localQueue.count > 1 {
            log.warning("\(self.failStreak) songs in a row could not play; stopping")
            failStreak = 0
            state.localPlaying = false
            state.localError = "Could not play the last few songs"
            phonePlayer?.stop()
            return
        }
        advance(auto: true, skipped: true)
    }

    func onFailed(tag: Int, notOnServer: Bool, message: String) {
        if tag != playTag { return }
        let track = state.localTrack
        let failedTrack = track.map { "\($0.source):\($0.id)" } ?? ""
        let trackContext = failedTrack.isEmpty ? "" : " (\(failedTrack))"
        ConsoleLog.shared.log("Playback", "\(playRoute) failed\(trackContext): \(message)")
        if let track, playRoute == "spotify", retriedTag != tag {
            // Spotify would not start it: YouTube from this phone now, and
            // Spotify left alone a while (a new connection made behind it).
            retriedTag = tag
            log.info("spotify failed (\(message, privacy: .public)); YouTube on the phone")
            spotifyRestUntil = uptime() + Self.spotifyRest
            Spotify.shared.reconnect()
            return playYouTubeInstead(track, tag: tag)
        }
        if let track, retriedTag != tag {
            retriedTag = tag
            let videoId = videoIdOf(track)
            // The droplet does not hold it (or its copy fails): straight from
            // YouTube at once, before downloading or waiting for the engine.
            if !videoId.isEmpty && track.source != "sc" && localFiles[videoId] == nil && keptFiles[videoId] == nil
                && state.gone[videoId] == nil && (notOnServer || playRoute == "stream" || playRoute == "warm asset") {
                serverCached.remove(videoId)
                log.info("droplet copy failed (\(message, privacy: .public)), YouTube directly")
                return playYouTubeDirect(videoId, track: track, tag: tag)
            }
            if !notOnServer && !videoId.isEmpty && localFiles[videoId] == nil {
                // The droplet has it but streaming it failed: fetch the whole
                // file once and play that, before bothering the engine.
                playRoute = "download"
                log.info("stream failed (\(message, privacy: .public)), downloading instead")
                Task {
                    let saved = await saveLocalNow(track, videoId)
                    guard tag == playTag, startedTag != tag else { return }
                    if saved, let file = localFiles[videoId] {
                        phone.playFile(file, tag: tag, duration: track.duration)
                    } else {
                        playRoute = "engine"
                        requestCloud(track.with(videoId: videoId), .play(tag: tag))
                    }
                }
                return
            }
            // Not on the droplet (or a broken copy): have the engine put it there.
            if notOnServer { serverCached.remove(videoId) }
            log.info("stream failed (\(message, privacy: .public)), asking the engine")
            playRoute = "engine"
            requestCloud(videoId.isEmpty ? track : track.with(videoId: videoId), .play(tag: tag))
            return
        }
        // The engine could not put it on the droplet either: move on.
        log.warning("gave up on \(track?.title ?? "", privacy: .public): \(message, privacy: .public)")
        skipCurrent()
    }

    private func advance(auto: Bool, skipped: Bool = false) {
        let s = state
        let queue = s.localQueue
        if queue.isEmpty { return }
        if auto && !skipped && s.localRepeat == "one" {
            phone.seek(to: 0)
            phone.play()
            return
        }
        let next: Int
        if s.localShuffle && queue.count > 1 {
            next = queue.indices.filter { $0 != s.localQueueIndex }.randomElement() ?? 0
        } else {
            next = s.localQueueIndex + 1
        }
        if queue.indices.contains(next) {
            playLocalQueue(queue, next, name: nil)
        } else if s.localRepeat == "all" {
            playLocalQueue(queue, 0, name: nil)
        } else if auto {
            state.localPlaying = false
        }
    }

    private func saveLocal(_ track: Track, _ videoId: String, announce: Bool) {
        Task {
            let ok = await saveLocalNow(track, videoId)
            if announce {
                showStatus(ok ? "Saved \(track.title) on this phone" : "Could not save \(track.title)", ok ? "ok" : "error")
            }
        }
    }

    /** Keep the droplet's copy of a played song in the caches folder. */
    private func keepNow(_ videoId: String) async {
        if videoId.isEmpty || keptFiles[videoId] != nil || localFiles[videoId] != nil || !serverCached.contains(videoId) { return }
        let dir = keptDirectory(), client = client
        guard let file = try? await Task.detached(operation: { try await AudioSaver.saveTo(videoId, dir: dir, client: client) }).value else { return }
        keptFiles[videoId] = file
        trimKeptSongs()
    }

    /** Copy the droplet's copy of [videoId] to the music folder. Returns once done. */
    private func saveLocalNow(_ track: Track, _ videoId: String) async -> Bool {
        if videoId.isEmpty { return false }
        if localFiles[videoId] != nil { return true }
        let dir = musicDirectory(), client = client
        guard let file = try? await Task.detached(operation: { try await AudioSaver.saveTo(videoId, dir: dir, client: client) }).value else {
            return false
        }
        localFiles[videoId] = file
        if let kept = keptFiles.removeValue(forKey: videoId) { try? FileManager.default.removeItem(at: kept) }
        let songs = state.songs.filter { videoIdOf($0) != videoId } + [track.with(videoId: videoId)]
        state.songs = songs
        let cache = deviceCache
        await Task.detached { cache.saveDownloadedSongs(songs) }.value
        publishLocalAvailable()
        return true
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        if state.playbackMode == mode { return }
        if mode == .remoteDesktop { phonePlayer?.pause() }
        if mode == .standalonePhone {
            _ = phone
            if state.localQueue.isEmpty {
                localDirty = true
                state.localQueue = state.queue
                state.localQueueName = "Phone queue"
            }
        }
        prefs.set(mode.rawValue, forKey: "playbackMode")
        state.playbackMode = mode
        progress = Progress()
    }

    // -- auth ---------------------------------------------------------------

    func login(_ user: String, _ pass: String) {
        authenticate(password: pass) { [client] in await client.login(user.trimmingCharacters(in: .whitespaces), pass) }
    }

    /**
     * The services' sessions from the account. They open with a key only the
     * Jukebox password gives, taken at sign-in. A phone without it (signed in
     * before this existed, or the password changed elsewhere) is signed out
     * of Jukebox: signing in again brings every service with it.
     */
    func refreshServices() async {
        let sessions = ServiceSessions.shared
        guard sessions.hasKey else {
            return signInAgain("Sign in once more to bring your music services to this phone.")
        }
        _ = await sessions.refresh(client)
        if !sessions.hasKey {
            // The account's sessions no longer open: the password changed.
            return signInAgain("Your Jukebox password changed. Sign in again.")
        }
        // This phone's own YouTube Music session read before the services are counted.
        await YtmDevice.shared.start()
        state.services = currentServices()
        Spotify.shared.start()
        syncSpotifyLists()
        await pullPrefs()
    }

    /**
     * The services this phone can use: the account's sealed sessions
     * (Spotify, SoundCloud), and YouTube Music when this phone is signed in
     * to it itself (YtmDevice; that session never leaves the phone).
     */
    private func currentServices() -> [String] {
        var out = ServiceSessions.shared.available
        // YouTube Music: held here, or borrowed from the device that holds it (round 2 I).
        if YtmDevice.shared.signedIn || !DeviceLink.shared.holder.isEmpty { out.append(ServiceSessions.ytm) }
        return out
    }

    /** Forgot password: nil when the link is on its way, else the reason. */
    func forgotPassword(_ user: String) async -> String? {
        await client.forgotPassword(user.trimmingCharacters(in: .whitespaces))
    }

    func register(_ user: String, _ pass: String) {
        authenticate(created: true, password: pass) { [client] in await client.register(user.trimmingCharacters(in: .whitespaces), pass) }
    }

    private func authenticate(created: Bool = false, password: String, _ call: @escaping () async -> Bool) {
        Task {
            state.busy = true
            state.error = nil
            if await call() {
                // The splash until the account's services are known (round 2 F).
                state.listenGate = "checking"
                state.signedIn = true
                state.email = client.email ?? ""
                state.busy = false
                _ = await ServiceSessions.shared.unlock(password: password, email: state.email)
                Task { await refreshServices(); await decideListenGate() }
                gateDeadline()
                ensurePhonePump()
                await pullAccount()
                await pullSync()
                await syncPlayer()
                await refreshTrackMap()
                showStatus(
                    created ? "Account created. Now pick how you want to listen." : "Signed in as \(client.email ?? "")",
                    created ? "info" : "ok"
                )
            } else {
                state.busy = false
                state.error = created ? "Could not create the account." : "Sign in failed. Check the email and password."
            }
        }
    }

    /** Signed out on this phone only, back at sign-in with the email filled in. */
    private func signInAgain(_ why: String) {
        let email = state.email
        Task {
            await client.logout()
            ServiceSessions.shared.forgetAll()
            Spotify.shared.start()
            resetToSignIn(email: email, error: why)
        }
    }

    func logout() {
        Task {
            await client.logout()
            ServiceSessions.shared.forgetAll()
            // Signed out of Jukebox here: the next account must not inherit this
            // phone's YouTube Music sign-in.
            await YtmDevice.shared.signOut()
            Spotify.shared.start()      // no login left: stops it
            resetToSignIn()
        }
    }

    /**
     * The droplet turned the saved session away (a password reset signs
     * every device out): back to the sign-in screen, the email filled in,
     * instead of carrying on alone with every request refused.
     */
    private func sessionRejected() {
        guard state.signedIn else { return }
        log.info("session rejected by the droplet; signing in again")
        resetToSignIn(email: state.email, error: "You were signed out of this account, maybe after a password change. Sign in again.")
    }

    private func resetToSignIn(email: String = "", error: String? = nil) {
        phonePlayer?.stop()
        pending.removeAll()
        pumpStop = true
        pump?.cancel()
        pump = nil
        likedSync?.cancel()
        likedSync = nil
        var fresh = UiState()
        fresh.myDeviceId = state.myDeviceId
        fresh.deviceName = state.deviceName
        fresh.email = email
        fresh.error = error
        state = fresh
        progress = Progress()
        // The next account decides afresh whether to ask how to listen.
        prefs.removeObject(forKey: "listenIn")
    }

    // -- first run (round 2 F) ------------------------------------------------
    //
    // Jukebox sign-in first; then straight into the app when the account has
    // any music service (a session on the account, or YouTube Music kept by
    // Jukebox online), or chose to listen as a guest; only with none at all
    // "How do you want to listen?". Decided once the account has been asked,
    // behind the splash, so the question never flashes up and away. Offline:
    // straight in.

    /** The account's preference key for "Continue as guest" (shared by every app). */
    static let listenChoiceKey = "listenChoice"

    private func setGate(_ gate: String) {
        if state.listenGate != gate { state.listenGate = gate }
        if gate == "in" { prefs.set(true, forKey: "listenIn") }
    }

    private func decideListenGate() async {
        guard state.signedIn else { return }
        // "Checking your accounts" (round 2 I): the other devices asked first -
        // behind that screen on a first run, quietly on every later start.
        await checkAccounts()
        guard state.listenGate == "checking" else { return }
        if !state.services.isEmpty { return setGate("in") }
        // A service only an unreachable device has: the screen stays, offering
        // "I can't reach my other devices".
        if !state.unreachableServices.isEmpty { return }
        guard let doc = await client.prefs() else { return setGate("in") }     // offline: straight in
        applyPrefs(doc)
        guard state.listenGate == "checking" else { return }
        let guest = doc.obj("prefs")?.str(Self.listenChoiceKey) == "guest"
        setGate(guest || !state.services.isEmpty ? "in" : "pick")
    }

    /** Never more than a few seconds of splash: whatever is known by then decides. */
    private func gateDeadline() {
        Task {
            await sleep(seconds: 12)
            // Not while "I can't reach my other devices" is offered: that waits for a tap.
            if state.signedIn && state.listenGate == "checking" && state.unreachableServices.isEmpty { setGate("in") }
        }
    }

    /** "Continue as guest": remembered on the account, so no window or device asks again. */
    func continueAsGuest() {
        setGate("in")
        let device = deviceId()
        Task { _ = await client.putPrefs([Self.listenChoiceKey: "guest"], device: device) }
    }

    /**
     * "I can't reach my other devices" (round 2 I): sign in to the missing
     * service here instead of getting it from the device that has it.
     */
    func cantReachDevices() {
        guard let first = state.unreachableServices.first else { return setGate(state.services.isEmpty ? "pick" : "in") }
        connectService(first)
    }

    /** Past "Checking your accounts" with what is there. */
    func skipAccountCheck() {
        setGate(state.services.isEmpty ? "pick" : "in")
    }

    /**
     * Sign this phone out of Jukebox. Only this phone: every other device
     * stays signed in, and the account keeps its music services for them.
     */
    func signOutMaro() {
        showStatus("Signed out of Jukebox on this phone.", "ok")
        logout()
    }

    // -- commands -----------------------------------------------------------

    func send(_ action: String, _ payload: JSON = [:]) {
        Task {
            if !(await client.postAction(action, payload)) { showStatus("Command not delivered to the desktop.", "error") }
        }
    }

    /** The sign-in page open on this phone, if any (shown as a sheet). */
    @Published var signIn: ServiceSignIn?

    /**
     * Connect: sign in on this phone, on the service's own page; the session
     * goes onto the account, where every client takes it. Sign out: off the
     * account, so every client is signed out of it. `key` is "spotify",
     * "ytm" or "sc".
     */
    func connectService(_ key: String) {
        let slot = key == "spotify" ? ServiceSessions.librespot : key == "ytm" ? ServiceSessions.ytm : ServiceSessions.soundcloud
        let label = key == "spotify" ? "Spotify" : key == "ytm" ? "YouTube Music" : "SoundCloud"
        if state.services.contains(slot) {
            if slot == ServiceSessions.ytm {
                // Borrowed from another device: signing in here makes this phone the holder.
                guard DeviceLink.shared.amHolder || YtmDevice.shared.signedIn else { return startSignIn(key) }
                // Held here: signed out here, and nobody holds it until someone signs in.
                Task {
                    await YtmDevice.shared.signOut()
                    await linkSetHolder(nil)
                    ConsoleLog.shared.log("ServiceSignIn", "YouTube Music signed out on this phone")
                    state.services = currentServices()
                    showStatus("Signed out of YouTube Music on this phone", "ok")
                }
                return
            }
            Task {
                await ServiceSessions.shared.signOut(slot, client: client)
                ConsoleLog.shared.log("ServiceSignIn", "\(label) signed out")
                if slot == ServiceSessions.librespot { Spotify.shared.start() }   // no login: stops it
                state.services = currentServices()
                showStatus("Signed out of \(label) on every device", "ok")
            }
            return
        }
        startSignIn(key)
    }

    /** Sign in to a service on its own page, on this phone; the new session replaces the account's. */
    private func startSignIn(_ key: String) {
        let slot = key == "spotify" ? ServiceSessions.librespot : key == "ytm" ? ServiceSessions.ytm : ServiceSessions.soundcloud
        let label = key == "spotify" ? "Spotify" : key == "ytm" ? "YouTube Music" : "SoundCloud"
        // YouTube Music's session stays on this phone, so it needs no account key.
        guard key == "ytm" || ServiceSessions.shared.hasKey else {
            ConsoleLog.shared.log("ServiceSignIn", "\(label) connect blocked: Jukebox sign-in required")
            showStatus("Sign in to Jukebox again to connect music services.", "info")
            return
        }
        signIn = ServiceSignIn(service: key) { [weak self] outcome in
            guard let self else { return }
            self.signIn = nil
            switch outcome {
            case .session(let payload):
                ConsoleLog.shared.log("ServiceSignIn", "\(label) sign-in completed; publishing session")
                Task { await self.saveSession(slot, payload, label: label) }
            case .device:
                ConsoleLog.shared.log("ServiceSignIn", "YouTube Music signed in on this phone")
                Task { await self.ytmSignedInHere() }
            case .spotifyToken(let token):
                ConsoleLog.shared.log("ServiceSignIn", "Spotify authorization received; starting player sign-in")
                showStatus("Signing in to Spotify…", "info")
                Spotify.shared.onLoggedIn = { [weak self] creds in
                    Task { await self?.saveSession(ServiceSessions.librespot, ["credentials": creds], label: "Spotify") }
                }
                Spotify.shared.signIn(token: token)
            case .failed(let why):
                ConsoleLog.shared.log("ServiceSignIn", "\(label) sign-in failed: \(why)")
                showStatus(why, "error")
            case .cancelled:
                ConsoleLog.shared.log("ServiceSignIn", "\(label) sign-in cancelled")
                break
            }
        }
    }

    private func saveSession(_ slot: String, _ payload: JSON, label: String) async {
        if let why = await ServiceSessions.shared.publish(slot, payload, client: client) {
            ConsoleLog.shared.log("ServiceSignIn", "\(label) session publish failed: \(why)")
            showStatus(why, "error")
            return
        }
        ConsoleLog.shared.log("ServiceSignIn", "\(label) signed in")
        state.services = currentServices()
        if slot == ServiceSessions.librespot { Spotify.shared.start() }
        showStatus("Signed in to \(label) - on your account, so every device has it", "ok")
    }

    /**
     * Signed in to YouTube Music on this phone (round 2 H): the session stays
     * in this phone's store. Any old copy on the account's /service/ytm slot
     * is deleted, so no stale session is ever picked up anywhere.
     */
    private func ytmSignedInHere() async {
        _ = await client.deleteServiceBlob(ServiceSessions.ytm)
        await YtmDevice.shared.signedInNow()
        // Signing in here makes this phone the holder; the old one lets go (round 2 I).
        if YtmDevice.shared.signedIn { await linkSetHolder(deviceId()) }
        state.services = currentServices()
        showStatus(YtmDevice.shared.signedIn ? "Signed in to YouTube Music on this phone" : "YouTube Music sign-in didn't stick - try again",
                   YtmDevice.shared.signedIn ? "ok" : "error")
        checkHealth(force: true)
    }


    func artFetch(_ artKey: String) {
        if artKey.isEmpty {
            showStatus("No artwork key is available for this song", "error")
            return
        }
        if state.artworkProgress[artKey] != nil { return }
        ArtLoader.shared.invalidate(artKey)
        state.artworkProgress[artKey] = 5
        showStatus("Downloading artwork…", "info")
        Task {
            let delivered = await client.postAction("art.fetch", ["ids": [artKey]])
            var found = false
            if delivered {
                for _ in 1...30 {
                    await sleep(seconds: 1)
                    if let data = await client.cover(artKey), !data.isEmpty {
                        found = true
                        break
                    }
                }
            }
            state.artworkProgress[artKey] = nil
            ArtLoader.shared.invalidate(artKey)
            showStatus(
                !delivered ? "Artwork request failed to reach the desktop" : found ? "Artwork downloaded" : "Artwork was not found",
                found ? "ok" : "error"
            )
        }
    }

    /**
     * The drop-in for rows that render before the engine resolved their art:
     * fetch and store it quietly, once per session, so playlist covers fill in
     * and stay on disk for good.
     */
    func prefetchArt(_ artKey: String) {
        if artKey.isEmpty || ArtLoader.shared.has(artKey) || !artFetched.insert(artKey).inserted { return }
        Task {
            if await client.postAction("art.fetch", ["ids": [artKey]]) {
                for _ in 1...15 {
                    await sleep(seconds: 1)
                    if let data = await client.cover(artKey), !data.isEmpty { break }
                }
            }
            ArtLoader.shared.invalidate(artKey)
        }
    }

    func openUrl(_ url: String) {
        guard !url.isEmpty, let u = URL(string: url) else { return }
        UIApplication.shared.open(u)
    }

    // -- player -------------------------------------------------------------

    func playPause() {
        let s = state
        if isPhone {
            if s.localTrack == nil && !s.localQueue.isEmpty {
                playLocalQueue(s.localQueue, 0, name: nil)
            } else if let track = s.localTrack {
                if !phone.hasMedia {
                    // After a restart the song is shown but not loaded yet:
                    // carry on from where the playhead was left.
                    pendingSeek = progress.position
                    startTrack(track)
                } else if phone.isPlaying {
                    phone.pause()
                } else {
                    phone.play()
                }
            }
            return
        }
        if !s.isCurrent { return }
        let now = uptime()
        state.playing = !s.playing
        progress = Progress(position: progress.at(now), duration: progress.duration, playing: !s.playing, anchor: now)
        remote("toggle")
    }

    func next() {
        if isPhone { advance(auto: false) } else { remoteJump(1, "next") }
    }

    /**
     * Controlling the desktop: show the next/previous song at once, as the
     * desktop will report it in a moment, instead of sitting on the old one.
     */
    private func remoteJump(_ delta: Int, _ action: String) {
        let target = state.queueIndex + delta
        if let t = state.queue[safe: target] { showRemote(t, target) }
        remote(action)
    }

    private func showRemote(_ track: Track, _ index: Int) {
        state.track = track
        state.queueIndex = index
        state.playing = true
        progress = Progress(position: 0, duration: track.duration, playing: true, anchor: uptime())
    }

    func previous() {
        if !isPhone { return remoteJump(-1, "previous") }
        if phone.currentPosition > 5 || state.localQueueIndex <= 0 {
            phone.seek(to: 0)
        } else {
            playLocalQueue(state.localQueue, state.localQueueIndex - 1, name: nil)
        }
    }

    func restart() {
        if !isPhone { return remote("restart") }
        phone.seek(to: 0)
        phone.play()
    }

    func seek(_ position: Double) {
        var p = progress
        p.position = position
        p.anchor = uptime()
        progress = p
        if isPhone { phone.seek(to: position) } else { remote("seek", ["position": position]) }
    }

    func setVolume(_ pct: Int) {
        let v = min(max(pct, 0), 100)
        state.volume = v
        if isPhone { phone.volume = Float(v) / 100 } else { remote("volume", ["value": v, "final": true]) }
    }

    func setRepeat(_ mode: String) {
        if isPhone {
            state.localRepeat = mode
        } else {
            state.repeat = mode
            remote("repeat", ["mode": mode])
        }
    }

    func toggleShuffle() {
        if isPhone {
            state.localShuffle.toggle()
        } else {
            state.shuffle.toggle()
            remote("queue.shuffle", ["enabled": state.shuffle])
        }
    }

    func playQueueIndex(_ i: Int) {
        if isPhone {
            playLocalQueue(state.localQueue, i, name: nil)
        } else {
            if let t = state.queue[safe: i] { showRemote(t, i) }
            remote("play.queue", ["index": i])
        }
    }

    /**
     * Play [t]. On the phone, the list it was tapped in becomes the queue, so
     * next/previous work and the following songs can be fetched ahead.
     */
    func playTrack(_ t: Track, context: [Track]? = nil, name: String? = nil, index: Int? = nil) {
        if t.id.isEmpty { return }
        // The list it was tapped in becomes the queue, wherever it plays.
        let list = context ?? [t]
        if let i = index ?? list.firstIndex(where: { $0.id == t.id }) {
            playList(list, i, name: name)
        } else {
            playList([t], 0, name: name)
        }
    }

    func playPlaylist(_ row: LibraryRow) {
        if row.id.isEmpty { return }
        if state.selectedPlaylist?.id == row.id && !state.playlistTracks.isEmpty {
            playList(state.playlistTracks, 0, name: row.name)
        } else {
            playWhenLoaded = row.id
            openPlaylist(row)
        }
    }

    func playOfflineAt(_ i: Int) {
        guard state.songs.indices.contains(i) else { return }
        playList(state.songs, i, name: "Saved songs")
    }

    /// The song rings as the alarm on every Hourglass device.
    func setAsAlarm(_ t: Track) {
        let id = videoIdOf(t).ifEmpty(t.videoId.ifEmpty(t.id))
        if id.isEmpty { return }
        showStatus("Making \(t.title) your alarm…", "info")
        let client = client
        Task {
            let err = await client.hourglassAlarm(songId: id, title: t.title, artist: t.artist)
            if let err { showStatus(err, "error") } else { showStatus("\(t.title) is now your alarm on every device", "ok") }
        }
    }

    /// Copies the Spotify link for this song: the exact track, or a search for it.
    func shareSpotifyLink(_ t: Track) {
        let id = t.source == "spotify" ? t.id.ifEmpty(t.sourceId) : ""
        copyLink(Omp.spotifyShareUrl(id: id, query: "\(t.title) \(t.artist)"), "Spotify")
    }

    /// Copies the YouTube Music link for this song, the same way.
    func shareYouTubeLink(_ t: Track) {
        let id = videoIdOf(t).ifEmpty(t.source == "ytm" ? t.id : "")
        copyLink(Omp.youtubeShareUrl(videoId: id, query: "\(t.title) \(t.artist)"), "YouTube Music")
    }

    private func copyLink(_ url: String, _ service: String) {
        guard !url.isEmpty else { return }
        UIPasteboard.general.string = url
        showStatus("\(service) link copied", "ok")
    }

    /** Whether this song is in the queue the user is looking at. */
    func isQueued(_ t: Track) -> Bool {
        let queue = isPhone ? state.localQueue : state.queue
        return !t.id.isEmpty && queue.contains { $0.id == t.id }
    }

    /**
     * One song, tapped outside a list - search, Recent. It plays now and joins
     * the queue right after the current song; the queue itself stays. A queue
     * is only replaced by playing another list, or emptied by Clear all.
     */
    func playSingle(_ t: Track) {
        if t.id.isEmpty { return }
        if !isPhone {
            remote("playtrack", ["track": t.toJSON()])
            return
        }
        var queue = state.localQueue
        let index: Int
        if queue.isEmpty {
            queue.append(giveVideoId(t))
            index = 0
        } else if let at = queue.firstIndex(where: { $0.id == t.id }) {
            index = at
        } else {
            index = min(max(state.localQueueIndex + 1, 0), queue.count)
            queue.insert(giveVideoId(t), at: index)
        }
        playLocalQueue(queue, index, name: state.localQueue.isEmpty ? t.title : state.localQueueName)
    }

    func queueNext(_ t: Track) {
        if t.id.isEmpty { return }
        if isPhone {
            let t2 = giveVideoId(t)
            var queue = state.localQueue
            var index = state.localQueueIndex
            // Already queued: move it to play next instead of adding a copy.
            if let at = queue.firstIndex(where: { $0.id == t2.id }) {
                if at == index { return }
                let item = queue.remove(at: at)
                if at < index { index -= 1 }
                queue.insert(item, at: min(max(index + 1, 0), queue.count))
            } else {
                queue.insert(t2, at: min(max(index + 1, 0), queue.count))
            }
            state.localQueue = queue
            state.localQueueIndex = index
            warm([t2])
            showStatus("Playing next: \(t.title)", "ok")
            return
        }
        remote("queue.addNext", ["track": t.toJSON()])
        showStatus("Playing next: \(t.title)", "ok")
    }

    func addToQueue(_ t: Track) {
        if t.id.isEmpty { return }
        if isPhone {
            // Already queued: nothing to add.
            if state.localQueue.contains(where: { $0.id == t.id }) { return }
            state.localQueue.append(giveVideoId(t))
        } else {
            remote("queue.add", ["track": t.toJSON()])
        }
        showStatus("Added to queue: \(t.title)", "ok")
    }

    /** A whole list after the queue (the desktop's "Add to queue" on a playlist): one command, not one per song. */
    func addAllToQueue(_ tracks: [Track]) {
        let list = tracks.filter { !$0.id.isEmpty }
        if list.isEmpty { return }
        if isPhone {
            var queue = state.localQueue
            for t in list where !queue.contains(where: { $0.id == t.id }) { queue.append(giveVideoId(t)) }
            state.localQueue = queue
        } else {
            remote("queue.add", ["tracks": list.map { $0.toJSON() }])
        }
        showStatus("Added \(list.count) \(list.count == 1 ? "track" : "tracks") to queue", "ok")
    }

    func removeQueueIndex(_ i: Int) {
        if !isPhone { return remote("queue.remove", ["index": i]) }
        guard state.localQueue.indices.contains(i) else { return }
        let wasCurrent = i == state.localQueueIndex
        if wasCurrent { phonePlayer?.stop() }
        var s = state
        s.localQueue.remove(at: i)
        if s.localQueue.isEmpty || wasCurrent {
            s.localQueueIndex = -1
        } else if i < s.localQueueIndex {
            s.localQueueIndex -= 1
        }
        if wasCurrent {
            s.localTrack = nil
            s.localPlaying = false
        }
        state = s
    }

    func moveQueue(_ from: Int, _ to: Int) {
        if from == to { return }
        if !isPhone { return remote("queue.move", ["from": from, "to": to]) }
        var queue = state.localQueue
        guard queue.indices.contains(from), queue.indices.contains(to) else { return }
        let current = state.localQueueIndex
        queue.insert(queue.remove(at: from), at: to)
        var index = current
        if current == from {
            index = to
        } else if from < current && to >= current {
            index -= 1
        } else if from > current && to <= current {
            index += 1
        }
        state.localQueue = queue
        state.localQueueIndex = index
    }

    func clearQueue() {
        // The account snapshot may still hold the old songs for a while: mark
        // the clear so the merge guard adopts the empty queue.
        queueClearedAt = uptime()
        if !isPhone { return remote("queue.clear") }
        localDirty = true
        phonePlayer?.stop()
        var s = state
        s.localQueue = []
        s.localQueueIndex = -1
        s.localTrack = nil
        s.localPlaying = false
        s.localPreparing = false
        state = s
        progress = Progress()
    }

    func clearHistory() { send("history.clear") }

    func saveOffline(_ t: Track) {
        if t.id.isEmpty { return }
        if !isPhone {
            send("offline.add", ["track": t.toJSON()])
            showStatus("Saving \(t.title)…", "info")
            return
        }
        let videoId = videoIdOf(t)
        if !videoId.isEmpty && localFiles[videoId] != nil {
            showStatus("\(t.title) is already on this phone", "ok")
        } else if !videoId.isEmpty && serverCached.contains(videoId) {
            showStatus("Saving \(t.title) on this phone…", "info")
            saveLocal(t, videoId, announce: true)
        } else {
            showStatus("Preparing \(t.title) for this phone…", "info")
            requestCloud(videoId.isEmpty ? t : t.with(videoId: videoId), .save)
        }
    }

    func likeTrack(_ t: Track) {
        if t.id.isEmpty { return }
        let liked = state.isLiked(t)
        var s = state
        if liked {
            s.likedKeys = s.likedKeys.filter { !$0.hasSuffix(":" + t.id) }
            s.likedIds.subtract(t.trackIds)
            likedTracks.removeAll { $0.sameAs(t) }
        } else {
            if !t.source.isEmpty { s.likedKeys.insert(t.source + ":" + t.id) }
            s.likedIds.formUnion(t.trackIds)
            likedTracks.insert(t, at: 0)       // newest on top
        }
        if s.selectedPlaylist?.source == "liked" {
            s.playlistTracks = likedTracks
            s.playlistTotal = likedTracks.count
        }
        likedKnown = true
        applyCounts(&s)
        state = s
        // Saved on the droplet (every other device has it at once); a few
        // tries if the connection drops.
        let json = t.toJSON(), client = client
        Task {
            for _ in 0..<5 {
                if await client.like(json, liked: !liked) { return }
                await sleep(seconds: 3)
            }
            log.warning("a like did not reach the account")
        }
        showStatus(liked ? "Unliked" : "Liked", "ok")
    }

    // -- playlists ----------------------------------------------------------

    private func playlistKey(_ row: LibraryRow) -> String { "v3:" + row.source + ":" + row.id }

    func openPlaylist(_ row: LibraryRow) {
        if row.id.isEmpty { return }
        var s = state
        s.selectedPlaylist = row
        s.playlistTracks = []
        s.playlistLoading = true
        s.playlistLoadingMore = false
        s.playlistHasMore = true
        s.playlistTotal = row.count
        s.playlistError = ""
        // Held already - Liked (the liked list, as the account has it) or a
        // list saved on the account or read here: every song shows at once,
        // whether or not a desktop is awake to fetch it from the service.
        // Liked always shows the liked list (empty until it arrives), never a
        // copy kept on the phone by an older build.
        if let tracks = heldTracks(row) ?? (row.source == "liked" ? likedTracks : nil) {
            s.playlistTracks = tracks
            s.playlistLoading = false
            s.playlistHasMore = false
            s.playlistTotal = tracks.count
            state = s
            if playWhenLoaded == row.id {
                playWhenLoaded = nil
                playList(tracks, 0, name: row.name)
            }
            // A newer copy on the account, or a Spotify list older than half
            // an hour, is read again behind it.
            if accountNewer(row) {
                Task { await fetchAccountList(row) }
            } else if listDue(row) {
                Task { await fetchSpotifyList(row) }
            }
            return
        }
        state = s
        Task {
            let key = playlistKey(row), cache = deviceCache
            let cached = await Task.detached { cache.playlist(key) }.value
            if state.selectedPlaylist?.id != row.id { return }
            if let cached, !cached.tracks.isEmpty {
                state.playlistTracks = cached.tracks
                state.playlistLoading = false
                state.playlistHasMore = cached.hasMore
                state.playlistTotal = cached.hasMore ? cached.total : cached.tracks.count
                if playWhenLoaded == row.id {
                    playWhenLoaded = nil
                    playList(cached.tracks, 0, name: row.name)
                }
                // The account's stored copy replaces it when there is one.
                if accountIndex["\(row.source):\(row.id)"] != nil, await fetchAccountList(row) != nil { return }
                if listDue(row) { await fetchSpotifyList(row) }
                return
            }
            // Nothing held: the account's stored copy, then Spotify read on
            // this phone, then the desktop page by page.
            if await fetchAccountList(row) != nil { return }
            if await fetchSpotifyList(row) != nil { return }
            if state.selectedPlaylist?.id == row.id { loadPlaylistPage(0) }
        }
    }

    // -- song lists held for every playlist (round 2 B) ----------------------

    /**
     * The account's stored lists without their songs ("source:id" -> count,
     * savedAt, snapshotId), from GET /cache/playlists: the rows' counts, and
     * whether a held copy is behind.
     */
    private var accountIndex: [String: (count: Int, savedAt: Double, snapshotId: String)] = [:]
    private var indexAt: Double = -.infinity

    /** The account's list index, at most once a minute unless forced. */
    private func refreshAccountIndex(force: Bool = false) async {
        if !force && uptime() - indexAt < 60 { return }
        indexAt = uptime()
        guard let rows = await client.savedPlaylistIndex() else { return }
        var index: [String: (count: Int, savedAt: Double, snapshotId: String)] = [:]
        for r in rows {
            let key = r.str("key").ifEmpty("\(r.str("source")):\(r.str("id"))")
            index[key] = (r.int("count"), Self.savedAt(r), r.str("snapshotId"))
        }
        accountIndex = index
        recount()
    }

    /** Whether the account holds a newer copy of a list than the one held here. */
    private func accountNewer(_ row: LibraryRow) -> Bool {
        let key = "\(row.source):\(row.id)"
        guard row.source != "liked", let stored = accountIndex[key] else { return false }
        guard let mine = savedPlaylists[key] else { return true }
        return stored.savedAt > Self.savedAt(mine) + 1
    }

    /** When each list was last read on this phone ("source:id" -> epoch seconds). */
    private var listFetchedAt: [String: Double] = [:]
    /** Lists being read right now, so one is never asked twice at once. */
    private var listFetching: Set<String> = []
    /** A list is read again at most this often (seconds), unless asked to. */
    private static let listRefresh: Double = 1800
    /** The background sweep over the whole library is gentler: a list held for six hours is left alone. */
    private static let sweepAge: Double = 6 * 3600

    /**
     * Whether a Spotify playlist's held list is old enough to read again:
     * neither the account's copy nor this phone's is newer than `maxAge`
     * (half an hour for an opened list).
     */
    private func listDue(_ row: LibraryRow, maxAge: Double? = nil) -> Bool {
        guard row.source == "spotify", Spotify.shared.hasLogin else { return false }
        let key = "spotify:\(row.id)"
        let last = max(listFetchedAt[key] ?? 0, savedPlaylists[key].map(Self.savedAt) ?? 0, accountIndex[key]?.savedAt ?? 0)
        return Date().timeIntervalSince1970 - last > (maxAge ?? Self.listRefresh)
    }

    /**
     * A Spotify playlist's whole song list (every song, not a first page),
     * read with this phone's own Spotify session, then held like a saved
     * one. nil when this phone has no Spotify or Spotify did not answer.
     */
    @discardableResult
    private func fetchSpotifyList(_ row: LibraryRow) async -> [Track]? {
        guard row.source == "spotify", !row.id.isEmpty, Spotify.shared.hasLogin else { return nil }
        let key = "spotify:\(row.id)"
        guard listFetching.insert(key).inserted else { return nil }
        defer { listFetching.remove(key) }
        Spotify.shared.start()
        // Spotify Liked Songs is a row like the others ("__liked__"), read from the collection.
        let read: [Track]?
        if row.id == "__liked__" {
            read = await Spotify.shared.liked()
        } else {
            read = await Spotify.shared.playlist(row.id)
        }
        guard let got = read, !got.isEmpty else {
            log.info("spotify list \(row.id, privacy: .public) did not load on this phone")
            return nil
        }
        let tracks = got.map(giveVideoId)
        holdList(row, tracks, savedAt: Date().timeIntervalSince1970, offer: true)
        return tracks
    }

    /** The account's stored copy of one list, when the snapshot did not carry it. */
    @discardableResult
    private func fetchAccountList(_ row: LibraryRow) async -> [Track]? {
        guard row.source != "liked", row.source != "local", !row.id.isEmpty else { return nil }
        guard let entry = await client.savedPlaylist("\(row.source):\(row.id)") else { return nil }
        let tracks = Sync.tracks(entry.arr("tracks")).map(giveVideoId)
        guard !tracks.isEmpty else { return nil }
        holdList(row, tracks, savedAt: Self.savedAt(entry), offer: false)
        return tracks
    }

    /**
     * A list now held: kept on the phone, counted on its row, shown if it is
     * the open one, and (when read here) stored on the account so every
     * device has it without the desktop.
     */
    private func holdList(_ row: LibraryRow, _ tracks: [Track], savedAt: Double, offer: Bool) {
        let key = "\(row.source):\(row.id)"
        let entry: JSON = ["tracks": tracks.map { $0.toJSON() }, "savedAt": savedAt, "snapshotId": "", "name": row.name]
        if offer { listFetchedAt[key] = savedAt }
        savedPlaylists[key] = entry
        savedCounts[key] = tracks.count
        keptCounts[key] = tracks.count
        let file = playlistKey(row), cache = deviceCache
        Task.detached(priority: .utility) { cache.savePlaylist(file, tracks, total: tracks.count, hasMore: false) }
        var s = state
        if let open = s.selectedPlaylist, open.source == row.source, open.id == row.id, !s.playlistLoadingMore {
            s.playlistTracks = tracks
            s.playlistLoading = false
            s.playlistHasMore = false
            s.playlistTotal = tracks.count
            s.playlistError = ""
        }
        applyCounts(&s)
        state = s
        if playWhenLoaded == row.id {
            playWhenLoaded = nil
            playList(tracks, 0, name: row.name)
        }
        if offer {
            let client = client
            Task {
                let answer = await client.putSavedPlaylist(key, entry)
                if answer == "ok" {
                    accountIndex[key] = (tracks.count, savedAt, "")
                } else if answer == "newer" {
                    // The account had a newer copy than this read: that one wins.
                    await fetchAccountList(row)
                }
            }
        }
    }

    /** Pull to refresh on an open playlist: its songs read again now. */
    func refreshOpenPlaylist() async {
        guard let row = state.selectedPlaylist, row.source != "liked" else { return }
        if await fetchSpotifyList(row) != nil { return }
        if await fetchAccountList(row) != nil { return }
        if row.source != "local" {
            state.playlistLoadingMore = false
            state.playlistHasMore = true
            loadPlaylistPage(0)
        }
    }

    private var listSyncRunning = false

    /**
     * Every Spotify playlist in the library read in full on this phone when
     * its held list is older than half an hour (all of them on a pull to
     * refresh), one at a time, so no row sits at a first page or at 0.
     * Off on a metered connection unless asked.
     */
    func syncSpotifyLists(force: Bool = false) {
        guard state.signedIn, !listSyncRunning, Spotify.shared.hasLogin, force || !NetworkWatch.expensive else { return }
        let now = Date().timeIntervalSince1970
        let due = state.playlists.filter { row in
            guard row.source == "spotify", !row.id.isEmpty else { return false }
            return force ? now - (listFetchedAt["spotify:\(row.id)"] ?? 0) > 60 : listDue(row, maxAge: Self.sweepAge)
        }
        guard !due.isEmpty else { return }
        listSyncRunning = true
        log.info("reading \(due.count) spotify lists on this phone")
        Task {
            for row in due {
                guard state.signedIn else { break }
                await fetchSpotifyList(row)
            }
            listSyncRunning = false
        }
    }

    /** Pull to refresh on the library: the account's snapshot and every Spotify list, now. */
    func refreshLibrary() async {
        await pullSync(force: true)
        syncSpotifyLists(force: true)
    }

    private func loadPlaylistPage(_ offset: Int) {
        guard let row = state.selectedPlaylist, offset >= 0, !state.playlistLoadingMore else { return }
        state.playlistLoading = offset == 0 && state.playlistTracks.isEmpty
        state.playlistLoadingMore = offset > 0
        send("playlist.tracks", [
            "requestId": UUID().uuidString.lowercased(),
            "source": row.source,
            "id": row.id,
            "name": row.name,
            "offset": offset,
            // Spotify's page maximum: fewer round trips through the desktop.
            "limit": 50,
        ])
    }

    func loadMorePlaylist() {
        let s = state
        if !s.playlistHasMore || s.playlistLoading || s.playlistLoadingMore { return }
        loadPlaylistPage(s.playlistTracks.count)
    }

    func closePlaylist() {
        playWhenLoaded = nil
        var s = state
        s.selectedPlaylist = nil
        s.playlistTracks = []
        s.playlistLoading = false
        s.playlistLoadingMore = false
        s.playlistHasMore = false
        s.playlistTotal = 0
        s.playlistError = ""
        state = s
    }

    func playOpenPlaylist() {
        guard let row = state.selectedPlaylist, !state.playlistTracks.isEmpty else { return }
        playList(state.playlistTracks, 0, name: row.name)
    }

    func createPlaylist(_ name: String, from: Track?) {
        var payload: JSON = ["name": name]
        if let from { payload["track"] = from.toJSON() }
        send("playlist.create", payload)
    }

    func renamePlaylist(_ id: String, _ name: String) { send("playlist.rename", ["id": id, "name": name]) }

    func deletePlaylist(_ id: String) { send("playlist.delete", ["id": id]) }

    /** Save offline on the desktop; the count said is the songs we hold for it. */
    func savePlaylistOffline(_ row: LibraryRow) {
        var payload: JSON = ["source": row.source, "id": row.id, "name": row.name]
        if let n = heldTracks(row)?.count {
            payload["count"] = n
            showStatus("Saving \(n) \(n == 1 ? "song" : "songs") offline", "info")
        }
        send("playlist.download", payload)
    }

    // -- Discover -----------------------------------------------------------

    /** What the home pages offered (Discover.swift); "at" is when they were read. */
    private var discoverRaw: JSON = [:]
    private var discoverYtm = false

    private func drawDiscover() {
        state.discover = DiscoverPage.build(discoverRaw, recent: state.recent, spotify: Spotify.shared.hasLogin, ytm: discoverYtm)
    }

    /** The tab: what is kept, at once; the home pages read again when older than an hour (or `force`). */
    func loadDiscover(force: Bool = false) {
        if discoverRaw.isEmpty, let kept = DiscoverStore.shared.page() { discoverRaw = kept }
        Task {
            discoverYtm = await YouTubeMusic.shared.signedIn
            drawDiscover()
            let spotify = Spotify.shared.hasLogin, ytm = discoverYtm
            let age = Date().timeIntervalSince1970 - discoverRaw.double("at")
            let wantsGuest = !spotify && !ytm
            let needsGuest = wantsGuest && discoverRaw.obj("ytmGuest") == nil
            guard !state.discoverBusy, force || age > 3600 || needsGuest else { return }
            state.discoverBusy = true
            if spotify { Spotify.shared.start() }
            let fromSpotify = spotify ? await SpotifyHome.sections() : nil
            let yt = (ytm || wantsGuest) ? (try? await YouTubeMusic.shared.home(signed: ytm)) : nil
            var raw = discoverRaw
            if let fromSpotify { raw["spotify"] = ["sections": fromSpotify] as JSON }
            if let yt {
                raw["ytm"] = ["mixes": yt.mixes, "radios": yt.radios] as JSON
                if wantsGuest { raw["ytmGuest"] = ["sections": yt.guestSections] as JSON }
            }
            if fromSpotify != nil || yt != nil {
                raw["at"] = Date().timeIntervalSince1970
                discoverRaw = raw
                let page = raw
                Task.detached { DiscoverStore.shared.savePage(page) }
            } else {
                showStatus("Couldn't read Discover - check the connection", "error")
            }
            state.discoverBusy = false
            drawDiscover()
        }
    }

    /** A mix or radio: its kept songs at once, read again behind them when old (six hours; a radio, a day). */
    func openDiscover(_ item: DiscoverItem) {
        var s = state
        s.discoverOpen = item
        s.discoverTracks = []
        s.discoverAt = 0
        s.discoverLoading = true
        if let kept = DiscoverStore.shared.list(item.id), !kept.tracks.isEmpty {
            s.discoverTracks = kept.tracks
            s.discoverAt = kept.at
            s.discoverLoading = false
        }
        state = s
        let age = Date().timeIntervalSince1970 - state.discoverAt
        if state.discoverTracks.isEmpty || age > (item.id.contains(":radio:") ? 86400 : 21600) { refreshDiscoverList() }
    }

    /** The open mix or radio, read from its service again. */
    func refreshDiscoverList() {
        guard let item = state.discoverOpen else { return }
        if state.discoverTracks.isEmpty { state.discoverLoading = true }
        Task {
            let got = await DiscoverPage.fetch(item.id)
            guard state.discoverOpen?.id == item.id else { return }
            state.discoverLoading = false
            if let got, !got.isEmpty {
                state.discoverTracks = got
                state.discoverAt = Date().timeIntervalSince1970
                Task.detached { DiscoverStore.shared.saveList(item.id, got) }
            } else if state.discoverTracks.isEmpty {
                showStatus("Couldn't open \(item.name)", "error")
            }
        }
    }

    func closeDiscover() {
        var s = state
        s.discoverOpen = nil
        s.discoverTracks = []
        s.discoverLoading = false
        state = s
    }

    /** Play a mix or radio from the start, opened or not. */
    func playDiscover(_ item: DiscoverItem) {
        if state.discoverOpen?.id == item.id && !state.discoverTracks.isEmpty {
            return playList(state.discoverTracks, 0, name: item.name)
        }
        Task {
            var tracks = DiscoverStore.shared.list(item.id)?.tracks ?? []
            if tracks.isEmpty { tracks = await DiscoverPage.fetch(item.id) ?? [] }
            if tracks.isEmpty { return showStatus("Couldn't open \(item.name)", "error") }
            let list = tracks
            Task.detached { DiscoverStore.shared.saveList(item.id, list) }
            playList(tracks, 0, name: item.name)
        }
    }

    /**
     * Radio from a song: Spotify's when it is a Spotify song (and Spotify is
     * signed in here), YouTube Music's otherwise. From the song playing on
     * this phone it keeps playing and the radio becomes the queue after it;
     * any other song plays first.
     */
    func startRadio(_ t: Track) {
        showStatus("Starting radio from \(t.title)…", "info")
        Task {
            var id = "", tracks: [Track] = []
            if t.source == "spotify" && Spotify.shared.hasLogin {
                Spotify.shared.start()
                if let r = await Spotify.shared.radio(t.id) {
                    id = "sp:radio:" + t.id
                    tracks = r.tracks
                }
            }
            if tracks.isEmpty {
                var vid = videoIdOf(t).ifEmpty(t.videoId)
                if vid.isEmpty && t.source == "ytm" { vid = t.id }
                if vid.isEmpty {
                    let found = await YouTubeDirect.shared.search("\(t.title) \(t.artist)")
                    vid = (found.first(where: { Match.sameSong($0, t) }) ?? found.first)?.id ?? ""
                }
                if !vid.isEmpty, let r = try? await YouTubeMusic.shared.radio(vid) {
                    id = "yt:radio:" + vid
                    tracks = r
                }
            }
            guard !tracks.isEmpty else { return showStatus("No radio for \(t.title)", "error") }
            let name = t.title + " Radio", list = tracks, key = id
            Task.detached { DiscoverStore.shared.saveList(key, list) }
            if isPhone, state.localPlaying, let cur = state.localTrack, cur.sameAs(t) {
                let q = [cur] + tracks.filter { !$0.sameAs(cur) }
                var s = state
                s.localQueue = q
                s.localQueueIndex = 0
                s.localQueueName = name
                state = s
                localDirty = true
                warm(Array(q.dropFirst().prefix(3)))
                showStatus("\(name) is up next", "ok")
                return
            }
            playList([t] + tracks.filter { !$0.sameAs(t) }, 0, name: name)
            showStatus("Playing \(name)", "ok")
        }
    }

    // -- downloading a playlist to this phone -----------------------------

    private func setDownload(_ key: String, _ job: DownloadJob) { state.downloads[key] = job }

    /**
     * Queue and copy every song of this playlist onto the phone, with progress
     * on the playlist row. Songs the droplet already has stream straight to
     * the music folder; the rest ride {cloud.prepare}, which puts them there
     * first, and are copied as each finishes.
     */
    func downloadPlaylist(_ row: LibraryRow) {
        if row.id.isEmpty { return }
        let key = playlistKey(row)
        if state.downloads[key]?.running == true { return }
        setDownload(key, DownloadJob(running: true))
        Task {
            // The songs we hold for it (Liked: the liked list itself, never a
            // copy kept from an older build's first pages), else read in full.
            var tracks = heldTracks(row) ?? []
            if tracks.isEmpty { tracks = await fetchAccountList(row) ?? [] }
            if tracks.isEmpty { tracks = await fetchSpotifyList(row) ?? [] }
            if tracks.isEmpty && row.source != "liked" {
                await ensurePlaylistFull(row)
                if state.selectedPlaylist?.id == row.id { tracks = state.playlistTracks }
            }
            if tracks.isEmpty {
                setDownload(key, DownloadJob(failed: 1))
                showStatus("Could not load \(row.name) - is this phone online?", "error")
                return
            }
            // The count is the list's real songs, never a stored number.
            let total = tracks.count
            setDownload(key, DownloadJob(total: total, running: true))
            await downloadTracks(key, total: total, tracks)
        }
    }

    /** Make sure every page of [row] is in [UiState.playlistTracks]. */
    private func ensurePlaylistFull(_ row: LibraryRow) async {
        let key = playlistKey(row), cache = deviceCache
        let cached = await Task.detached { cache.playlist(key) }.value
        if let cached, !cached.tracks.isEmpty {
            var s = state
            s.selectedPlaylist = row
            s.playlistTracks = cached.tracks
            s.playlistLoading = false
            s.playlistLoadingMore = false
            s.playlistHasMore = cached.hasMore
            s.playlistTotal = cached.total
            s.playlistError = ""
            state = s
        } else {
            openPlaylist(row)
        }
        // Then page through, one page as it lands, like the detail view does.
        var guardCount = 0
        while guardCount < 150 {
            let s = state
            if s.selectedPlaylist?.id != row.id || !s.playlistHasMore { return }
            if s.playlistLoading || s.playlistLoadingMore || s.playlistTracks.isEmpty {
                await sleep(seconds: 0.5)
                guardCount += 1
                continue
            }
            let known = s.playlistTotal > 0 ? s.playlistTotal : s.playlistTracks.count
            if s.playlistTracks.count >= known { return }
            loadMorePlaylist()
            var waited = 0
            while waited < 32 && state.playlistLoadingMore {
                await sleep(seconds: 0.5)
                waited += 1
            }
            guardCount += 1
        }
    }

    /**
     * Whether a song is saved on this phone already: its file under its
     * video id, or any of its ids (source id, matched copy) mapping to a
     * saved file.
     */
    private func savedOnPhone(_ t: Track) -> Bool {
        let v = videoIdOf(t)
        if !v.isEmpty && localFiles[v] != nil { return true }
        return t.trackIds.contains { state.localAvailable.contains($0) }
    }

    /** Why a song can't be saved any more (marked by an earlier download or play), or nil. */
    private func unavailableReason(_ t: Track) -> String? {
        let why = state.goneReason(t)
        if !why.isEmpty { return why }
        let v = videoIdOf(t)
        return v.isEmpty ? nil : state.gone[v]
    }

    /**
     * The service's answer when it removed a song for good (YouTube "video
     * unavailable", private, taken down; not playable; 404), or nil for a
     * failure worth trying again (no connection, a timeout, no match yet).
     */
    private static func removedReason(_ error: String) -> String? {
        let e = error.lowercased()
        let signs = ["video unavailable", "unavailable", "removed", "private", "not available", "terminated",
                     "copyright", "deleted", "404", "no longer", "not playable", "taken down"]
        return signs.contains { e.contains($0) } ? error : nil
    }

    /** A song the service removed: marked in every list with the reason, and never asked for again. */
    private func markUnavailable(_ t: Track, _ reason: String) {
        let v = videoIdOf(t).ifEmpty(t.videoId)
        if !v.isEmpty { markGone(v, reason) }
        if !t.id.isEmpty && t.source != "ytm" {
            state.gone["\(t.source):\(t.id)"] = reason
            UserDefaults.standard.set(state.gone, forKey: "goneSongs")
        }
    }

    /**
     * Save a playlist's songs on this phone (round 2 D.4): the list's real
     * songs, every one already saved here skipped, a removed one marked
     * unavailable instead of failing again; only the missing ones are fetched.
     * With nothing missing it is done at once.
     */
    private func downloadTracks(_ key: String, total: Int, _ tracks: [Track]) async {
        let already = tracks.filter(savedOnPhone)
        var unavailable = 0
        var missing: [Track] = []
        for t in tracks where !savedOnPhone(t) {
            if unavailableReason(t) != nil { unavailable += 1 } else { missing.append(t) }
        }
        let wanted = missing.count
        var done = 0, failed = 0
        func job(_ running: Bool) -> DownloadJob {
            DownloadJob(total: total, done: done, failed: failed, running: running,
                        already: already.count, unavailable: unavailable, wanted: wanted)
        }
        func bump() { setDownload(key, job(true)) }
        func notAvailable(_ n: Int) -> String { n == 1 ? "1 isn't available any more" : "\(n) aren't available any more" }
        if missing.isEmpty {
            setDownload(key, job(false))
            showStatus("All \(already.count) \(already.count == 1 ? "song is" : "songs are") saved on this phone"
                       + (unavailable > 0 ? ", \(notAvailable(unavailable))" : ""), "ok")
            return
        }
        showStatus("\(wanted) of \(total) to download" + (already.isEmpty ? "" : ", \(already.count) already saved"), "info")
        // A previous job that timed out may have left results behind.
        downloadInbox.removeAll()
        bump()
        var todo = missing[...]
        while !todo.isEmpty {
            var asks: [JSON] = []
            var asked = 0
            while let t = todo.first, asks.count < downloadBatch {
                todo = todo.dropFirst()
                let videoId = videoIdOf(t)
                if !videoId.isEmpty && serverCached.contains(videoId) {
                    if await saveLocalNow(t.with(videoId: videoId), videoId) { done += 1 } else { failed += 1 }
                } else {
                    let requestId = UUID().uuidString.lowercased()
                    let track = videoId.isEmpty ? t : t.with(videoId: videoId)
                    pending[requestId] = Pending(track: track, purpose: .download(key: key))
                    asks.append(["requestId": requestId, "track": track.toJSON()])
                    asked += 1
                }
                bump()
            }
            guard !asks.isEmpty else { continue }
            if await client.postAction("cloud.prepare", ["tracks": asks]) {
                var got = 0
                let deadline = uptime() + 600
                var lastResult = uptime()
                while got < asked && uptime() < deadline && uptime() - lastResult < 30 {
                    if downloadInbox.isEmpty {
                        await sleep(seconds: 0.25)
                        continue
                    }
                    let r = downloadInbox.removeFirst()
                    lastResult = uptime()
                    got += 1
                    if r.ready, await saveLocalNow(r.track, r.track.videoId) {
                        done += 1
                    } else if !r.ready, let why = Self.removedReason(r.error) {
                        markUnavailable(r.track, why)
                        unavailable += 1
                    } else {
                        failed += 1
                    }
                    bump()
                }
                failed += asked - got
            } else {
                // The relay is down (probably offline): the rest of this chunk
                // cannot be prepared either.
                markOnline(false)
                failed += asked
            }
            bump()
        }
        setDownload(key, job(false))
        var parts = ["\(already.count + done) saved"]
        if unavailable > 0 { parts.append(notAvailable(unavailable)) }
        if failed > 0 { parts.append("\(failed) couldn't be saved - try again") }
        showStatus(parts.joined(separator: ", "), failed == 0 ? "ok" : "info")
    }

    // -- settings -----------------------------------------------------------

    // -- health -------------------------------------------------------------

    private var healthAt: Double = -.infinity

    /**
     * Settings > Health: whether each account answers right now - the
     * Jukebox account, then Spotify, YouTube Music and SoundCloud with the
     * sessions this phone holds. At most once a minute unless forced.
     */
    func checkHealth(force: Bool = false, only: String? = nil) {
        if only == nil {
            if !force && uptime() - healthAt < 60 { return }
            healthAt = uptime()
        }
        let scToken = ServiceSessions.shared.session(ServiceSessions.soundcloud)?.str("token") ?? ""
        let ytmOn = YtmDevice.shared.signedIn || !DeviceLink.shared.holder.isEmpty
        var signed: [String: Bool] = ["maro": state.signedIn, "spotify": Spotify.shared.hasLogin, "ytm": ytmOn, "sc": !scToken.isEmpty]
        // One row's Check now: only that service.
        if let only { signed = signed.filter { $0.key == only } }
        let online = state.online
        var health = state.health
        for (key, on) in signed {
            if !on {
                health[key] = HealthState(state: "off")
            } else if !online {
                health[key] = HealthState(state: "offline", why: "No internet connection")
            } else {
                health[key] = HealthState(state: "checking")
            }
        }
        state.health = health
        guard online else { return }
        let client = client
        if signed["maro"] == true {
            Task {
                let ok = await client.account() != nil
                state.health["maro"] = ok ? HealthState(state: "yes") : HealthState(state: "no", why: "The account did not answer")
            }
        }
        if signed["spotify"] == true {
            Task {
                Spotify.shared.start()
                let found = await Spotify.shared.search("music")
                let why = Spotify.shared.ready ? "Search did not answer" : "The player did not connect"
                state.health["spotify"] = !found.isEmpty ? HealthState(state: "yes") : HealthState(state: "no", why: why)
            }
        }
        if signed["ytm"] == true {
            Task {
                state.health["ytm"] = await ytmHealth()
                state.services = currentServices()
            }
        }
        if signed["sc"] == true {
            Task {
                let me = await SoundCloud.shared.me(token: scToken)
                state.health["sc"] = me != nil ? HealthState(state: "yes") : HealthState(state: "no", why: "SoundCloud refused the sign-in")
            }
        }
    }

    /**
     * YouTube Music's health is this phone's own session (round 2 H), asked
     * of YouTube Music itself: "Signed in on this device as <account>", or
     * "Google signed this device out" with a one-tap sign-in (the web view
     * remembers the account, so usually no password).
     */
    private func ytmHealth() async -> HealthState {
        // Borrowed: the holder's state (round 2 I).
        let link = DeviceLink.shared
        if !link.amHolder, let peer = link.holderPeer {
            return peer.online
                ? HealthState(state: "yes", why: "Through \(peer.name) - online")
                : HealthState(state: "offline", why: "Through \(peer.name) - offline, changes will sync")
        }
        let name = await YouTubeMusic.shared.accountName()
        YtmDevice.shared.setAccount(name)
        return !name.isEmpty
            ? HealthState(state: "yes", why: "Signed in on this device as \(name)")
            : HealthState(state: "no", why: "Google signed this device out - Sign in")
    }

    /** "Purge and sign in": a new sign-in, whose session replaces the one that stopped working. */
    func purgeAndSignIn(_ key: String) {
        if key == "maro" { return signOutMaro() }
        startSignIn(key)
    }

    func purge(_ scope: String) {
        // Songs on disk are this phone's own; the rest is cleared on the desktop too.
        if scope != "songs" { send("purge", ["scope": scope]) }
        // The phone's own copies of the same things.
        if scope == "artwork" || scope == "all" { ArtLoader.shared.clear() }
        if scope == "playlists" || scope == "all" { deviceCache.clearPlaylists() }
        if scope == "all" || scope == "songs" {
            AudioCache.clear()
            try? FileManager.default.removeItem(at: keptDirectory())
            keptFiles = [:]
        }
        refreshPhoneStorage()
    }

    func setQuality(_ kind: String, _ tier: String) {
        if kind == "stream" { state.quality = tier }
        if kind == "download" { state.downloadQuality = tier }
        send("quality.set", ["kind": kind, "tier": tier])
    }

    func setSavingOffline(_ enabled: Bool) {
        state.savingOffline = enabled
        prefs.set(enabled, forKey: "savingOffline")
    }

    // -- account preferences (round 2 D.3) ---------------------------------
    //
    // The preferred source is the account's, the same on every device
    // (GET/PUT /cache/prefs). It is written only when the user picks one and
    // never changed on its own: a phone that can't follow it (Spotify not
    // signed in here) plays what it can and says so, leaving the choice.

    private var prefsRev = -1
    private var prefsAt: Double = -.infinity
    private var preferNoteShown = false

    /** The account's preferences, at start and every few minutes (the relay tells of changes at once). */
    private func pullPrefs(force: Bool = false) async {
        if !force && uptime() - prefsAt < 240 { return }
        prefsAt = uptime()
        guard let doc = await client.prefs() else { return }
        applyPrefs(doc)
    }

    private func applyPrefs(_ doc: JSON) {
        guard let p = doc.obj("prefs") else { return }
        applyHolder(doc)
        let rev = doc.int("rev", -1)
        if rev >= 0 && rev < prefsRev { return }
        prefsRev = max(prefsRev, rev)
        let source = p.str("preferredSource")
        guard Omp.sourceOptions.contains(where: { $0.0 == source }) else { return }
        prefs.set(source, forKey: "preferredSource")
        if source != state.playbackSource { state.playbackSource = source }
    }

    /** prefs.ytmHolder from the account doc: the one device holding YouTube Music (round 2 I). */
    private func applyHolder(_ doc: JSON) {
        guard let p = doc.obj("prefs") else { return }
        let holder = p.str("ytmHolder")
        Task { await DeviceLink.shared.holderIs(holder) }
    }

    /** The user picked a preferred source: onto the account, for every device. */
    func setPlaybackSource(_ value: String) {
        state.playbackSource = value
        prefs.set(value, forKey: "preferredSource")
        preferNoteShown = false
        // Older desktops still listen for this.
        send("playback.source", ["value": value])
        let device = deviceId(), label = Omp.sourceOptions.first { $0.0 == value }?.1 ?? value
        Task {
            if let doc = await client.putPrefs(["preferredSource": value], device: device) {
                applyPrefs(doc)
                showStatus("Preferred source: \(label), on every device", "ok")
            } else {
                showStatus("Couldn't save the preferred source to your account - try again", "error")
            }
        }
    }

    /** Rename this phone everywhere: the picker here, the account, the desktop panel. */
    func setDeviceName(_ name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespaces).prefix(80))
        let custom = clean == Omp.defaultPhoneName ? "" : clean
        Omp.customPhoneName = custom
        prefs.set(custom, forKey: "deviceName")
        state.deviceName = Omp.phoneName
        let body: JSON = ["device": deviceId(), "name": Omp.phoneName]
        Task { _ = await client.postAction("phone.state", body) }
        showStatus("This phone is now called \(Omp.phoneName)", "ok")
    }

    func selectAccount(_ account: String) {
        state.selectedAccount = account
        prefs.set(account, forKey: "selectedAccount")
    }

    /**
     * Make `device` the one that plays. Like Spotify Connect, only the sound
     * moves: the same queue and song carry on there from the same second.
     */
    func selectDevice(_ device: Device) {
        if !device.connected && !device.id.isEmpty { return }
        if solo { return showStatus("This phone plays on its own. Turn off \u{201C}Play music on this device only\u{201D} first.", "error") }
        let target = device.id.ifEmpty(deviceId())
        Task {
            // The latest word from this phone before the sound leaves it.
            if isPhone { await publishPlayer(force: true) }
            guard let doc = await client.playerDevice(target) else {
                showStatus("Could not switch devices", "error")
                return
            }
            await applyPlayer(doc)
        }
    }

    /** What the desktop needs to go on from here, or nil when nothing plays. */
    private func transferOut() -> JSON? {
        let s = state
        guard isPhone, s.localPlaying, !s.localQueue.isEmpty, s.localQueueIndex >= 0 else { return nil }
        let start = max(s.localQueueIndex - 50, 0)
        let window = s.localQueue[start..<min(start + 300, s.localQueue.count)]
        return [
            "tracks": window.map { $0.toJSON() },
            "index": s.localQueueIndex - start,
            "name": s.localQueueName,
            "position": phone.currentPosition,
            "playing": true,
        ]
    }

    // -- lyrics ---------------------------------------------------------------

    private func remember(_ found: SongLyrics, _ id: String) {
        if lyricsMem.updateValue(found, forKey: id) == nil { lyricsOrder.append(id) }
        if lyricsOrder.count > 200 { lyricsMem.removeValue(forKey: lyricsOrder.removeFirst()) }
    }

    /**
     * Find the song's lyrics: memory, then the droplet (the desktop looks up
     * everything it plays, and the next song too), then the desktop engine
     * with all its sources, then LRCLib directly if the desktop is away.
     */
    private func loadLyrics(_ track: Track?) {
        lyricsTask?.cancel()
        guard let track, !track.title.isEmpty else {
            lyrics = SongLyrics()
            return
        }
        let id = track.id
        if let hit = lyricsMem[id] {
            lyrics = hit
            return
        }
        lyrics = SongLyrics(trackId: id, loading: true)
        lyricsTask = Task {
            if id.range(of: "^[A-Za-z0-9_-]{6,64}$", options: .regularExpression) != nil,
               let found = SongLyrics.from(id, await client.lyrics(id)) {
                return lyricsFound(found, id)
            }
            if Task.isCancelled { return }
            if state.signedIn {
                send("lyrics.get", ["track": track.toJSON()])
                await sleep(seconds: 6)
                if Task.isCancelled || lyrics.trackId != id || !lyrics.loading { return }
            }
            lyricsFound(SongLyrics.from(id, await client.lrclib(track)) ?? SongLyrics(trackId: id), id)
        }
    }

    private func lyricsFound(_ found: SongLyrics, _ id: String) {
        remember(found, id)
        if lyrics.trackId == id { lyrics = found }
    }

    // -- remote control from the desktop -----------------------------------

    /** A command from the desktop panel, for this phone. */
    private func onControl(_ p: JSON) {
        let command = p.str("command")
        log.info("control '\(command, privacy: .public)' for \(p.str("device"), privacy: .public)")
        if p.str("device") != deviceId() { return }
        if command == "handoff" {
            let transfer = transferOut()
            phonePlayer?.pause()
            setPlaybackMode(.remoteDesktop)
            var body: JSON = ["device": p.str("to")]
            if let transfer { body["transfer"] = transfer }
            send("device.select", body)
            return
        }
        // Anything else means this phone is the one playing now.
        if !isPhone { setPlaybackMode(.standalonePhone) }
        let offset = reportedOffset
        switch command {
        case "transfer", "playtracks":
            let tracks = Sync.tracks(p.arr("tracks"))
            if tracks.isEmpty { return }
            if command == "transfer" && !p.bool("playing", true) { return }
            pendingSeek = p.double("position")
            playLocalQueue(tracks, min(max(p.int("index"), 0), tracks.count - 1), name: p.str("name").isEmpty ? nil : p.str("name"))
        case "toggle": playPause()
        case "next": next()
        case "previous": previous()
        case "restart": restart()
        case "seek": seek(p.double("position"))
        case "volume": setVolume(p.int("value", state.volume))
        case "play.queue": playQueueIndex(p.int("index") + offset)
        case "queue.add": addToQueue(Track.from(p.obj("track")))
        case "queue.addNext": queueNext(Track.from(p.obj("track")))
        case "playtrack": playSingle(Track.from(p.obj("track")))
        case "queue.remove": removeQueueIndex(p.int("index") + offset)
        case "queue.move": moveQueue(p.int("from") + offset, p.int("to") + offset)
        case "queue.clear": clearQueue()
        case "repeat": setRepeat(p.str("mode", "off"))
        case "queue.shuffle": state.localShuffle = p.bool("enabled")
        default: break
        }
    }

    /**
     * Tell the desktop what this phone is playing, so its panel can show it
     * and drive it. Sent when something changes (checked four times a second,
     * which costs nothing when nothing did) and every 15 s while playing. The
     * queue goes along only when it changed, as a window of 300 around the song.
     */
    private func startStateReports() {
        Task { [weak self] in
            var lastKey: [AnyHashable] = []
            var lastQueue: [Track]?
            var lastOffset = -1
            var lastSaved: Set<String>?
            var sentAt: Double = 0
            var sentPos: Double = 0
            while true {
                await sleep(seconds: 0.25)
                guard let self else { return }
                if self.pump == nil { return }
                let s = self.state
                guard s.signedIn, self.isPhone else {
                    lastKey = []
                    continue
                }
                // The shared player first: it decides what every device shows.
                await self.publishPlayer()
                let key: [AnyHashable] = [s.localTrack?.id, s.localPlaying, s.localQueueIndex, s.volume, s.localRepeat,
                                          s.localShuffle, s.localPreparing, s.localQueueName, s.localQueue.count, s.localAvailable]
                let now = uptime()
                let pos = self.progress.at(now)
                let expected = sentPos + (s.localPlaying ? now - sentAt : 0)
                // The whole queue goes to the shared player now; the desktop's
                // indices are the same as this phone's.
                let offset = 0
                let queueChanged = s.localQueue != lastQueue || offset != lastOffset
                let jumped = abs(pos - expected) > 2
                let due = s.localPlaying && now - sentAt > 15
                if key == lastKey && !queueChanged && !jumped && !due { continue }
                lastKey = key
                sentAt = now
                sentPos = pos
                var body: JSON = [
                    "device": self.deviceId(),
                    "name": Omp.phoneName,
                    "track": s.localTrack.map { $0.toJSON() as Any } ?? NSNull(),
                    "playing": s.localPlaying,
                    "position": pos,
                    "duration": self.progress.duration,
                    "queueName": s.localQueueName,
                    "queueIndex": s.localQueueIndex - offset,
                    "volume": s.volume,
                    "repeat": s.localRepeat,
                    "shuffle": s.localShuffle,
                    "preparing": s.localPreparing,
                ]
                if queueChanged {
                    lastQueue = s.localQueue
                    lastOffset = offset
                    self.reportedOffset = offset
                }
                // The whole offline set, but only when it moves.
                if s.localAvailable != lastSaved {
                    lastSaved = s.localAvailable
                    body["saved"] = s.localAvailable.sorted()
                }
                let client = self.client, payload = body
                Task { _ = await client.postAction("phone.state", payload) }
            }
        }
    }

    // -- search -------------------------------------------------------------

    private var searchDebounce: Task<Void, Never>?

    /**
     * Search as you type: 200 ms after the last keystroke, from two
     * characters. A query kept in the search cache draws at once; a longer
     * one whose start is kept shows that start's songs, narrowed to the
     * typed words, until its own answer lands.
     */
    func setSearchText(_ text: String) {
        state.searchText = text
        searchDebounce?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchToken += 1
            state.searching = false
            state.searchResults = []
            state.searchLink = ""
            return
        }
        if q.count < 2 { return }
        if !Self.isLink(q) { showKept(q) }
        searchDebounce = Task { [weak self] in
            await sleep(seconds: 0.2)
            guard let self, !Task.isCancelled else { return }
            self.runSearch(announce: false)
        }
    }

    func pickSearchSource(_ key: String) {
        state.searchSource = key
        doSearch()
    }

    private static func isLink(_ q: String) -> Bool {
        q.hasPrefix("http") || q.contains("spotify.com/") || q.contains("soundcloud.com/") || q.contains("snd.sc/") || q.contains("youtu")
    }

    /** What the cache already knows for this query: its own answer, or a kept start of it narrowed down. */
    private func showKept(_ q: String) {
        let cache = SearchCache.shared, source = state.searchSource
        if let hit = cache.get(SearchCache.key(q, source: source)) {
            state.searchResults = hit.tracks
            state.searchLink = ""
            state.searching = false
            return
        }
        let lower = q.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        var n = lower.count - 1
        while n >= 2 {
            let prefix = String(lower.prefix(n)).trimmingCharacters(in: .whitespaces)
            let key = SearchCache.key(prefix, source: source)
            if prefix.count >= 2, cache.has(key), let hit = cache.get(key) {
                state.searchResults = hit.tracks.filter { t in
                    let hay = (t.title + " " + t.artist).lowercased()
                    return words.allSatisfy { hay.contains($0) }
                }
                state.searchLink = ""
                state.searching = true
                return
            }
            n -= 1
        }
        state.searching = true
    }

    /**
     * Search every service from this phone itself - Spotify through its own
     * player, YouTube Music and SoundCloud through their sites - and merge
     * them into one row per song. Nothing goes through another device.
     */
    private var searchToken = 0

    /** Enter, the Search button or a source: at once, saying so when nothing is found. */
    func doSearch() {
        searchDebounce?.cancel()
        runSearch(announce: true)
    }

    private func runSearch(announce: Bool) {
        let q = state.searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return }
        searchToken += 1
        let token = searchToken
        state.searchLink = ""
        let link = Self.isLink(q)
        let cacheKey = SearchCache.key(q, source: state.searchSource)
        if !link, let hit = SearchCache.shared.get(cacheKey) {
            // Kept: drawn now, with no spinner; asked again quietly when older than ten minutes.
            state.searchResults = hit.tracks
            state.searching = false
            if Date().timeIntervalSince1970 - hit.at < 600 { return }
        } else {
            // A narrowed kept start stays on screen until the answer lands.
            if link { state.searchResults = [] }
            state.searching = true
        }
        // `list`: a pasted playlist, album or Mix - its songs play as one list, under this name.
        func done(_ found: [Track], _ empty: String, list: String = "") {
            guard token == searchToken else { return }
            state.searching = false
            state.searchResults = found
            state.searchLink = found.count > 1 ? list : ""
            if found.isEmpty && announce { showStatus(empty, "error") }
        }
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: q) else { return nil }
            return String(q[r])
        }
        // A pasted link opens the song (or set, playlist, album, Mix, profile) itself.
        if q.contains("soundcloud.com/") || q.contains("snd.sc/") {
            Task { @MainActor in
                let found = (try? await SoundCloud.shared.open(link: q)) ?? []
                done(found, "SoundCloud didn't recognise that link", list: q.contains("/sets/") ? "SoundCloud playlist" : "SoundCloud")
            }
            return
        }
        if q.contains("spotify.com/"), let kind = first(#"open\.spotify\.com/(?:intl-[a-z]+/)?(track|playlist|album)/"#),
           let id = first(#"open\.spotify\.com/(?:intl-[a-z]+/)?(?:track|playlist|album)/([A-Za-z0-9]+)"#) {
            Spotify.shared.start()
            let empty = Spotify.shared.hasLogin ? "Spotify didn't open that link" : "Sign in to Spotify in Settings to open Spotify links"
            Task { @MainActor in
                if kind == "track" {
                    let found = ((await Spotify.shared.ask("tracks", ["uris": ["spotify:track:" + id]])) as? [JSON] ?? []).map(Spotify.track)
                    return done(found, empty)
                }
                var got = await SpotifyLinks.open(kind: kind, id: id, share: first(#"[?&]pt=([A-Za-z0-9]+)"#) ?? "")
                if got == nil, kind == "playlist", let own = await Spotify.shared.playlist(id) { got = ("", own) }
                let name = (got?.name ?? "").ifEmpty(kind == "album" ? "Spotify album" : "Spotify playlist")
                done(got?.tracks ?? [], empty, list: name)
            }
            return
        }
        if q.contains("youtu"), let list = first(#"[?&]list=([A-Za-z0-9_-]{10,})"#) {
            Task { @MainActor in
                if list.hasPrefix("RD") {
                    let got = try? await YouTubeMusic.shared.mix(list, videoId: first(#"[?&]v=([A-Za-z0-9_-]{11})"#) ?? "")
                    return done(got?.tracks ?? [], "YouTube didn't open that Mix", list: (got?.title ?? "").ifEmpty("YouTube Mix"))
                }
                let found = (try? await YouTubeMusic.shared.playlist(list)) ?? []
                done(found, "YouTube didn't open that playlist", list: "YouTube Music playlist")
            }
            return
        }
        if q.contains("youtu"), let video = first(#"(?:youtu\.be/|[?&]v=|/shorts/)([A-Za-z0-9_-]{11})"#) {
            Task { @MainActor in
                // The song itself is the first of its radio, with its title and artist.
                let found = ((try? await YouTubeMusic.shared.radio(video)) ?? []).prefix(1)
                done(Array(found), "YouTube didn't open that link")
            }
            return
        }
        let source = state.searchSource
        let wantSpotify = (source.isEmpty || source == "spotify") && Spotify.shared.hasLogin
        let wantYouTube = source.isEmpty || source == "ytm"
        let wantSoundCloud = source.isEmpty || source == "sc"
        if wantSpotify { Spotify.shared.start() }
        Task { @MainActor in
            async let sp: [Track] = wantSpotify ? Spotify.shared.search(q) : []
            async let yt: [Track] = wantYouTube ? YouTubeDirect.shared.search(q) : []
            async let sc: [Track] = wantSoundCloud ? ((try? await SoundCloud.shared.search(q)) ?? []) : []
            let (a, b, c) = await (sp, yt, sc)
            // The preferred service's copy first, then Spotify, YouTube, SoundCloud.
            var lists = ["spotify": a, "ytm": b, "sc": c]
            let order = [state.playbackSource] + ["spotify", "ytm", "sc"]
            var merged: [Track] = []
            for key in order where lists[key] != nil {
                merged = Self.merge(merged, lists[key] ?? [])
                lists[key] = nil
            }
            if !merged.isEmpty { SearchCache.shared.put(cacheKey, merged) }
            // Only the newest query's answer draws; a late one is dropped.
            guard token == searchToken else { return }
            state.searching = false
            state.searchResults = merged
            if merged.isEmpty && announce { showStatus("Nothing found for \(q)", "info") }
        }
    }

    /**
     * One row per song: a SoundCloud result the list already has from another
     * service is left out, as the desktop's own merge does.
     */
    static func merge(_ rows: [Track], _ extra: [Track]) -> [Track] {
        var out = rows
        for t in extra where !out.contains(where: { $0.id == t.id || Match.sameSong($0, t) }) {
            out.append(t)
        }
        return out
    }

    // -- view ---------------------------------------------------------------

    func selectTab(_ key: String) {
        var s = state
        s.view = key
        s.pages = []
        state = s
        if key == Sync.viewDiscover { loadDiscover() }
    }

    // -- artist and album pages ---------------------------------------------

    func openArtist(_ name: String, id: String = "", art: String = "") {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty && id.isEmpty { return }
        // Already on it (a song on this artist's own page).
        if case .artist(let n, let i, _)? = state.pages.last,
           (!id.isEmpty && i == id) || (!name.isEmpty && YTMParse.fold(n) == YTMParse.fold(name)) { return }
        push(.artist(name: name, id: id, art: art))
    }

    func openAlbum(_ name: String, id: String = "", art: String = "", artist: String = "") {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty && id.isEmpty { return }
        if case .album(let n, let i, _, _)? = state.pages.last, (!id.isEmpty && i == id) || (id.isEmpty && n == name) { return }
        push(.album(name: name, id: id, art: art, artist: artist))
    }

    func openAlbum(of t: Track) {
        openAlbum(t.album, id: t.albumId, art: t.artUrl, artist: t.artistNames.first ?? "")
    }

    func openReleases(_ title: String, artist: String, ref: BrowseRef) {
        push(.releases(title: title, artist: artist, ref: ref))
    }

    func pageBack() {
        if !state.pages.isEmpty { state.pages.removeLast() }
    }

    private func push(_ page: DetailPage) {
        if state.pages.last == page { return }
        PageStore.shared.load(page)
        var s = state
        s.pages.append(page)
        if s.pages.count > 40 { s.pages.removeFirst() }
        s.settingsOpen = false
        state = s
    }

    /** What this phone already holds of an artist or an album: the page when YouTube Music cannot be reached. */
    func knownTracks(artist: String = "", album: String = "") -> [Track] {
        let s = state
        let pool = likedTracks + s.recent + s.songs + s.localQueue + s.queue + s.playlistTracks + s.searchResults + s.discoverTracks
        let a = YTMParse.fold(artist), b = YTMParse.fold(album)
        var seen = Set<String>(), out: [Track] = []
        for t in pool where !t.id.isEmpty && !seen.contains(t.id) {
            let match = !a.isEmpty ? t.artistNames.contains { YTMParse.fold($0) == a } : (!b.isEmpty && YTMParse.fold(t.album) == b)
            if match {
                seen.insert(t.id)
                out.append(t)
            }
        }
        return out
    }

    // -- launch route (testing) ---------------------------------------------

    /**
     * `-jbRoute <route>` at launch opens a screen: artist:<name>,
     * album:<name>[|<artist>], search:<query>, settings, library,
     * playlist:liked, tab:<key>, jam (full screen). Only for looking at screens on a device.
     */
    private func applyLaunchRoute() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-jbRoute"), i + 1 < args.count else { return }
        let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? "", value = parts.count > 1 ? parts[1] : ""
        Task {
            await sleep(seconds: 2)
            switch kind {
            case "artist": openArtist(value)
            case "album":
                let bits = value.components(separatedBy: "|")
                openAlbum(bits[0], artist: bits.count > 1 ? bits[1] : "")
            case "search":
                selectTab(Sync.viewSearch)
                setSearchText(value)
            case "settings":
                if !value.isEmpty { SettingsPage.scrollTo = value }
                if !state.settingsOpen { toggleSettings() }
            case "library": selectTab(Sync.viewPlaylists)
            case "jam": jamRequest += 1
            case "tab": selectTab(value)
            case "playlist":
                selectTab(Sync.viewPlaylists)
                for _ in 0..<30 {
                    if let row = state.library.first(where: { !$0.isHeader && ($0.source == value || $0.name == value) }) {
                        openPlaylist(row)
                        break
                    }
                    await sleep(seconds: 0.5)
                }
            default: break
            }
        }
    }

    func toggleStats() {
        state.statsOpen.toggle()
        if state.statsOpen { measureSounding() }
    }

    func toggleSettings() {
        state.settingsOpen.toggle()
        if state.settingsOpen {
            refreshPhoneStorage()
            checkHealth()
        }
    }

    func showStatus(_ msg: String, _ kind: String) {
        state.statusMsg = msg
        state.statusKind = kind
    }

    func clearStatus() { state.statusMsg = "" }

    func dismissLogin() { state.loginPrompt = nil }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension ISO8601DateFormatter {
    /** The droplet writes sentAt with milliseconds; tolerate either form. */
    static func flexible(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// -- sign in once, every device works (round 2 I and I.5) ----------------------

extension MaroViewModel: DeviceLinkHost {
    func linkChanged() {
        state.services = currentServices()
        if ServiceSessions.shared.session(ServiceSessions.librespot) != nil { Spotify.shared.start() }
        state.accountSources = accountSources()
        Task { await DeviceLink.shared.register() }
    }

    func linkStatus(_ message: String, _ kind: String) { showStatus(message, kind) }

    var linkPlayingDevice: String { playerDoc?.str("device") ?? "" }

    var linkPlayingHere: Bool { isPhone && state.localPlaying }

    func linkSetHolder(_ id: String?) async {
        let value: Any = id ?? NSNull()
        if let doc = await client.putPrefs(["ytmHolder": value], device: deviceId()) { applyPrefs(doc) }
    }

    /**
     * Each service's source line, as onboarding ("Checking your accounts")
     * and Settings > Accounts show it.
     */
    func accountSources() -> [String: String] {
        let link = DeviceLink.shared
        link.updateSources()
        var out: [String: String] = [:]
        for service in ["spotify", "soundcloud"] {
            let s = link.sources[service] ?? ""
            if s == "here" {
                out[service] = "This device"
            } else if s.hasPrefix("peer:") {
                out[service] = "From " + String(s.dropFirst("peer:".count))
            } else if s == "account" {
                out[service] = "On your account"
            } else {
                out[service] = "Not connected"
            }
        }
        if link.amHolder {
            out["ytm"] = "Signed in here (moves to the device you're using)"
        } else if let peer = link.holderPeer {
            out["ytm"] = peer.online ? "Through \(peer.name) - online" : "Through \(peer.name) - offline, changes will sync"
        } else {
            out["ytm"] = "Not connected"
        }
        return out
    }

    /**
     * Who has which service, checked with the other devices: this device on
     * the account, the account's copies, a session from a device that holds
     * one, and who holds YouTube Music. Quiet on every start; behind
     * "Checking your accounts" on the first.
     */
    func checkAccounts() async {
        let link = DeviceLink.shared
        link.startLan()
        await link.register()
        await link.refreshPeers()
        await link.askForSessions()
        state.services = currentServices()
        state.accountSources = accountSources()
        // A service only an unreachable device has, with no copy on the account.
        var unreachable: [String] = []
        if ServiceSessions.shared.session(ServiceSessions.librespot) == nil, link.peers.contains(where: { $0.spotify && !$0.online }) { unreachable.append("spotify") }
        if ServiceSessions.shared.session(ServiceSessions.soundcloud) == nil, link.peers.contains(where: { $0.soundcloud && !$0.online }) { unreachable.append("sc") }
        state.unreachableServices = unreachable
        if link.amHolder { await link.applyPending() }
    }

    /** The app came to the front or went away (scene phase). */
    func appActive(_ active: Bool) {
        let link = DeviceLink.shared
        link.active = active
        if active {
            backgroundedAt = nil
            if state.signedIn { link.startLan() }
            return
        }
        link.stopLan()
        backgroundedAt = Date()
        // I.5: after more than 10 minutes away and not playing, the YouTube
        // Music role goes to the device in use. iOS suspends an app that isn't
        // playing, so this happens if the app is still running by then (or at
        // termination, below).
        let mark = backgroundedAt
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard backgroundedAt == mark, backgroundedAt != nil, !linkPlayingHere else { return }
            await link.handOver(reason: "phone away for 10 minutes")
        }
    }

}
