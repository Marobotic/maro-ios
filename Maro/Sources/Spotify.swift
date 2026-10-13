import Foundation

/**
 * Spotify on this phone: the desktop's own Spotify helper (librespot, in
 * spotify/), compiled into the app as a static library. Same commands, same
 * events, one JSON object each - jb_spotify_send() in place of its stdin and
 * a callback in place of its stdout. It plays 320 kbps Ogg Vorbis straight to
 * the speaker through CoreAudio, inside the app's own audio session.
 *
 * The login is the desktop's, from the account (ServiceSessions "librespot"):
 * librespot's stored credentials, written where the player looks for them.
 */
@MainActor
final class Spotify {
    static let shared = Spotify()

    /** What the player said last, for PhonePlayer. */
    enum Event {
        case playing(uri: String, ms: Int)
        case paused(uri: String, ms: Int)
        case loading(uri: String)
        case ended(uri: String)
        case unavailable(uri: String)
        case bitrate(uri: String, ms: Int, kbps: Int, nominal: Int)
        case signedOut(String)
        case error(String)
    }

    var onEvent: ((Event) -> Void)?

    private(set) var ready = false
    private(set) var user = ""
    private var started = false
    private var startedWith: Data?
    private var rid = 0
    private var waiting: [Int: CheckedContinuation<Any?, Never>] = [:]

    private var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("spotify", isDirectory: true)
    }

    /** True when the account (or this phone) holds a Spotify login. */
    var hasLogin: Bool { ServiceSessions.shared.session(ServiceSessions.librespot)?.obj("credentials") != nil }

    /**
     * Start the player on the login the account holds, or restart it when
     * that login changed. Cheap to call again: nothing happens if it is the
     * same login and the player is up.
     */
    func start() {
        guard let creds = ServiceSessions.shared.session(ServiceSessions.librespot)?.obj("credentials") else {
            stopForSignOut()
            return
        }
        let data = JSONText.data(creds)
        if started && data == startedWith { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("credentials.json")
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        startedWith = data
        started = true
        ready = false
        _ = dir.path.withCString { jb_spotify_start($0, spotifyEvent) }
    }

    private func stopForSignOut() {
        guard started else { return }
        send(["cmd": "quit"])
        started = false
        ready = false
        startedWith = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("credentials.json"))
    }

    // -- commands ----------------------------------------------------------

    @discardableResult
    private func send(_ cmd: JSON) -> Bool {
        JSONText.string(cmd).withCString { jb_spotify_send($0) }
    }

    func load(_ uri: String, play: Bool = true, ms: Int = 0) { send(["cmd": "load", "uri": uri, "play": play, "pos": ms]) }
    func play() { send(["cmd": "play"]) }
    func pause() { send(["cmd": "pause"]) }
    func stop() { send(["cmd": "stop"]) }
    func seek(ms: Int) { send(["cmd": "seek", "pos": max(0, ms)]) }
    func volume(_ value: Double) { send(["cmd": "volume", "value": min(max(value, 0), 1)]) }
    /** Load the next song paused on a standby player, so it starts at once. */
    func stage(_ uri: String) { send(["cmd": "stage", "uri": uri, "role": "next"]) }

    /** A library call ("search", "liked", "playlists", "playlist"): its data, or nil. */
    func ask(_ cmd: String, _ args: JSON = [:]) async -> Any? {
        guard started else { return nil }
        rid += 1
        let id = rid
        var body = args
        body["cmd"] = cmd
        body["rid"] = id
        return await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            waiting[id] = k
            if !send(body) {
                waiting.removeValue(forKey: id)?.resume(returning: nil)
                return
            }
            // A reply that never comes must not hang a search forever.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self.waiting.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func search(_ q: String) async -> [Track] {
        ((await ask("search", ["q": q])) as? [JSON] ?? []).map(Self.track)
    }

    /** The helper's Web-API-shaped track, as a row. */
    static func track(_ o: JSON) -> Track {
        var t = Track()
        t.source = "spotify"
        t.id = o.str("id")
        t.title = o.str("name")
        t.artist = ((o["artists"] as? [JSON]) ?? []).map { $0.str("name") }.filter { !$0.isEmpty }.joined(separator: ", ")
        t.album = o.obj("album")?.str("name") ?? ""
        t.artUrl = ((o.obj("album")?["images"] as? [JSON])?.first?.str("url")) ?? ""
        t.duration = Double((o["duration_ms"] as? Int) ?? 0) / 1000
        return t
    }

    // -- events ------------------------------------------------------------

    fileprivate func handle(_ line: String) {
        guard let ev = JSONText.object(line) else { return }
        let uri = ev.str("uri")
        let ms = (ev["pos"] as? Int) ?? 0
        switch ev.str("ev") {
        case "ready":
            ready = true
            user = ev.str("user")
        case "reply":
            let id = (ev["rid"] as? Int) ?? -1
            waiting.removeValue(forKey: id)?.resume(returning: (ev["ok"] as? Bool) == true ? ev["data"] : nil)
        case "playing": onEvent?(.playing(uri: uri, ms: ms))
        case "paused": onEvent?(.paused(uri: uri, ms: ms))
        case "loading": onEvent?(.loading(uri: uri))
        case "end": onEvent?(.ended(uri: uri))
        case "unavailable": onEvent?(.unavailable(uri: uri))
        case "bitrate":
            onEvent?(.bitrate(uri: uri, ms: ms, kbps: (ev["kbps"] as? Int) ?? 0, nominal: (ev["nominal"] as? Int) ?? 0))
        case "error":
            if ev.str("code") == "signed_out" {
                ready = false
                started = false
                onEvent?(.signedOut(ev.str("message")))
            } else {
                onEvent?(.error(ev.str("message")))
            }
        default:
            break
        }
    }
}

/** Called on one of the player's own threads; everything else is on main. */
private let spotifyEvent: @convention(c) (UnsafePointer<CChar>?) -> Void = { line in
    guard let line else { return }
    let text = String(cString: line)
    DispatchQueue.main.async { MainActor.assumeIsolated { Spotify.shared.handle(text) } }
}
