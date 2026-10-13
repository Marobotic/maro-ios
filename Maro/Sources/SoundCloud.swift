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
    }

    private static let api = "https://api-v2.soundcloud.com"
    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let idKey = "soundcloudClientId"

    private var clientId = UserDefaults.standard.string(forKey: idKey) ?? ""
    private var tracks: [String: JSON] = [:]
    private let http = URLSession(configuration: .default)

    private var token: String { ServiceSessions.shared.session(ServiceSessions.soundcloud)?.str("token") ?? "" }

    var signedIn: Bool { !token.isEmpty }

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
                          codec: aac ? "aac" : mime.contains("mpeg") ? "mp3" : "opus")
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
