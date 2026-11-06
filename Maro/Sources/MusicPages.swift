import CryptoKit
import Foundation

/**
 * Artist and album pages, from YouTube Music itself (innertube, the
 * WEB_REMIX client, no sign-in needed): the same calls the Windows app makes.
 * An artist name is looked up with the artists filter, its page browsed by
 * its channel id (UC...); an album is browsed by its release id (MPREb...).
 * Answers are kept in memory and on disk for a day.
 */

/** Where a "See all" goes: a browse id and its params. */
struct BrowseRef: Equatable, Hashable {
    var browseId = ""
    var params = ""
}

/** A page opened over the tabs. */
enum DetailPage: Equatable, Hashable {
    case artist(name: String, id: String, art: String)
    case album(name: String, id: String, art: String, artist: String)
    /** An artist's whole list of albums or singles ("See all"). */
    case releases(title: String, artist: String, ref: BrowseRef)

    var key: String {
        switch self {
        case .artist(let name, let id, _):
            return id.isEmpty ? "artist:n:" + YTMParse.fold(name) : "artist:" + id
        case .album(let name, let id, _, let artist):
            return id.isEmpty ? "album:n:" + YTMParse.fold(name) + "|" + YTMParse.fold(artist) : "album:" + id
        case .releases(_, _, let ref):
            return "releases:" + ref.browseId + "|" + ref.params
        }
    }
}

/** An album, single or EP as a tile. */
struct ReleaseItem: Equatable, Hashable {
    var id = ""
    var title = ""
    var year = ""
    var kind = ""
    var art = ""

    func toJSON() -> JSON { ["id": id, "title": title, "year": year, "kind": kind, "art": art] }

    static func from(_ o: JSON) -> ReleaseItem {
        ReleaseItem(id: o.str("id"), title: o.str("title"), year: o.str("year"), kind: o.str("kind"), art: o.str("art"))
    }
}

struct ArtistLink: Equatable, Hashable {
    var name = ""
    var id = ""
}

struct ArtistInfo: Equatable {
    var id = ""
    var name = ""
    var photo = ""
    var subtitle = ""
    var songs: [Track] = []
    /** The "Top songs" list (VL...): every song rather than the first five. */
    var songsList = ""
    var albums: [ReleaseItem] = []
    var singles: [ReleaseItem] = []
    var albumsMore: BrowseRef?
    var singlesMore: BrowseRef?

    func toJSON() -> JSON {
        var o: JSON = [
            "id": id, "name": name, "photo": photo, "subtitle": subtitle, "songsList": songsList,
            "songs": songs.map { $0.toJSON() },
            "albums": albums.map { $0.toJSON() },
            "singles": singles.map { $0.toJSON() },
        ]
        if let albumsMore { o["albumsMore"] = ["browseId": albumsMore.browseId, "params": albumsMore.params] }
        if let singlesMore { o["singlesMore"] = ["browseId": singlesMore.browseId, "params": singlesMore.params] }
        return o
    }

    static func from(_ o: JSON) -> ArtistInfo {
        func ref(_ v: JSON?) -> BrowseRef? {
            guard let v, !v.str("browseId").isEmpty else { return nil }
            return BrowseRef(browseId: v.str("browseId"), params: v.str("params"))
        }
        var a = ArtistInfo()
        a.id = o.str("id")
        a.name = o.str("name")
        a.photo = o.str("photo")
        a.subtitle = o.str("subtitle")
        a.songsList = o.str("songsList")
        a.songs = Sync.tracks(o.arr("songs"))
        a.albums = ((o.arr("albums") as? [JSON]) ?? []).map(ReleaseItem.from)
        a.singles = ((o.arr("singles") as? [JSON]) ?? []).map(ReleaseItem.from)
        a.albumsMore = ref(o.obj("albumsMore"))
        a.singlesMore = ref(o.obj("singlesMore"))
        return a
    }
}

struct AlbumInfo: Equatable {
    var id = ""
    var title = ""
    var kind = "Album"
    var artists: [ArtistLink] = []
    var year = ""
    var trackCount = 0
    var length = ""
    var art = ""
    var tracks: [Track] = []

    func toJSON() -> JSON {
        [
            "id": id, "title": title, "kind": kind, "year": year, "trackCount": trackCount, "length": length, "art": art,
            "artists": artists.map { ["name": $0.name, "id": $0.id] },
            "tracks": tracks.map { $0.toJSON() },
        ]
    }

    static func from(_ o: JSON) -> AlbumInfo {
        var a = AlbumInfo()
        a.id = o.str("id")
        a.title = o.str("title")
        a.kind = o.str("kind", "Album").ifEmpty("Album")
        a.year = o.str("year")
        a.trackCount = o.int("trackCount")
        a.length = o.str("length")
        a.art = o.str("art")
        a.artists = ((o.arr("artists") as? [JSON]) ?? []).map { ArtistLink(name: $0.str("name"), id: $0.str("id")) }
        a.tracks = Sync.tracks(o.arr("tracks"))
        return a
    }
}

// -- reading innertube answers ---------------------------------------------------

enum YTMParse {
    /** For comparing names: no case, no accents, no outer spaces. */
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased().trimmingCharacters(in: .whitespaces)
    }

    static func runs(_ v: JSON?) -> [JSON] { (v?["runs"] as? [JSON]) ?? [] }

    static func text(_ v: JSON?) -> String {
        guard let v else { return "" }
        if let s = v["simpleText"] as? String { return s }
        return runs(v).map { $0.str("text") }.joined()
    }

    /** The largest picture of an object holding a musicThumbnailRenderer. */
    static func thumb(_ v: JSON?) -> String {
        let list = v?.obj("musicThumbnailRenderer")?.obj("thumbnail")?["thumbnails"] as? [JSON]
        return list?.last?.str("url") ?? ""
    }

    static func browse(_ run: JSON?) -> JSON? { run?.obj("navigationEndpoint")?.obj("browseEndpoint") }

    static func pageType(_ endpoint: JSON?) -> String {
        endpoint?.obj("browseEndpointContextSupportedConfigs")?.obj("browseEndpointContextMusicConfig")?.str("pageType") ?? ""
    }

    static func seconds(_ s: String) -> Double {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        let nums = parts.compactMap { Double($0) }
        guard nums.count >= 2, nums.count == parts.count else { return 0 }
        return nums.reduce(0) { $0 * 60 + $1 }
    }

    /** Google's picture servers crop to any size: a square 544 px one for a round artist photo. */
    static func square(_ url: String) -> String {
        guard url.contains("googleusercontent.com") else { return url }
        return url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w544-h544", options: .regularExpression)
    }

    private static func isSeparator(_ s: String) -> Bool {
        ["", "\u{2022}", ",", "&"].contains(s.trimmingCharacters(in: .whitespaces))
    }

    private static func columns(_ r: JSON) -> [[JSON]] {
        ((r["flexColumns"] as? [JSON]) ?? []).map { runs($0.obj("musicResponsiveListItemFlexColumnRenderer")?.obj("text")) }
    }

    private static func sectionList(_ v: JSON?) -> [JSON] {
        let tabs = v?.obj("contents")?.obj("singleColumnBrowseResultsRenderer")?["tabs"] as? [JSON]
        return (tabs?.first?.obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")?["contents"] as? [JSON]) ?? []
    }

    /** Every list row of a search answer. */
    static func searchRows(_ v: JSON) -> [JSON] {
        let tabs = v.obj("contents")?.obj("tabbedSearchResultsRenderer")?["tabs"] as? [JSON]
        let sections = (tabs?.first?.obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")?["contents"] as? [JSON]) ?? []
        return sections.flatMap { (($0.obj("musicShelfRenderer")?["contents"] as? [JSON]) ?? []).compactMap { $0.obj("musicResponsiveListItemRenderer") } }
    }

    static func rowTitle(_ r: JSON) -> String { columns(r).first?.map { $0.str("text") }.joined() ?? "" }

    static func rowText(_ r: JSON) -> String {
        columns(r).dropFirst().map { $0.map { $0.str("text") }.joined() }.joined(separator: " ")
    }

    /** A song row of an artist's or album's page (or a search): source "ytm", its video id set. */
    static func song(_ item: JSON) -> Track? {
        guard let r = item.obj("musicResponsiveListItemRenderer") else { return nil }
        let cols = columns(r)
        var vid = r.obj("playlistItemData")?.str("videoId") ?? ""
        if vid.isEmpty { vid = cols.first?.first?.obj("navigationEndpoint")?.obj("watchEndpoint")?.str("videoId") ?? "" }
        if vid.isEmpty {
            vid = r.obj("overlay")?.obj("musicItemThumbnailOverlayRenderer")?.obj("content")?.obj("musicPlayButtonRenderer")?
                .obj("playNavigationEndpoint")?.obj("watchEndpoint")?.str("videoId") ?? ""
        }
        guard !vid.isEmpty else { return nil }
        var t = Track()
        t.source = "ytm"
        t.id = vid
        t.videoId = vid
        t.title = cols.first?.map { $0.str("text") }.joined() ?? ""
        var names: [String] = []
        for col in cols.dropFirst() {
            for run in col {
                let text = run.str("text")
                if isSeparator(text) { continue }
                let end = browse(run)
                let id = end?.str("browseId") ?? ""
                let type = pageType(end)
                if type == "MUSIC_PAGE_TYPE_ALBUM" || id.hasPrefix("MPRE") {
                    if t.album.isEmpty {
                        t.album = text
                        t.albumId = id
                    }
                } else if type == "MUSIC_PAGE_TYPE_ARTIST" || type == "MUSIC_PAGE_TYPE_USER_CHANNEL" || id.hasPrefix("UC") {
                    names.append(text)
                    if t.artistId.isEmpty { t.artistId = id }
                } else if t.duration == 0 && seconds(text) > 0 {
                    t.duration = seconds(text)
                }
            }
        }
        t.artist = names.joined(separator: ", ")
        if t.duration == 0 {
            let fixed = (r["fixedColumns"] as? [JSON])?.first?.obj("musicResponsiveListItemFixedColumnRenderer")?.obj("text")
            t.duration = seconds(text(fixed))
        }
        t.artUrl = thumb(r.obj("thumbnail"))
        return t
    }

    /** An album / single / EP tile (musicTwoRowItemRenderer). */
    static func release(_ item: JSON, kind fallback: String) -> ReleaseItem? {
        guard let r = item.obj("musicTwoRowItemRenderer") else { return nil }
        let end = r.obj("navigationEndpoint")?.obj("browseEndpoint") ?? browse(runs(r.obj("title")).first)
        let id = end?.str("browseId") ?? ""
        guard id.hasPrefix("MPRE") else { return nil }
        var out = ReleaseItem(id: id, title: text(r.obj("title")), kind: fallback, art: thumb(r.obj("thumbnailRenderer")))
        for run in runs(r.obj("subtitle")) {
            let t = run.str("text").trimmingCharacters(in: .whitespaces)
            if ["Album", "Single", "EP"].contains(t) {
                out.kind = t
            } else if t.count == 4, Int(t) != nil {
                out.year = t
            }
        }
        return out
    }

    static func artist(_ v: JSON, id: String) -> ArtistInfo {
        var a = ArtistInfo()
        a.id = id
        let head = v.obj("header")
        let h = head?.obj("musicImmersiveHeaderRenderer") ?? head?.obj("musicVisualHeaderRenderer") ?? [:]
        a.name = text(h.obj("title"))
        a.photo = square(thumb(h.obj("foregroundThumbnail")).ifEmpty(thumb(h.obj("thumbnail"))))
        let monthly = text(h.obj("monthlyListenerCount"))
        let subs = text(h.obj("subscriptionButton")?.obj("subscribeButtonRenderer")?.obj("subscriberCountText"))
        a.subtitle = !monthly.isEmpty ? monthly : subs.isEmpty ? "" : subs + " subscribers"
        for section in sectionList(v) {
            if let shelf = section.obj("musicShelfRenderer"), a.songs.isEmpty {
                a.songs = ((shelf["contents"] as? [JSON]) ?? []).compactMap { item -> Track? in
                    guard var t = song(item) else { return nil }
                    if t.artist.isEmpty { t.artist = a.name }
                    if t.artistId.isEmpty { t.artistId = id }
                    return t
                }
                let list = shelf.obj("bottomEndpoint")?.obj("browseEndpoint")?.str("browseId") ?? browse(runs(shelf.obj("title")).first)?.str("browseId") ?? ""
                a.songsList = list.hasPrefix("VL") ? list : ""
            } else if let carousel = section.obj("musicCarouselShelfRenderer") {
                let header = carousel.obj("header")?.obj("musicCarouselShelfBasicHeaderRenderer")
                let title = fold(text(header?.obj("title")))
                let albums = title == "albums", singles = title.hasPrefix("singles")
                if !albums && !singles { continue }
                let items = ((carousel["contents"] as? [JSON]) ?? []).compactMap { release($0, kind: albums ? "Album" : "Single") }
                var more: BrowseRef?
                let end = header?.obj("moreContentButton")?.obj("buttonRenderer")?.obj("navigationEndpoint")?.obj("browseEndpoint")
                    ?? browse(runs(header?.obj("title")).first)
                if let end, !end.str("browseId").isEmpty,
                   pageType(end) == "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY" || end.str("browseId").hasPrefix("MPAD") {
                    more = BrowseRef(browseId: end.str("browseId"), params: end.str("params"))
                }
                if albums {
                    a.albums = items
                    a.albumsMore = more
                } else {
                    a.singles = items
                    a.singlesMore = more
                }
            }
        }
        return a
    }

    static func album(_ v: JSON, id: String) -> AlbumInfo {
        var a = AlbumInfo()
        a.id = id
        let two = v.obj("contents")?.obj("twoColumnBrowseResultsRenderer")
        let tabs = two?["tabs"] as? [JSON]
        let top = tabs?.first?.obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")?["contents"] as? [JSON]
        let h = top?.first?.obj("musicResponsiveHeaderRenderer") ?? [:]
        a.title = text(h.obj("title"))
        for run in runs(h.obj("subtitle")) {
            let t = run.str("text").trimmingCharacters(in: .whitespaces)
            if ["Album", "Single", "EP"].contains(t) {
                a.kind = t
            } else if t.count == 4, Int(t) != nil {
                a.year = t
            }
        }
        for run in runs(h.obj("straplineTextOne")) where !isSeparator(run.str("text")) {
            a.artists.append(ArtistLink(name: run.str("text").trimmingCharacters(in: .whitespaces), id: browse(run)?.str("browseId") ?? ""))
        }
        for run in runs(h.obj("secondSubtitle")) {
            let t = run.str("text").trimmingCharacters(in: .whitespaces)
            if t.contains("song") || t.contains("track"), let n = Int(t.split(separator: " ").first ?? "") {
                a.trackCount = n
            } else if t.contains("minute") || t.contains("hour") {
                a.length = t
            }
        }
        a.art = thumb(h.obj("thumbnail"))
        let sections = (two?.obj("secondaryContents")?.obj("sectionListRenderer")?["contents"] as? [JSON]) ?? []
        let shelf = sections.compactMap { $0.obj("musicShelfRenderer") }.first
        let names = a.artists.map(\.name).joined(separator: ", ")
        a.tracks = ((shelf?["contents"] as? [JSON]) ?? []).compactMap { item -> Track? in
            guard var t = song(item) else { return nil }
            if t.artist.isEmpty {
                t.artist = names
                t.artistId = a.artists.first?.id ?? ""
            }
            if t.album.isEmpty {
                t.album = a.title
                t.albumId = id
            }
            if t.artUrl.isEmpty { t.artUrl = a.art }
            return t
        }
        if a.trackCount == 0 { a.trackCount = a.tracks.count }
        return a
    }

    /** A discography page ("See all"): its grid of tiles. */
    static func grid(_ v: JSON) -> [ReleaseItem] {
        sectionList(v).flatMap { section -> [ReleaseItem] in
            let items = (section.obj("gridRenderer")?["items"] as? [JSON]) ?? []
            return items.compactMap { release($0, kind: "Album") }
        }
    }
}

struct PageMissing: Error {}

extension YouTubeMusic {
    private static let artistsFilter = "EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D"
    private static let albumsFilter = "EgWKAQIYAWoKEAMQBBAJEAoQBQ%3D%3D"

    /** The artist a name means: the best name match of an artists search. */
    func findArtist(_ name: String) async throws -> (id: String, photo: String)? {
        let v = try await call("search", ["query": name, "params": Self.artistsFilter], signed: false)
        let want = YTMParse.fold(name)
        var first: (id: String, photo: String)?
        for r in YTMParse.searchRows(v) {
            let id = r.obj("navigationEndpoint")?.obj("browseEndpoint")?.str("browseId") ?? ""
            guard id.hasPrefix("UC") else { continue }
            let hit = (id: id, photo: YTMParse.square(YTMParse.thumb(r.obj("thumbnail"))))
            if YTMParse.fold(YTMParse.rowTitle(r)) == want { return hit }
            if first == nil { first = hit }
        }
        return first
    }

    /** The release a name (and its artist) means. */
    func findAlbum(_ name: String, artist: String) async throws -> String? {
        let query = artist.isEmpty ? name : name + " " + artist
        let v = try await call("search", ["query": query, "params": Self.albumsFilter], signed: false)
        let want = YTMParse.fold(name), by = YTMParse.fold(artist.components(separatedBy: ",").first ?? "")
        var titled: String?, first: String?
        for r in YTMParse.searchRows(v) {
            let id = r.obj("navigationEndpoint")?.obj("browseEndpoint")?.str("browseId") ?? ""
            guard id.hasPrefix("MPRE") else { continue }
            let same = YTMParse.fold(YTMParse.rowTitle(r)) == want
            if same && (by.isEmpty || YTMParse.fold(YTMParse.rowText(r)).contains(by)) { return id }
            if same && titled == nil { titled = id }
            if first == nil { first = id }
        }
        return titled ?? first
    }

    /** Who this phone's YouTube Music session belongs to; "" when Google no longer takes it. */
    func accountName() async -> String {
        guard signedIn, let v = try? await call("account/account_menu", [:], signed: true) else { return "" }
        let popup = (v["actions"] as? [JSON])?.first?.obj("openPopupAction")?.obj("popup")
        let header = popup?.obj("multiPageMenuRenderer")?.obj("header")?.obj("activeAccountHeaderRenderer")
        return YTMParse.text(header?.obj("accountName"))
    }

    func artistPage(_ id: String) async throws -> ArtistInfo {
        YTMParse.artist(try await call("browse", ["browseId": id], signed: false), id: id)
    }

    func albumPage(_ id: String) async throws -> AlbumInfo {
        YTMParse.album(try await call("browse", ["browseId": id], signed: false), id: id)
    }

    func releases(_ ref: BrowseRef) async throws -> [ReleaseItem] {
        var body: JSON = ["browseId": ref.browseId]
        if !ref.params.isEmpty { body["params"] = ref.params }
        return YTMParse.grid(try await call("browse", body, signed: false))
    }
}

// -- the pages' answers, kept ----------------------------------------------------

private func digest(_ key: String) -> String {
    Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class PageStore: ObservableObject {
    static let shared = PageStore()

    enum Status: Equatable { case loading, ready, failed }

    @Published private(set) var artists: [String: ArtistInfo] = [:]
    @Published private(set) var albums: [String: AlbumInfo] = [:]
    @Published private(set) var releases: [String: [ReleaseItem]] = [:]
    /** An artist's every top song, once asked for ("Show all"). */
    @Published private(set) var allSongs: [String: [Track]] = [:]
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var songsLoading: Set<String> = []

    private static let maxAge: Double = 24 * 3600
    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ytm-pages", isDirectory: true)
    }()

    func load(_ page: DetailPage) {
        let key = page.key
        if let s = status[key], s != .failed { return }
        if let raw = readDisk(key, maxAge: Self.maxAge) {
            apply(page, raw)
            status[key] = .ready
            return
        }
        status[key] = .loading
        Task {
            do {
                let raw = try await fetch(page)
                writeDisk(key, raw)
                apply(page, raw)
                status[key] = .ready
            } catch {
                // An old answer beats none.
                if let raw = readDisk(key, maxAge: .infinity) {
                    apply(page, raw)
                    status[key] = .ready
                } else {
                    status[key] = .failed
                }
            }
        }
    }

    /** Every top song of an artist: the "Top songs" list behind the first five. */
    func loadAllSongs(_ key: String) {
        guard let info = artists[key], info.songsList.hasPrefix("VL"), allSongs[key] == nil, !songsLoading.contains(key) else { return }
        songsLoading.insert(key)
        Task {
            let list = String(info.songsList.dropFirst(2))
            let found = (try? await YouTubeMusic.shared.playlist(list)) ?? []
            songsLoading.remove(key)
            if !found.isEmpty { allSongs[key] = found }
        }
    }

    private func fetch(_ page: DetailPage) async throws -> JSON {
        let yt = YouTubeMusic.shared
        switch page {
        case .artist(let name, let id, _):
            var browseId = id, photo = ""
            if browseId.isEmpty {
                guard let hit = try await yt.findArtist(name) else { throw PageMissing() }
                browseId = hit.id
                photo = hit.photo
            }
            var info = try await yt.artistPage(browseId)
            if info.name.isEmpty && info.songs.isEmpty && info.albums.isEmpty { throw PageMissing() }
            if !photo.isEmpty { info.photo = photo }
            return info.toJSON()
        case .album(let name, let id, _, let artist):
            var browseId = id
            if browseId.isEmpty {
                guard let found = try await yt.findAlbum(name, artist: artist) else { throw PageMissing() }
                browseId = found
            }
            let info = try await yt.albumPage(browseId)
            if info.tracks.isEmpty { throw PageMissing() }
            return info.toJSON()
        case .releases(_, _, let ref):
            let items = try await yt.releases(ref)
            if items.isEmpty { throw PageMissing() }
            return ["items": items.map { $0.toJSON() }]
        }
    }

    private func apply(_ page: DetailPage, _ raw: JSON) {
        let key = page.key
        switch page {
        case .artist: artists[key] = ArtistInfo.from(raw)
        case .album: albums[key] = AlbumInfo.from(raw)
        case .releases: releases[key] = ((raw.arr("items") as? [JSON]) ?? []).map(ReleaseItem.from)
        }
    }

    private func readDisk(_ key: String, maxAge: Double) -> JSON? {
        let file = dir.appendingPathComponent(digest(key) + ".json")
        guard let data = try? Data(contentsOf: file), let o = JSONText.parse(data) as? JSON,
              Date().timeIntervalSince1970 - o.double("at") < maxAge else { return nil }
        return o.obj("data")
    }

    private func writeDisk(_ key: String, _ raw: JSON) {
        let file = dir.appendingPathComponent(digest(key) + ".json"), folder = dir
        let data = JSONText.data(["at": Date().timeIntervalSince1970, "data": raw] as JSON)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
