import CryptoKit
import Foundation

/**
 * The Discover tab's sources, asked from this phone itself (no desktop):
 * Discover Weekly and the rest of Spotify's home page through the phone's
 * own Spotify player, Discover Mix and the other mixes from YouTube Music's
 * home page with the phone's YouTube Music session, and song radios from
 * both. The same choices as the desktop's discover.rs.
 *
 * Ids: "sp:pl:<playlist>", "yt:pl:<playlist>", "sp:radio:<track>", "yt:radio:<video>".
 */
struct DiscoverItem: Equatable, Hashable {
    var id = ""
    var service = ""        // "spotify" | "ytm"
    var name = ""
    var sub = ""
    var art = ""

    func toJSON() -> JSON { ["id": id, "service": service, "name": name, "sub": sub, "art": art] }
    static func from(_ o: JSON) -> DiscoverItem {
        DiscoverItem(id: o.str("id"), service: o.str("service"), name: o.str("name"), sub: o.str("sub"), art: o.str("art"))
    }
}

struct DiscoverSection: Equatable, Hashable {
    var key = ""
    var title = ""
    var items: [DiscoverItem] = []
}

// -- YouTube Music, signed in with this phone's session -----------------------

actor YouTubeMusic {
    static let shared = YouTubeMusic()
    private let http = URLSession(configuration: .ephemeral)
    private static let origin = "https://music.youtube.com"

    /** The session's cookie header, when YouTube Music is signed in here. */
    private func cookie() -> String {
        ServiceSessions.shared.session(ServiceSessions.ytm)?.obj("headers")?.str("cookie") ?? ""
    }

    var signedIn: Bool { !cookie().isEmpty }

    private static func cookieValue(_ cookies: String, _ name: String) -> String {
        for part in cookies.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == name { return String(kv[1]) }
        }
        return ""
    }

    private func call(_ endpoint: String, _ body: JSON, signed: Bool) async throws -> JSON {
        var body = body
        let d = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
        let version = String(format: "1.%04d%02d%02d.01.00", d.year ?? 2026, d.month ?? 1, d.day ?? 1)
        body["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": version, "hl": "en"], "user": [:] as JSON]
        var req = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?alt=json&prettyPrint=false")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = JSONText.data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        req.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        req.setValue(YouTubeDirect.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let cookies = signed ? cookie() : ""
        if !cookies.isEmpty {
            let sid = Self.cookieValue(cookies, "__Secure-3PAPISID").ifEmpty(Self.cookieValue(cookies, "SAPISID"))
            let ts = Int(Date().timeIntervalSince1970)
            let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sid) \(Self.origin)".utf8)).map { String(format: "%02x", $0) }.joined()
            req.setValue(cookies, forHTTPHeaderField: "Cookie")
            req.setValue("SAPISIDHASH \(ts)_\(hash)", forHTTPHeaderField: "Authorization")
            req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        let (data, resp) = try await http.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = JSONText.parse(data) as? JSON else {
            throw YouTubeDirect.Refused(reason: "YouTube Music answered \(code)")
        }
        return json
    }

    private static func text(_ v: JSON?) -> String {
        guard let v else { return "" }
        if let s = v["simpleText"] as? String { return s }
        return ((v["runs"] as? [JSON]) ?? []).map { $0.str("text") }.joined()
    }

    private static func lastThumb(_ v: Any?) -> String { ((v as? [JSON])?.last?.str("url")) ?? "" }

    private static func seconds(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func pageType(_ run: JSON) -> String {
        run.obj("navigationEndpoint")?.obj("browseEndpoint")?.obj("browseEndpointContextSupportedConfigs")?
            .obj("browseEndpointContextMusicConfig")?.str("pageType") ?? ""
    }

    /** A YouTube Music song row. */
    private static func song(_ id: String, _ title: String, _ byline: [JSON], _ length: String, _ art: String) -> Track {
        var artists: [String] = [], album = "", segment = 0
        for run in byline {
            let t = run.str("text")
            if t.trimmingCharacters(in: .whitespaces) == "\u{2022}" { segment += 1; continue }
            if pageType(run) == "MUSIC_PAGE_TYPE_ALBUM" {
                album = t
            } else if segment == 0 && ![",", "&", ""].contains(t.trimmingCharacters(in: .whitespaces)) {
                artists.append(t)
            }
        }
        var track = Track()
        track.source = "ytm"
        track.id = id
        track.videoId = id
        track.title = title
        track.artist = artists.joined(separator: ", ")
        track.album = album
        track.duration = seconds(length)
        track.artUrl = art
        return track
    }

    /** One row of a playlist page. */
    private static func playlistRow(_ item: JSON) -> Track? {
        guard let r = item.obj("musicResponsiveListItemRenderer"),
              let id = r.obj("playlistItemData")?.str("videoId"), !id.isEmpty else { return nil }
        let cols = (r["flexColumns"] as? [JSON]) ?? []
        func col(_ i: Int) -> [JSON] {
            (cols[safe: i]?.obj("musicResponsiveListItemFlexColumnRenderer")?.obj("text")?["runs"] as? [JSON]) ?? []
        }
        var byline = col(1)
        if let third = col(2).first, pageType(third) == "MUSIC_PAGE_TYPE_ALBUM" { byline += [["text": " \u{2022} "], third] }
        let fixed = ((r["fixedColumns"] as? [JSON])?.first?.obj("musicResponsiveListItemFixedColumnRenderer")?.obj("text"))
        let art = lastThumb(r.obj("thumbnail")?.obj("musicThumbnailRenderer")?.obj("thumbnail")?["thumbnails"])
        return song(id, col(0).first?.str("text") ?? "", byline, text(fixed), art)
    }

    /** A playlist's first page (a mix is one page: 50 to 100 songs). */
    func playlist(_ id: String) async throws -> [Track] {
        let v = try await call("browse", ["browseId": "VL" + id], signed: true)
        let two = v.obj("contents")?.obj("twoColumnBrowseResultsRenderer")?.obj("secondaryContents")?.obj("sectionListRenderer")?["contents"] as? [JSON]
        let one = (v.obj("contents")?.obj("singleColumnBrowseResultsRenderer")?["tabs"] as? [JSON])?.first?.obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")?["contents"] as? [JSON]
        let shelf = (two ?? one)?.first?.obj("musicPlaylistShelfRenderer")?["contents"] as? [JSON] ?? []
        return shelf.compactMap(Self.playlistRow)
    }

    /** A song's radio: about 50 songs that follow it. Works signed out too. */
    func radio(_ videoId: String) async throws -> [Track] {
        let v = try await call("next", ["videoId": videoId, "playlistId": "RDAMVM" + videoId, "isAudioOnly": true], signed: true)
        let tabs = v.obj("contents")?.obj("singleColumnMusicWatchNextResultsRenderer")?.obj("tabbedRenderer")?
            .obj("watchNextTabbedResultsRenderer")?["tabs"] as? [JSON]
        let panel = tabs?.first?.obj("tabRenderer")?.obj("content")?.obj("musicQueueRenderer")?.obj("content")?
            .obj("playlistPanelRenderer")?["contents"] as? [JSON] ?? []
        return panel.compactMap { item in
            guard let r = item.obj("playlistPanelVideoRenderer")
                    ?? item.obj("playlistPanelVideoWrapperRenderer")?.obj("primaryRenderer")?.obj("playlistPanelVideoRenderer"),
                  !r.str("videoId").isEmpty else { return nil }
            return Self.song(r.str("videoId"), Self.text(r.obj("title")), (r.obj("longBylineText")?["runs"] as? [JSON]) ?? [],
                             Self.text(r.obj("lengthText")), Self.lastThumb(r.obj("thumbnail")?["thumbnails"]))
        }
    }

    /**
     * From the home page: the mixes made for this account (Discover Mix, My
     * Supermix, New Release Mix...) and the song radios of "Your daily
     * discover". Each {id, name, sub, art}; a radio's id is its video.
     */
    func home() async throws -> (mixes: [JSON], radios: [JSON]) {
        var v = try await call("browse", ["browseId": "FEmusic_home"], signed: true)
        var mixes: [JSON] = [], radios: [JSON] = []
        for _ in 0..<6 {
            let list: JSON? = v.obj("continuationContents")?.obj("sectionListContinuation")
                ?? (v.obj("contents")?.obj("singleColumnBrowseResultsRenderer")?["tabs"] as? [JSON])?.first?
                    .obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")
            for shelf in (list?["contents"] as? [JSON]) ?? [] {
                guard let c = shelf.obj("musicCarouselShelfRenderer") else { continue }
                let title = Self.text(c.obj("header")?.obj("musicCarouselShelfBasicHeaderRenderer")?.obj("title")).lowercased()
                for it in (c["contents"] as? [JSON]) ?? [] {
                    guard let r = it.obj("musicTwoRowItemRenderer") else { continue }
                    let nav = r.obj("navigationEndpoint")
                    let art = Self.lastThumb(r.obj("thumbnailRenderer")?.obj("musicThumbnailRenderer")?.obj("thumbnail")?["thumbnails"])
                    func item(_ id: String) -> JSON { ["id": id, "name": Self.text(r.obj("title")), "sub": Self.text(r.obj("subtitle")), "art": art] }
                    let browse = nav?.obj("browseEndpoint")?.str("browseId") ?? ""
                    if browse.hasPrefix("VLRDTMAK") {
                        let id = String(browse.dropFirst(2))
                        if !mixes.contains(where: { $0.str("id") == id }) { mixes.append(item(id)) }
                    } else if title.contains("discover"), let w = nav?.obj("watchEndpoint"), w.str("playlistId").hasPrefix("RDAMVM") {
                        let vid = w.str("videoId")
                        if !vid.isEmpty && !radios.contains(where: { $0.str("id") == vid }) { radios.append(item(vid)) }
                    }
                }
            }
            let token = ((list?["continuations"] as? [JSON])?.first?.obj("nextContinuationData")?.str("continuation")) ?? ""
            if token.isEmpty { break }
            v = try await call("browse", ["continuation": token], signed: true)
        }
        return (mixes, radios)
    }
}

// -- Spotify's home page -------------------------------------------------------

enum SpotifyHome {
    // The web player's "home" query id as of October 2026.
    private static let known = "5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1"
    private static let saved = "spotifyHomeHash"

    /** The current query id, read from the web player's own script. */
    private static func fresh() async -> String? {
        var req = URLRequest(url: URL(string: "https://open.spotify.com/")!, timeoutInterval: 15)
        req.setValue(YouTubeDirect.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let page = String(decoding: data, as: UTF8.self)
        guard let at = page.range(of: "/cdn/build/web-player/web-player."),
              let start = page[..<at.lowerBound].lastIndex(of: "\""),
              let end = page[at.upperBound...].range(of: ".js") else { return nil }
        guard let url = URL(string: String(page[page.index(after: start)..<end.upperBound])),
              let (js, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let script = String(decoding: js, as: UTF8.self)
        guard let key = script.range(of: "\"home\",\"query\",\"") else { return nil }
        let hash = String(script[key.upperBound...].prefix(64))
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }

    /** The home page's sections, with a fresh query id once if the kept one is refused. */
    @MainActor
    static func sections() async -> [JSON]? {
        let hash = UserDefaults.standard.string(forKey: saved) ?? known
        if let got = await Spotify.shared.home(hash: hash) { return got }
        guard let new = await fresh(), new != hash else { return nil }
        UserDefaults.standard.set(new, forKey: saved)
        return await Spotify.shared.home(hash: new)
    }
}

// -- kept on the phone ---------------------------------------------------------

/** The page's sources (discover.json) and each opened list's songs (discover/<id>.json), with when. */
final class DiscoverStore: @unchecked Sendable {
    static let shared = DiscoverStore()
    private let dir: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("device-cache/discover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ id: String) -> URL {
        let name = Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".json")
    }

    func page() -> JSON? { (try? Data(contentsOf: dir.appendingPathComponent("page.json"))).flatMap { JSONText.parse($0) as? JSON } }

    func savePage(_ page: JSON) { try? JSONText.data(page).write(to: dir.appendingPathComponent("page.json"), options: .atomic) }

    func list(_ id: String) -> (tracks: [Track], at: Double)? {
        guard let data = try? Data(contentsOf: file(id)), let o = JSONText.parse(data) as? JSON else { return nil }
        return (Sync.tracks(o.arr("tracks")), o.double("at"))
    }

    func saveList(_ id: String, _ tracks: [Track]) {
        let o: JSON = ["at": Date().timeIntervalSince1970, "tracks": tracks.map { $0.toJSON() }]
        try? JSONText.data(o).write(to: file(id), options: .atomic)
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

enum DiscoverPage {
    /** A list's songs from its service. */
    @MainActor
    static func fetch(_ id: String) async -> [Track]? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        switch (parts[0], parts[1]) {
        case ("sp", "pl"):
            Spotify.shared.start()
            return await Spotify.shared.playlist(parts[2])
        case ("sp", "radio"):
            Spotify.shared.start()
            return await Spotify.shared.radio(parts[2])?.tracks
        case ("yt", "pl"): return try? await YouTubeMusic.shared.playlist(parts[2])
        case ("yt", "radio"): return try? await YouTubeMusic.shared.radio(parts[2])
        default: return nil
        }
    }

    /**
     * The tab's three sections from what the home pages offered and the songs
     * played lately: Discover Weekly (and its YouTube Music counterpart),
     * Radio, and everything else made for the account.
     */
    static func build(_ raw: JSON, recent: [Track], spotify: Bool, ytm: Bool) -> [DiscoverSection] {
        let spSections = spotify ? ((raw.obj("spotify")?.arr("sections") as? [JSON]) ?? []) : []
        let spItems: [(String, JSON)] = spSections.flatMap { sec in ((sec.arr("items") as? [JSON]) ?? []).map { (sec.str("title").lowercased(), $0) } }
        let mixes = ytm ? ((raw.obj("ytm")?.arr("mixes") as? [JSON]) ?? []) : []
        let radios = ytm ? ((raw.obj("ytm")?.arr("radios") as? [JSON]) ?? []) : []
        func sp(_ o: JSON) -> DiscoverItem { DiscoverItem(id: "sp:pl:" + o.str("id"), service: "spotify", name: o.str("name"), sub: o.str("description"), art: o.str("art")) }
        func yt(_ o: JSON, _ kind: String) -> DiscoverItem { DiscoverItem(id: "yt:\(kind):" + o.str("id"), service: "ytm", name: o.str("name"), sub: o.str("sub"), art: o.str("art")) }
        var seen = Set<String>()
        func take(_ list: inout [DiscoverItem], _ it: DiscoverItem) { if seen.insert(it.id).inserted { list.append(it) } }

        var weekly: [DiscoverItem] = []
        if let it = spItems.first(where: { $0.1.str("name") == "Discover Weekly" }) { take(&weekly, sp(it.1)) }
        if let it = mixes.first(where: { $0.str("name") == "Discover Mix" }) { take(&weekly, yt(it, "pl")) }
        for it in spItems where it.1.str("name") == "Release Radar" { take(&weekly, sp(it.1)) }
        if let it = mixes.first(where: { $0.str("name") == "New Release Mix" }) { take(&weekly, yt(it, "pl")) }

        var radio: [DiscoverItem] = []
        var artists = Set<String>()
        for t in recent where radio.count < 4 {
            let artist = (t.artist.split(separator: ",").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if artist.isEmpty || !artists.insert(artist).inserted { continue }
            let id: String
            if t.source == "spotify" && spotify { id = "sp:radio:" + t.id }
            else if t.source == "ytm" { id = "yt:radio:" + t.id }
            else if !t.videoId.isEmpty { id = "yt:radio:" + t.videoId }
            else { continue }
            take(&radio, DiscoverItem(id: id, service: id.hasPrefix("sp") ? "spotify" : "ytm", name: t.title + " Radio", sub: "Songs like " + t.artist, art: t.artUrl))
        }
        let stations = spItems.filter { $0.0.contains("station") || $0.0.contains("radio") || $0.1.str("name").hasSuffix(" Radio") }.map { sp($0.1) }
        let daily = radios.map { o -> DiscoverItem in var x = yt(o, "radio"); x.name = o.str("name") + " Radio"; return x }
        for i in 0..<max(stations.count, daily.count) {
            for l in [stations, daily] where radio.count < 24 { if let x = l[safe: i] { take(&radio, x) } }
        }

        var more: [DiscoverItem] = []
        for it in spItems where it.1.str("name").hasPrefix("Daily Mix") || it.1.str("name") == "daylist" { take(&more, sp(it.1)) }
        for it in mixes { take(&more, yt(it, "pl")) }
        for it in spItems where it.0.contains("mix") && more.count < 40 { take(&more, sp(it.1)) }

        return [
            DiscoverSection(key: "weekly", title: "Discover Weekly", items: weekly),
            DiscoverSection(key: "radio", title: "Radio", items: radio),
            DiscoverSection(key: "more", title: "Made for you", items: more),
        ]
    }
}
