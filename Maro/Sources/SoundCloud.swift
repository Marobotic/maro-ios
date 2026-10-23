import Foundation

/**
 * SoundCloud straight from this phone: api-v2, the API soundcloud.com itself
 * uses, with the site's public client id and - when the account holds one -
 * the user's own sign-in (ServiceSessions "soundcloud"), which brings their
 * library and Go+ tracks in full.
 *
 * Ported from the desktop's sidecar/soundcloud.py. One difference: AVPlayer
 * plays HLS natively, so the 160 kbps AAC stream comes first here, where the
 * desktop starts with the 128 kbps MP3 file because its player seeks a plain
 * file best.
 *
 * Like the desktop, it never plays what SoundCloud only serves encrypted
 * (major-label releases): those fall back to the same song elsewhere.
 */
actor SoundCloud {
    static let shared = SoundCloud()

    struct Unplayable: Error { let reason: String }

    struct Stream {
        let url: URL
        let kbps: Int
        let codec: String
        let hls: Bool
    }

    private static let api = "https://api-v2.soundcloud.com"
    // A desktop browser's name: a phone's is sent to m.soundcloud.com, whose
    // page carries no client id at all.
    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private static let idKey = "soundcloudClientId"

    private var clientId = UserDefaults.standard.string(forKey: idKey) ?? ""
    private var tracks: [String: JSON] = [:]
    private let http = URLSession(configuration: .default)

    private var token: String { ServiceSessions.shared.session(ServiceSessions.soundcloud)?.str("token") ?? "" }

    var signedIn: Bool { !token.isEmpty }

    /** Who a SoundCloud login belongs to: {"id", "name"}, the desktop's shape. */
    func me(token: String) async -> JSON? {
        guard let cid = try? await id(refresh: false),
              let url = URL(string: Self.api + "/me?client_id=" + cid) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await http.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let me = JSONText.parse(data) as? JSON else { return nil }
        let id = "\(me["id"] ?? "")"
        return id.isEmpty ? nil : ["id": id, "name": me.str("username").ifEmpty(me.str("permalink"))]
    }

    // -- transport --------------------------------------------------------

    private func get(_ url: URL, json: Bool = true) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        if json { req.setValue("application/json", forHTTPHeaderField: "Accept") }
        if !token.isEmpty, url.host?.hasSuffix("soundcloud.com") == true {
            // The site's own login, sent the way its web player sends it.
            req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await http.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func freshClientId() async throws -> String {
        let (page, _) = try await get(URL(string: "https://soundcloud.com/")!, json: false)
        let html = String(decoding: page, as: UTF8.self)
        let scripts = html.matches(#"<script[^>]+src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#)
        for src in scripts.reversed() {                 // it lives in one of the last ones
            guard let url = URL(string: src), let (js, _) = try? await get(url, json: false) else { continue }
            if let id = String(decoding: js, as: UTF8.self).matches(#"client_id\s*:\s*"([0-9a-zA-Z]{32})""#).first {
                return id
            }
        }
        throw Unplayable(reason: "SoundCloud's client id was not found")
    }

    private func id(refresh: Bool) async throws -> String {
        if refresh || clientId.isEmpty {
            clientId = try await freshClientId()
            UserDefaults.standard.set(clientId, forKey: Self.idKey)
        }
        return clientId
    }

    /** One API call; a rotated client id answers 401/403, so fetch it once more. */
    private func call(_ path: String, _ params: [String: String] = [:]) async throws -> JSON {
        for attempt in 0..<2 {
            var c = URLComponents(string: Self.api + path)!
            var q = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            q.append(URLQueryItem(name: "client_id", value: try await id(refresh: attempt == 1)))
            c.queryItems = q
            let (data, code) = try await get(c.url!)
            if attempt == 0 && (code == 401 || code == 403) { continue }
            guard (200..<300).contains(code) else { throw Unplayable(reason: "SoundCloud answered \(code)") }
            return JSONText.parse(data) as? JSON ?? [:]
        }
        throw Unplayable(reason: "SoundCloud refused the request")
    }

    // -- tracks -----------------------------------------------------------

    private static func streams(_ t: JSON) -> [JSON] {
        let list = (t.obj("media")?["transcodings"] as? [JSON]) ?? []
        return list.filter {
            let proto = $0.obj("format")?.str("protocol") ?? ""
            return !proto.contains("encrypted") && !(($0["snipped"] as? Bool) ?? false)
        }
    }

    private func normalise(_ t: JSON) -> Track {
        let id = "\(t["id"] ?? "")"
        tracks[id] = t
        let art = t.str("artwork_url").ifEmpty(t.obj("user")?.str("avatar_url") ?? "")
        let ms = (t["full_duration"] as? Double) ?? (t["duration"] as? Double) ?? 0
        var track = Track()
        track.source = "sc"
        track.id = id
        track.title = t.str("title")
        track.artist = (t.obj("publisher_metadata")?.str("artist")).flatMap { $0.isEmpty ? nil : $0 }
            ?? t.obj("user")?.str("username") ?? ""
        track.album = t.obj("publisher_metadata")?.str("album_title") ?? ""
        track.duration = ms / 1000
        track.artUrl = art.replacingOccurrences(of: "-large.", with: "-t500x500.")
        return track
    }

    func search(_ q: String, limit: Int = 20) async throws -> [Track] {
        let data = try await call("/search/tracks", ["q": q, "limit": "\(limit)"])
        let items = (data["collection"] as? [JSON]) ?? []
        return items.filter { $0.str("kind") == "track" }.map(normalise)
    }

    /** The tracks behind a pasted SoundCloud link: a song, a set, or a profile. */
    func open(link: String) async throws -> [Track] {
        var url = link.trimmingCharacters(in: .whitespaces)
        if url.contains("on.soundcloud.com") || url.contains("snd.sc/"), let short = URL(string: url) {
            // Short links are redirects to the page they name.
            var req = URLRequest(url: short, timeoutInterval: 15)
            req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await http.data(for: req), let final = resp.url { url = final.absoluteString }
        }
        url = String(url.split(separator: "?", maxSplits: 1).first ?? "")
            .replacingOccurrences(of: "://m.soundcloud.com", with: "://soundcloud.com")
        let data = try await call("/resolve", ["url": url])
        switch data.str("kind") {
        case "track":
            return [normalise(data)]
        case "playlist":
            // A set lists only its first few tracks in full; the rest by id.
            let items = (data["tracks"] as? [JSON]) ?? []
            let missing = items.filter { $0["title"] == nil }.map { "\($0["id"] ?? "")" }
            var full: [String: JSON] = [:]
            for chunk in stride(from: 0, to: missing.count, by: 50) {
                let ids = missing[chunk..<min(chunk + 50, missing.count)].joined(separator: ",")
                if let got = try? await callList("/tracks", ["ids": ids]) {
                    for t in got { full["\(t["id"] ?? "")"] = t }
                }
            }
            return items.compactMap { t in
                let id = "\(t["id"] ?? "")"
                return t["title"] != nil ? normalise(t) : full[id].map(normalise)
            }
        case "user":
            let tracks = try await call("/users/\(data["id"] ?? "")/tracks", ["limit": "50"])
            return ((tracks["collection"] as? [JSON]) ?? []).filter { $0.str("kind") == "track" }.map(normalise)
        default:
            return []
        }
    }

    private func callList(_ path: String, _ params: [String: String]) async throws -> [JSON] {
        var c = URLComponents(string: Self.api + path)!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "client_id", value: try await id(refresh: false))]
        let (data, code) = try await get(c.url!)
        guard (200..<300).contains(code) else { return [] }
        return JSONText.parse(data) as? [JSON] ?? []
    }

    // -- the same song from another service ---------------------------------

    private var matches: [String: Track] = [:]

    /**
     * The same song on SoundCloud, streamed in full, or nil - the desktop's
     * soundcloud_equivalent. Normally only the artist's own upload counts.
     * `loose` is for when SoundCloud was picked for this song by hand: if the
     * official copy is a preview, a full-length upload of the same recording by
     * someone else will do (same title, the artist named, within three
     * seconds of the same length, no remix/cover/live/sped-up marker).
     */
    func equivalent(of track: Track, loose: Bool) async -> Track? {
        let title = track.title.trimmingCharacters(in: .whitespaces)
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }
        let key = track.source + ":" + track.id
        if let hit = matches[key] ?? (loose ? matches[key + "~any"] : nil) { return hit }
        guard let found = try? await search("\(title) \(artist)".trimmingCharacters(in: .whitespaces), limit: 20) else { return nil }
        let wantTitle = Match.words(title), wantArtist = Match.words(artist)
        let mine = Match.spaced(title)
        let versions = Match.versionWords + ["boosted", "bass", "fast", "reverb", "copy", "quality", "type beat", "prod", "loop"]
        let candidates = found.filter { c in
            guard let raw = tracks[c.id], !Self.streams(raw).isEmpty, !["SNIP", "BLOCK"].contains(raw.str("policy")) else { return false }
            let theirs = Match.spaced(c.title)
            if versions.contains(where: { theirs.contains(" \($0) ") && !mine.contains(" \($0) ") }) { return false }
            return Match.overlap(wantTitle, Match.words(c.title)) >= 0.6
        }
        func official(_ c: Track) -> Bool {
            if !wantArtist.isEmpty && Match.overlap(wantArtist, Match.words(c.artist)) < 0.5 { return false }
            let d = track.duration, got = c.duration
            return !(d > 0 && got > 0 && abs(got - d) > max(10, d * 0.1))
        }
        func reupload(_ c: Track) -> Bool {
            if !wantArtist.isEmpty && Match.overlap(wantArtist, Match.words(c.artist + " " + c.title)) < 0.5 { return false }
            return track.duration > 0 && c.duration > 0 && abs(c.duration - track.duration) <= 3
        }
        if let pick = candidates.first(where: official) {
            matches[key] = pick
            return pick
        }
        if loose, let pick = candidates.first(where: reupload) {
            // Kept apart, so the standing "Prefer SoundCloud" never picks up a
            // re-upload from an earlier one-off choice.
            matches[key + "~any"] = pick
            return pick
        }
        return nil
    }

    /**
     * A URL AVPlayer can open for this track: HLS AAC, then the MP3 file, then
     * anything else plain. Throws Unplayable for DRM-only and preview-only.
     */
    func resolve(_ trackId: String) async throws -> Stream {
        let t: JSON
        if let known = tracks[trackId] { t = known } else { t = try await call("/tracks/" + trackId); tracks[trackId] = t }
        if ["SNIP", "BLOCK"].contains(t.str("policy")) {
            throw Unplayable(reason: "SoundCloud only plays a preview of this track")
        }
        func rank(_ tc: JSON) -> Int {
            let f = tc.obj("format") ?? [:]
            let hls = f.str("protocol") == "hls", aac = f.str("mime_type").contains("mp4") || f.str("mime_type").contains("aac")
            if hls && aac { return 0 }
            if !hls && f.str("mime_type").contains("mpeg") { return 1 }
            return 2
        }
        var params = ["client_id": try await id(refresh: false)]
        let auth = t.str("track_authorization")
        if !auth.isEmpty { params["track_authorization"] = auth }
        // A label release lists plain streams next to its encrypted ones, but
        // the plain ones answer 403/404: only when all of them refuse is the
        // track DRM-only.
        for tc in Self.streams(t).sorted(by: { rank($0) < rank($1) }) {
            guard var c = URLComponents(string: tc.str("url")) else { continue }
            c.queryItems = (c.queryItems ?? []) + params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let (data, code) = try? await get(c.url!), (200..<300).contains(code),
                  let body = JSONText.parse(data) as? JSON, let url = URL(string: body.str("url")) else { continue }
            let mime = tc.obj("format")?.str("mime_type") ?? ""
            let aac = mime.contains("mp4") || mime.contains("aac")
            return Stream(url: url, kbps: aac ? 160 : mime.contains("ogg") ? 64 : 128,
                          codec: aac ? "aac" : mime.contains("mpeg") ? "mp3" : "opus",
                          hls: tc.obj("format")?.str("protocol") == "hls")
        }
        throw Unplayable(reason: "SoundCloud only streams this track with DRM")
    }
}

private extension String {
    /** Every first capture group of `pattern` in this string. */
    func matches(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}
