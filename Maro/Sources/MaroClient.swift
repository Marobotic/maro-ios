import Foundation

/** The droplet's view of which songs it can stream: track id -> video id, and the cached videos. */
struct TrackMap {
    let map: [String: String]
    let cached: Set<String>
}

/**
 * Thin HTTP client for the maro droplet, mirrored from the Android app's
 * MaroClient and the desktop plugin's maro_account.py.
 *
 * One URLSession for everything keeps the TLS connection alive between
 * requests: on 4G a fresh handshake costs about half a second.
 */
final class MaroClient: @unchecked Sendable {
    static let base = "https://marobotic.dev/cache"
    static let defaultTimeout: TimeInterval = 8
    static let pollTimeout: TimeInterval = 36

    static func audioURL(_ videoId: String) -> URL {
        URL(string: base + "/audio/" + escape(videoId))!
    }

    /** One exact stored copy ("max.m4a"); the bytes behind it never change. */
    static func audioURL(_ videoId: String, copy: String) -> URL {
        URL(string: base + "/audio/" + escape(videoId) + "?f=" + escape(copy))!
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var _session: String?
    private var _email: String?

    let http: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = MaroClient.pollTimeout
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    var session: String? {
        lock.lock(); defer { lock.unlock() }
        return _session
    }

    var email: String? {
        lock.lock(); defer { lock.unlock() }
        return _email
    }

    /// Make a song the alarm sound in Hourglass, which signs in with this
    /// same account. The server cuts the loudest 30 s from its cached copy.
    /// Returns nil on success, else the reason.
    func hourglassAlarm(songId: String, title: String, artist: String) async -> String? {
        guard let s = session else { return "Sign in first" }
        var req = URLRequest(url: URL(string: MaroClient.base.replacingOccurrences(of: "/cache", with: "") + "/hourglass/api/ringtones/song")!, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["song_id": songId, "name": title, "artist": artist])
        guard let got = try? await http.data(for: req) else { return "No connection" }
        let data = got.0
        let code = (got.1 as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return nil }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? "Hourglass answered \(code)"
    }

    init() {
        _session = defaults.string(forKey: "session")
        _email = defaults.string(forKey: "email")
    }

    private func setAuth(_ session: String?, _ email: String?) {
        lock.lock()
        _session = session
        _email = email
        lock.unlock()
        if let session, let email {
            defaults.set(session, forKey: "session")
            defaults.set(email, forKey: "email")
        } else {
            defaults.removeObject(forKey: "session")
            defaults.removeObject(forKey: "email")
        }
    }

    func request(_ url: String, method: String = "GET", timeout: TimeInterval = defaultTimeout) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        req.httpMethod = method
        if url.hasPrefix(Self.base), let s = session { req.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func call(_ method: String, _ path: String, body: JSON? = nil, timeout: TimeInterval = defaultTimeout) async throws -> JSON {
        var req = request(Self.base + path, method: method, timeout: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSONText.data(body)
        }
        let (data, _) = try await http.data(for: req)
        if data.isEmpty { return [:] }
        return JSONText.parse(data) as? JSON ?? [:]
    }

    /** Body bytes, or nil when the server answers non-2xx. */
    private func raw(_ req: URLRequest) async -> Data? {
        guard let result = try? await http.data(for: req),
              let code = (result.1 as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return result.0
    }

    /**
     * The engine uploads a track's cover to /covers/<art key> when it resolves
     * it, so the phone asks for the art by the same key the desktop would.
     */
    func cover(_ key: String) async -> Data? {
        var req = request(Self.base + "/covers/" + Self.escape(key))
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        return await raw(req)
    }

    func coverURL(_ url: String) async -> Data? {
        guard URL(string: url) != nil else { return nil }
        var req = request(url)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return await raw(req)
    }

    /** Lyrics the desktop engine already looked up for this song, or nil. */
    func lyrics(_ key: String) async -> JSON? {
        var req = request(Self.base + "/lyrics/" + Self.escape(key))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = await raw(req) else { return nil }
        return JSONText.parse(data) as? JSON
    }

    /**
     * LRCLib straight from the phone: the fallback for when the desktop is not
     * there to ask. Same exact-match-then-search the engine starts with.
     */
    func lrclib(_ track: Track) async -> JSON? {
        func get(_ url: String) async -> Any? {
            var req = request(url)
            req.setValue("maro.music (https://marobotic.dev)", forHTTPHeaderField: "User-Agent")
            guard let data = await raw(req) else { return nil }
            return JSONText.parse(data)
        }
        let title = track.title.replacingOccurrences(
            of: #"\s*[(\[][^)\]]*(feat|ft\.|remaster|live|version)[^)\]]*[)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
        let artist = track.artist.split(whereSeparator: { $0 == "," || $0 == "&" }).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let q = "artist_name=\(Self.escape(artist))&track_name=\(Self.escape(title))"
        var hit: JSON?
        if let exact = await get("https://lrclib.net/api/get?\(q)&duration=\(Int(track.duration))") as? JSON,
           !exact.str("syncedLyrics").isEmpty || !exact.str("plainLyrics").isEmpty {
            hit = exact
        } else if let arr = await get("https://lrclib.net/api/search?\(q)") as? [Any] {
            hit = arr.compactMap { $0 as? JSON }
                .filter { track.duration <= 0 || abs($0.double("duration") - track.duration) <= 15 }
                .sorted { ($0.str("syncedLyrics").isEmpty ? 1 : 0) < ($1.str("syncedLyrics").isEmpty ? 1 : 0) }
                .first
        }
        guard let hit else { return nil }
        let synced = hit.str("syncedLyrics")
        if !synced.isEmpty {
            return SongLyrics.json(SongLyrics.parseLrc(synced), synced: true, source: "LRCLib")
        }
        return SongLyrics.json(SongLyrics.plain(hit.str("plainLyrics")), synced: false, source: "LRCLib")
    }

    /** Which tracks the droplet can already stream, or nil when unreachable. */
    /**
     * Which stored copy each song plays as at `tier`: the best at or below it,
     * else the original. Nil when the droplet cannot be reached.
     */
    func variants(_ ids: [String], tier: String) async -> [String: AudioCache.Variant]? {
        guard !ids.isEmpty else { return [:] }
        let path = "/variants?ids=" + Self.escape(ids.prefix(150).joined(separator: ","))
            + "&q=" + Self.escape(tier)
        guard let resp = try? await call("GET", path, timeout: 8) else { return nil }
        var out: [String: AudioCache.Variant] = [:]
        for (id, value) in resp.obj("variants") ?? [:] {
            guard let v = value as? JSON else { continue }
            out[id] = AudioCache.Variant(name: v.str("variant"), kbps: v.int("kbps"),
                                         inTier: v.bool("inTier"), tier: tier, at: 0)
        }
        return out
    }

    /** The droplet's per-second kbps of one stored copy, or nil. */
    func timeline(_ videoId: String, copy: String) async -> [Int]? {
        let q = copy.isEmpty ? "" : "?f=" + Self.escape(copy)
        guard let resp = try? await call("GET", "/audio/" + Self.escape(videoId) + "/timeline" + q, timeout: 20),
              let arr = resp.arr("kbps") else { return nil }
        return arr.map { ($0 as? NSNumber)?.intValue ?? 0 }
    }

    func trackMap() async -> TrackMap? {
        guard let resp = try? await call("GET", "/map", timeout: 15), let map = resp.obj("map") else { return nil }
        var out: [String: String] = [:]
        for (k, _) in map { out[k] = map.str(k) }
        let cached = (resp.arr("cached") ?? []).compactMap { $0 as? String }
        return TrackMap(map: out, cached: Set(cached))
    }

    func register(_ user: String, _ pass: String) async -> Bool { await authenticate("/auth/register", user, pass) }

    func login(_ user: String, _ pass: String) async -> Bool { await authenticate("/auth/login", user, pass) }

    private func authenticate(_ path: String, _ user: String, _ pass: String) async -> Bool {
        guard let resp = try? await call("POST", path, body: ["email": user, "password": pass]) else { return false }
        let s = resp.str("session")
        if s.isEmpty { return false }
        setAuth(s, user)
        return true
    }

    /**
     * The last snapshot this account pushed: {"kind","at","snapshot"}.
     * Returns nil when the engine has not pushed one yet.
     */
    func sync() async -> JSON? {
        guard let resp = try? await call("GET", "/sync"), !resp.str("kind").isEmpty else { return nil }
        return resp
    }

    func logout() async {
        _ = try? await call("POST", "/auth/logout")
        setAuth(nil, nil)
    }

    func account() async -> JSON? { try? await call("GET", "/account") }

    func setPlayback(_ device: String) async -> Bool {
        guard let resp = try? await call("POST", "/account/playback", body: ["device": device]) else { return false }
        return resp.str("playback") == device
    }

    // -- the shared player: one queue, one song, one playhead per account --

    /** The account's shared player, or nil when the droplet is unreachable. */
    func getPlayer() async -> JSON? {
        (try? await call("GET", "/player", timeout: 15))?.obj("player")
    }

    /**
     * Report what this phone plays. The answer carries `player` (and ok false)
     * when the sound has moved to another device in the meantime.
     */
    func putPlayer(_ body: JSON) async -> JSON? {
        try? await call("PUT", "/player", body: body, timeout: 15)
    }

    /** Move the sound to `device`; the new shared player, or nil. */
    func playerDevice(_ device: String) async -> JSON? {
        (try? await call("POST", "/player/device", body: ["device": device], timeout: 15))?.obj("player")
    }

    /** A press for whichever device plays; `from` takes over if that one is gone. */
    func playerCommand(_ action: String, _ payload: JSON, from: String) async -> Bool {
        guard let resp = try? await call("POST", "/player/command", body: ["action": action, "payload": payload, "from": from]) else { return false }
        return resp.bool("ok")
    }

    /** A song started playing here: the droplet keeps a played song for good. */
    func markPlayed(_ videoId: String) async {
        _ = try? await call("POST", "/played/" + Self.escape(videoId))
    }

    func postAction(_ action: String, _ payload: JSON = [:]) async -> Bool {
        guard let resp = try? await call("POST", "/relay/desktop", body: ["action": action, "payload": payload]) else { return false }
        return resp.bool("ok")
    }

    /**
     * Long-poll the phone queue so now-playing snapshots arrive as the desktop
     * engine emits them. Runs until the task is cancelled or [stop] says so.
     */
    func phonePump(deviceId: String, deviceName: @escaping @Sendable () async -> String, solo: @escaping @Sendable () async -> Bool, stop: @escaping @Sendable () async -> Bool, onEvent: @escaping @Sendable (JSON) async -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            // Carry on after the last message this phone handled, even across a
            // restart: from 0 the backlog replays, and a play command someone
            // sent a few seconds before the restart would start music on launch.
            let seqKey = "relaySeq:\(deviceId)"
            var after = Int64(defaults.integer(forKey: seqKey))
            let q = Self.escape(deviceId)
            while !Task.isCancelled {
                if await stop() { return }
                // Read per poll: a rename reaches the account on the next one.
                let n = Self.escape(await deviceName())
                let alone = await solo() ? 1 : 0
                do {
                    var req = request("\(Self.base)/relay/phone?device=\(q)&name=\(n)&solo=\(alone)&after=\(after)&wait=25", timeout: Self.pollTimeout)
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (data, resp) = try await http.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(code), let body = JSONText.parse(data) as? JSON {
                        for case let msg as JSON in body.arr("messages") ?? [] { await onEvent(msg) }
                        let seq = body.int64("seq", after)
                        if seq != after {
                            after = seq
                            defaults.set(Int(seq), forKey: seqKey)
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
}
