import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/**
 * The droplet's audio as the phone sees it.
 *
 * A tap is only instant when the start of the song is already on the phone,
 * because the droplet is a 4G round trip away. Android keeps the first few
 * hundred KB in ExoPlayer's cache; here the songs a tap is likely to hit get
 * an AVURLAsset loaded ahead of time, which fetches the header and the first
 * seconds, and the player picks that asset up instead of starting cold.
 */
@MainActor
enum AudioCache {
    static var session: () -> String? = { nil }
    static var tier: () -> String = { "max" }
    static var client: MaroClient?

    /**
     * Which stored copy of a song the droplet plays at the chosen tier: the
     * best at or below it, else the original. The droplet keeps one copy per
     * bitrate; `name` is the file ("m4a" is the original, "max.m4a" an
     * upgrade) and `kbps` what it measures - the number the player shows.
     */
    struct Variant: Equatable, Sendable {
        let name: String
        let kbps: Int
        let inTier: Bool
        let tier: String
        var at: Double
    }

    private static var variants: [String: Variant] = [:]

    /** The tier as a rung the droplet stores: Spotify's 320 has no YouTube copy. */
    static func rung() -> String {
        let t = tier()
        return t.isEmpty || t == "spotify" ? "max" : t
    }

    static func variant(_ videoId: String) -> Variant? {
        guard let v = variants[videoId], v.tier == rung() else { return nil }
        return v
    }

    /** Ask which copy each song plays as; songs asked recently are skipped. */
    static func lookup(_ ids: [String], maxAge: Double = 120) async {
        let now = Date().timeIntervalSince1970
        let want = Array(Set(ids.filter { id in
            !id.isEmpty && (variant(id).map { now - $0.at > maxAge } ?? true)
        }))
        guard !want.isEmpty, let client else { return }
        let rung = rung()
        if let found = await client.variants(want, tier: rung) {
            for (id, var v) in found {
                v.at = now
                variants[id] = v
            }
        }
    }

    /** Whether a copy measuring `kbps` is the tier chosen - the droplet's own windows. */
    static func inTier(_ kbps: Int) -> Bool {
        switch rung() {
        case "low": return kbps < 100
        case "normal", "high": return kbps >= 100 && kbps < 200
        default: return kbps >= 200
        }
    }

    /** Key of the asset for the copy that plays now: a new copy is a new key. */
    private static func key(_ videoId: String) -> String {
        guard let v = variant(videoId), v.name.contains(".") else { return videoId }
        return videoId + "/" + v.name
    }

    private static var warmed: [String: AVURLAsset] = [:]
    private static var warmOrder: [String] = []
    private static let warmLimit = 16

    static func asset(_ videoId: String) -> AVURLAsset {
        if let asset = warmed[key(videoId)] { return asset }
        var headers: [String: String] = [:]
        if let token = session(), !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        let url: URL
        if let v = variant(videoId), v.name.contains(".") {
            url = MaroClient.audioURL(videoId, copy: v.name)
        } else {
            url = MaroClient.audioURL(videoId)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    static func isWarm(_ videoId: String) -> Bool { warmed[key(videoId)] != nil }

    /** Load the start of a song in the background, once. */
    static func precache(_ videoId: String) {
        guard !videoId.isEmpty, warmed[key(videoId)] == nil else { return }
        let asset = asset(videoId)
        let videoId = key(videoId)
        warmed[videoId] = asset
        warmOrder.append(videoId)
        if warmOrder.count > warmLimit { warmed.removeValue(forKey: warmOrder.removeFirst()) }
        Task {
            // Not on the droplet yet, or offline: forget it so the tap takes the slow path.
            if (try? await asset.load(.isPlayable)) != true { forget(videoId) }
        }
    }

    static func forget(_ videoId: String) {
        for k in [videoId, key(videoId)] {
            warmed.removeValue(forKey: k)
            warmOrder.removeAll { $0 == k }
        }
    }

    static func clear() {
        warmed.removeAll()
        warmOrder.removeAll()
    }

    /**
     * Cover for the lock screen. MPNowPlayingInfoCenter wants an image, so the
     * art is loaded the same way the rows load it.
     */
    static func artwork(_ track: Track) async -> UIImage? {
        await ArtLoader.shared.load(artKey: track.artKey, artUrl: track.artUrl, px: 300)
    }
}

/** Write the whole song to [dir]. Runs off the main actor. */
enum AudioSaver {
    static func saveTo(_ videoId: String, dir: URL, client: MaroClient) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let req = client.request(MaroClient.audioURL(videoId).absoluteString, timeout: 60)
        let (temp, resp) = try await client.http.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "maro", code: code, userInfo: [NSLocalizedDescriptionKey: "Cloud audio is unavailable"])
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: temp.path)
        guard ((attrs?[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "maro", code: 0, userInfo: [NSLocalizedDescriptionKey: "Cloud audio was empty"])
        }
        let target = dir.appendingPathComponent(videoId + extensionOf(temp))
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    private static func extensionOf(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ".m4a" }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 12))
        guard head.count >= 8 else { return ".m4a" }
        if String(decoding: head[4..<8], as: UTF8.self) == "ftyp" { return ".m4a" }
        if head[0] == 0x1A && head[1] == 0x45 { return ".webm" }
        if String(decoding: head[0..<4], as: UTF8.self) == "OggS" { return ".ogg" }
        if String(decoding: head[0..<3], as: UTF8.self) == "ID3" { return ".mp3" }
        return ".m4a"
    }
}

@MainActor
protocol PhonePlayerEvents: AnyObject {
    func onProgress(position: Double, duration: Double, playing: Bool)
    func onStarted(tag: Int)
    func onEnded()
    func onFailed(tag: Int, notOnServer: Bool, message: String)
}

/**
 * AVPlayer for standalone phone playback. The queue lives in the view model;
 * this plays one song at a time, like the Android PhonePlayer.
 */
@MainActor
final class PhonePlayer {
    private weak var events: PhonePlayerEvents?
    private let player = AVPlayer()
    private var tag = 0
    private var started = false
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var boundaryObserver: Any?
    /** The song's real length from its metadata, 0 when unknown. */
    private var expected: Double = 0

    init(events: PhonePlayerEvents) {
        self.events = events
        player.automaticallyWaitsToMinimizeStalling = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        controlObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.report() }
        }
        // A heartbeat so the playhead estimate never drifts far.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated {
                if ended && AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) { self?.play() }
            }
        }
    }

    /** True once a real song is loaded. */
    var hasMedia: Bool { tag > 0 && player.currentItem != nil }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    var currentPosition: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func playFile(_ file: URL, tag: Int, duration: Double) { start(AVURLAsset(url: file), tag: tag, duration: duration) }

    /** A stream straight from the service (SoundCloud's own CDN). */
    func playURL(_ url: URL, tag: Int, duration: Double) { start(AVURLAsset(url: url), tag: tag, duration: duration) }

    /** YouTube's own CDN wants the same browser the URL was asked for as. */
    func playYouTube(_ url: URL, tag: Int, duration: Double) {
        let headers = ["User-Agent": YouTubeDirect.ua]
        start(AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]), tag: tag, duration: duration)
    }

    func playStream(_ videoId: String, tag: Int, duration: Double) {
        let asset = AudioCache.asset(videoId)
        AudioCache.forget(videoId)
        start(asset, tag: tag, duration: duration)
    }

    private func start(_ asset: AVURLAsset, tag: Int, duration: Double) {
        self.tag = tag
        started = false
        expected = duration
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        // The droplet's files are fragmented MP4 (YouTube's streaming layout),
        // whose length AVPlayer estimates, sometimes minutes too long: the song
        // then ran into silence. The metadata's length is the real one, so the
        // song ends there.
        if duration > 1 {
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: duration - 0.25, preferredTimescale: 600))], queue: .main
            ) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.tag == tag else { return }
                    self.events?.onEnded()
                }
            }
        }
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item, tag: tag) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tag == tag else { return }
                self.events?.onEnded()
            }
        }
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.fail(error, tag: tag) }
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func itemStatusChanged(_ item: AVPlayerItem, tag: Int) {
        guard tag == self.tag else { return }
        switch item.status {
        case .readyToPlay:
            if !started {
                started = true
                events?.onStarted(tag: tag)
            }
            report()
        case .failed:
            fail(item.error, tag: tag)
        default:
            break
        }
    }

    private func fail(_ error: Error?, tag: Int) {
        guard tag == self.tag else { return }
        let ns = error as NSError?
        // CoreMedia reports an HTTP 404 as -12938.
        let codes = [ns?.code, (ns?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code]
        let notOnServer = codes.contains(-12938) || (ns?.localizedDescription.contains("404") ?? false)
        events?.onFailed(tag: tag, notOnServer: notOnServer, message: ns?.localizedDescription ?? "Phone playback failed")
    }

    private func report() {
        guard tag > 0 else { return }
        let d = player.currentItem?.duration.seconds ?? 0
        let length = expected > 1 ? expected : (d.isFinite ? d : 0)
        events?.onProgress(position: min(currentPosition, length > 0 ? length : .infinity), duration: length, playing: player.timeControlStatus != .paused)
    }

    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
    }

    func stop() {
        tag = 0
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/**
 * The lock screen, Control Center, headset and CarPlay buttons. The queue
 * lives in the view model, so every command is routed there.
 */
@MainActor
final class NowPlaying {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (Double) -> Void
    }

    private var artKey = ""

    init(_ h: Handlers) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in h.play(); return .success }
        c.pauseCommand.addTarget { _ in h.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { _ in h.toggle(); return .success }
        c.nextTrackCommand.addTarget { _ in h.next(); return .success }
        c.previousTrackCommand.addTarget { _ in h.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            h.seek(e.positionTime)
            return .success
        }
    }

    /** Built outside the main actor: the system calls the handler on its own queue. */
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func update(track: Track?, position: Double, duration: Double, playing: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            artKey = ""
            return
        }
        var info = center.nowPlayingInfo ?? [:]
        let key = track.artKey + "|" + track.artUrl
        if key != artKey { info[MPMediaItemPropertyArtwork] = nil }
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyAlbumTitle] = track.album
        info[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : track.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
        if key != artKey {
            artKey = key
            Task {
                guard let image = await AudioCache.artwork(track), self.artKey == key else { return }
                var info = center.nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = Self.artwork(image)
                center.nowPlayingInfo = info
            }
        }
    }
}
