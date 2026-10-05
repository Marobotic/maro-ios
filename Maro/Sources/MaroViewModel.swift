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
    @Published private(set) var lyrics = SongLyrics()

    /** The playhead, apart from [state]: only the seek row and lyrics read it. */
    @Published private(set) var progress = Progress()

    private var lyricsMem: [String: SongLyrics] = [:]
    private var lyricsOrder: [String] = []
    private var lyricsTask: Task<Void, Never>?

    private var phoneId = ""
    private var pump: Task<Void, Never>?
    private var pumpStop = false
    private var syncTask: Task<Void, Never>?
    private var lastSyncAt = ""

    // Which YouTube video plays each track, and what the droplet and phone hold.
    private var trackMap: [String: String] = [:]
    private var serverCached: Set<String> = []
    private var serverMapLoaded = false
    private var localFiles: [String: URL] = [:]
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
        AudioCache.session = { [client] in client.session }
        AudioCache.client = client
        AudioCache.tier = { [weak self] in self?.state.quality ?? "max" }
        ArtLoader.shared.client = client
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
        state = s
        Task {
            await loadDeviceState()
            await restoreSnapshot()
            publishLocalAvailable()
            if state.signedIn {
                ensurePhonePump()
                await pullAccount()
                await pullSync()
                await syncPlayer()
                await refreshTrackMap()
                await sleep(seconds: 1.5)
                await pullAccount()
            }
        }
        startConnectivityWatch()
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
        pump = client.phonePump(
            deviceId: deviceId(),
            deviceName: { await MainActor.run { Omp.phoneName } },
            solo: { [weak self] in await self?.solo ?? false },
            stop: { [weak self] in await self?.pumpShouldStop() ?? true },
            onEvent: { [weak self] msg in await self?.onRelayMessage(msg) }
        )
    }

    private func pumpShouldStop() -> Bool { pumpStop || !state.signedIn }

    private func musicDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Maro", isDirectory: true)
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
                            inTier: a["inTier"] as? Bool)
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
            publishedOnce = false               // try again next pass
            return
        }
        if !out.bool("ok"), let moved = out.obj("player") {
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

    private func pullSync() async {
        guard let data = await client.sync() else { return }
        markOnline(true)
        let at = data.str("at")
        if !at.isEmpty && at == lastSyncAt { return }
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
        s.likedIds = Set(Sync.tracks(likedArr).flatMap(\.trackIds))
        s.library = Sync.library(snap.obj("playlists"))
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
        case "playlist.tracks":
            onPlaylistPage(p)
        case "search":
            let q = p.str("q")
            if !q.isEmpty && q == state.searchText.trimmingCharacters(in: .whitespaces) {
                state.searching = false
                state.searchResults = Sync.tracks(p.arr("results"))
            }
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
            if tag != playTag { return }
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
            downloadInbox.append(Downloaded(ready: ready, track: job.track.with(videoId: videoId.ifEmpty(job.track.videoId))))
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
        saveTask?.cancel()
        progress = Progress(position: 0, duration: track.duration, playing: false, anchor: tapAt)
        let videoId = videoIdOf(track)
        if let file = localFiles[videoId], FileManager.default.fileExists(atPath: file.path) {
            playRoute = "file"
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
        } else if !videoId.isEmpty && (serverCached.contains(videoId) || !serverMapLoaded) {
            playRoute = AudioCache.isWarm(videoId) ? "warm asset" : "stream"
            playStreamAtTier(videoId, tag: tag, duration: track.duration)
        } else {
            playRoute = "engine"
            phone.stop()
            requestCloud(videoId.isEmpty ? track : track.with(videoId: videoId), .play(tag: tag))
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
    private func setSounding(_ videoId: String, copy: String, kbps: Int, inTier: Bool?) {
        let key = videoId + "/" + copy
        let known = timelines[key] ?? []
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
    private func warm(_ tracks: [Track]) {
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
        if !onDroplet.isEmpty { warmAtTier(onDroplet) }
    }

    /**
     * Songs the droplet already holds: find which copy each plays as at the
     * chosen tier, have the droplet fetch the tier for any below it, and warm
     * whichever copy plays now. Seen songs only - the rows on screen and the
     * next few in the queue.
     */
    private func warmAtTier(_ tracks: [Track]) {
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
            for t in tracks { AudioCache.precache(t.videoId) }
        }
    }

    /** The rows on screen settled: get them ready to play at a tap. */
    func prefetchVisible(_ tracks: [Track]) {
        // Whatever is on screen gets ready on the droplet, whichever device
        // plays: a tap from here, or on the one playing, should start at once.
        guard state.signedIn else { return }
        warm(Array(tracks.prefix(40)))
    }

    func onStarted(tag: Int) {
        if tag != playTag { return }
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
        if state.savingOffline && !videoId.isEmpty && localFiles[videoId] == nil {
            // Keep a copy once it has played a while.
            saveTask = Task {
                await sleep(seconds: 10)
                if !Task.isCancelled && tag == playTag { saveLocal(track, videoId, announce: false) }
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
        if let track, retriedTag != tag {
            retriedTag = tag
            let videoId = videoIdOf(track)
            if !notOnServer && !videoId.isEmpty && localFiles[videoId] == nil {
                // The droplet has it but streaming it failed: fetch the whole
                // file once and play that, before bothering the engine.
                playRoute = "download"
                log.info("stream failed (\(message, privacy: .public)), downloading instead")
                Task {
                    let saved = await saveLocalNow(track, videoId)
                    guard tag == playTag else { return }
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

    /** Copy the droplet's copy of [videoId] to the music folder. Returns once done. */
    private func saveLocalNow(_ track: Track, _ videoId: String) async -> Bool {
        if videoId.isEmpty { return false }
        if localFiles[videoId] != nil { return true }
        let dir = musicDirectory(), client = client
        guard let file = try? await Task.detached(operation: { try await AudioSaver.saveTo(videoId, dir: dir, client: client) }).value else {
            return false
        }
        localFiles[videoId] = file
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
        authenticate { [client] in await client.login(user.trimmingCharacters(in: .whitespaces), pass) }
    }

    func register(_ user: String, _ pass: String) {
        authenticate(created: true) { [client] in await client.register(user.trimmingCharacters(in: .whitespaces), pass) }
    }

    private func authenticate(created: Bool = false, _ call: @escaping () async -> Bool) {
        Task {
            state.busy = true
            state.error = nil
            if await call() {
                state.signedIn = true
                state.email = client.email ?? ""
                state.busy = false
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

    func logout() {
        Task {
            phonePlayer?.stop()
            pending.removeAll()
            pumpStop = true
            pump?.cancel()
            pump = nil
            await client.logout()
            var fresh = UiState()
            fresh.myDeviceId = state.myDeviceId
            fresh.deviceName = state.deviceName
            state = fresh
            progress = Progress()
        }
    }

    /** The account's own sign-out, through the engine (saves the queue). */
    func signOutMaro() {
        send("logout", ["target": "maro"])
        showStatus("Signed out. Your queue is saved to your account.", "ok")
        Task {
            await sleep(seconds: 1.2)
            logout()
        }
    }

    // -- commands -----------------------------------------------------------

    func send(_ action: String, _ payload: JSON = [:]) {
        Task {
            if !(await client.postAction(action, payload)) { showStatus("Command not delivered to the desktop.", "error") }
        }
    }

    func connectService(_ key: String) {
        let connected = key == "spotify" ? state.spotifyConnected : state.ytmConnected
        let label = key == "spotify" ? "Spotify" : "YouTube Music"
        if connected {
            send("logout", ["target": key])
            showStatus("Disconnecting \(label) on the desktop.", "info")
        } else {
            send(key == "spotify" ? "login.spotifyd" : "login.ytm")
            // A desktop engine opens it there; the cloud engine sends the
            // link back here ("login"), which shows it on this phone.
            showStatus("Starting the \(label) sign-in…", "info")
        }
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
        } else {
            if !t.source.isEmpty { s.likedKeys.insert(t.source + ":" + t.id) }
            s.likedIds.formUnion(t.trackIds)
        }
        state = s
        send("song.like", ["track": t.toJSON()])
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
        state = s
        Task {
            let key = playlistKey(row), cache = deviceCache
            let cached = await Task.detached { cache.playlist(key) }.value
            if state.selectedPlaylist?.id != row.id { return }
            if let cached, !cached.tracks.isEmpty {
                state.playlistTracks = cached.tracks
                state.playlistLoading = false
                state.playlistHasMore = cached.hasMore
                state.playlistTotal = cached.total
                if playWhenLoaded == row.id {
                    playWhenLoaded = nil
                    playList(cached.tracks, 0, name: row.name)
                }
            } else {
                loadPlaylistPage(0)
            }
        }
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

    func savePlaylistOffline(_ row: LibraryRow) {
        send("playlist.download", ["source": row.source, "id": row.id, "name": row.name])
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
            await ensurePlaylistFull(row)
            if state.selectedPlaylist?.id != row.id {
                setDownload(key, DownloadJob(failed: 1))
                return
            }
            let tracks = state.playlistTracks
            if tracks.isEmpty {
                setDownload(key, DownloadJob(failed: 1))
                showStatus("Could not load \(row.name) - is this phone online?", "error")
                return
            }
            let total = state.playlistTotal > 0 ? state.playlistTotal : tracks.count
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

    private func downloadTracks(_ key: String, total: Int, _ tracks: [Track]) async {
        var done = 0, failed = 0
        func bump() { setDownload(key, DownloadJob(total: total, done: done, failed: failed, running: true)) }
        // A previous job that timed out may have left results behind.
        downloadInbox.removeAll()
        bump()
        var todo = tracks[...]
        while !todo.isEmpty {
            var asks: [JSON] = []
            var wanted = 0
            while let t = todo.first, asks.count < downloadBatch {
                todo = todo.dropFirst()
                let videoId = videoIdOf(t)
                if !videoId.isEmpty && localFiles[videoId] != nil {
                    done += 1
                } else if !videoId.isEmpty && serverCached.contains(videoId) {
                    if await saveLocalNow(t.with(videoId: videoId), videoId) { done += 1 } else { failed += 1 }
                } else {
                    let requestId = UUID().uuidString.lowercased()
                    let track = videoId.isEmpty ? t : t.with(videoId: videoId)
                    pending[requestId] = Pending(track: track, purpose: .download(key: key))
                    asks.append(["requestId": requestId, "track": track.toJSON()])
                    wanted += 1
                }
                bump()
            }
            guard !asks.isEmpty else { continue }
            if await client.postAction("cloud.prepare", ["tracks": asks]) {
                var got = 0
                let deadline = uptime() + 600
                var lastResult = uptime()
                while got < wanted && uptime() < deadline && uptime() - lastResult < 30 {
                    if downloadInbox.isEmpty {
                        await sleep(seconds: 0.25)
                        continue
                    }
                    let r = downloadInbox.removeFirst()
                    lastResult = uptime()
                    got += 1
                    if r.ready, await saveLocalNow(r.track, r.track.videoId) { done += 1 } else { failed += 1 }
                    bump()
                }
                failed += wanted - got
            } else {
                // The relay is down (probably offline): the rest of this chunk
                // cannot be prepared either.
                markOnline(false)
                failed += wanted
            }
            bump()
        }
        setDownload(key, DownloadJob(total: total, done: done, failed: failed, running: false))
        showStatus(
            failed == 0 ? "Saved \(done) songs on this phone" : "Saved \(done) of \(total), \(failed) could not be saved",
            failed == 0 ? "ok" : "info"
        )
    }

    // -- settings -----------------------------------------------------------

    func purge(_ scope: String) {
        send("purge", ["scope": scope])
        // The phone's own copies of the same things.
        if scope == "artwork" || scope == "all" { ArtLoader.shared.clear() }
        if scope == "playlists" || scope == "all" { deviceCache.clearPlaylists() }
        if scope == "all" { AudioCache.clear() }
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

    func setPlaybackSource(_ value: String) {
        state.playbackSource = value
        send("playback.source", ["value": value])
        showStatus("Playback source set to \(value)", "ok")
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

    func setSearchText(_ text: String) { state.searchText = text }

    func pickSearchSource(_ key: String) {
        state.searchSource = key
        doSearch()
    }

    func doSearch() {
        let q = state.searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return }
        state.searching = true
        state.searchResults = []
        send("search", ["q": q, "source": state.searchSource])
    }

    // -- view ---------------------------------------------------------------

    func selectTab(_ key: String) { state.view = key }

    func toggleSettings() {
        state.settingsOpen.toggle()
        if state.settingsOpen { refreshPhoneStorage() }
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
