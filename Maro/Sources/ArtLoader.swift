import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/**
 * Cover art for rows, the now-playing card and the lock screen.
 *
 * Decoded images stay in memory at the size they are drawn, bytes stay on
 * disk, and the network is the last resort. Decoding happens off the main
 * thread and is downsampled, so a 640 px JPEG never lands in a 30 pt row.
 * Spotify and Google serve the same image at smaller sizes, so small slots
 * ask for a small file too.
 */
final class ArtLoader: ObservableObject, @unchecked Sendable {
    static let shared = ArtLoader()

    /** Bumped when artwork is re-fetched, so visible covers load again. */
    @MainActor @Published private(set) var epoch = 0

    var client: MaroClient?
    private let diskDir: URL
    private let songDir: URL
    private let memory = NSCache<NSString, UIImage>()

    private init() {
        // Application Support, not Caches: iOS may purge the cache directory
        // any time it needs space, and covers are meant to stay for good.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        diskDir = support.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        songDir = diskDir.appendingPathComponent("songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: songDir, withIntermediateDirectories: true)
        // Once: the per-size copies kept before one cover per song. Playlist
        // tiles among them are fetched again when next shown.
        let moved = songDir.appendingPathComponent(".one-per-song")
        if !FileManager.default.fileExists(atPath: moved.path) {
            let old = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
            for f in old where f.pathExtension == "img" { try? FileManager.default.removeItem(at: f) }
            FileManager.default.createFile(atPath: moved.path, contents: Data())
        }
        // Room for a long playlist's row covers (~20 KB each) besides the big ones.
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    // ---- songs ---------------------------------------------------------------
    //
    // One cover per song, chosen by the droplet (YouTube Music's sleeve, else
    // Spotify's, else SoundCloud's, else the video's still) and answered for
    // every id the song is known by. Kept here once, as the droplet has it,
    // and scaled to exactly each box's pixel size the first time that box
    // draws it:
    //
    //   covers/songs/<master>.jpg        the droplet's picture
    //   covers/songs/<master>@<px>.jpg   the same, exactly px x px
    //   covers/songs/index.json          art key -> master, version
    //
    // A cover that changes on the droplet (Fix artwork anywhere, or a song's
    // first proper cover replacing an old copy) arrives through syncChanges().

    private let indexLock = NSLock()
    private var indexLoaded = false
    private var index: [String: (master: String, version: Int64)] = [:]
    private var since: Int64 = 0

    private func withIndex<T>(_ body: () -> T) -> T {
        indexLock.lock(); defer { indexLock.unlock() }
        if !indexLoaded {
            indexLoaded = true
            if let data = try? Data(contentsOf: songDir.appendingPathComponent("index.json")),
               let doc = JSONText.parse(data) as? JSON {
                since = doc.int64("since")
                for (k, v) in doc.obj("ids") ?? [:] {
                    if let e = v as? JSON { index[k] = (e.str("m"), e.int64("v")) }
                }
            }
        }
        return body()
    }

    private func saveIndex() {
        let doc: JSON = withIndex {
            var ids: JSON = [:]
            for (k, v) in index { ids[k] = ["m": v.master, "v": v.version] as JSON }
            return ["since": since, "ids": ids]
        }
        try? JSONText.data(doc).write(to: songDir.appendingPathComponent("index.json"), options: .atomic)
    }

    /** What the droplet can look a song up by, as a query string. */
    private static func query(_ t: Track) -> [(String, String)] {
        var q: [(String, String)] = [("t", t.title), ("a", t.artist)]
        func add(_ kind: String, _ id: String) {
            if kind == "ytm", id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { q.append(("yt", id)) }
            else if kind == "spotify", id.range(of: "^[0-9A-Za-z]{22}$", options: .regularExpression) != nil { q.append(("sp", id)) }
            else if kind == "sc", id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil { q.append(("sc", id)) }
        }
        add(t.source, t.id)
        if !t.sourceId.isEmpty && t.sourceId != t.id {
            // A song playing under another service's id keeps its own too.
            let yt = t.sourceId.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
            add(yt ? "ytm" : "spotify", t.sourceId)
        }
        if !t.videoId.isEmpty { add("ytm", t.videoId) }
        if t.artUrl.hasPrefix("https://") { q.append(("art", t.artUrl)) }
        var seen = Set<String>()
        return q.filter { !$0.1.isEmpty && seen.insert($0.0 + "=" + $0.1).inserted }
    }

    func songKey(_ t: Track, px: Int) -> String { t.artKey.isEmpty ? "" : "s:\(t.artKey)@\(px)" }

    /** A song row's cover in pixels, as the rows last drew it (prefetch asks the same size). */
    var rowPx = 84

    /** Whether this song's chosen cover is on the phone already. */
    func hasSong(_ t: Track) -> Bool {
        guard !t.artKey.isEmpty, let have = withIndex({ index[t.artKey] }) else { return false }
        return Self.size(of: masterFile(have.master)) > 0
    }

    private var jobs: [String: Task<Void, Never>] = [:]
    private let jobsLock = NSLock()

    /**
     * A list's covers ahead of being shown, decoded at row size into memory,
     * so a row scrolled - or flung - to draws its picture in its first frame
     * (rows used to wait for a fetch and a decode once drawn, and a fling
     * showed blank boxes). Rows nearest `around` first: the droplet's chosen
     * cover when it is on the phone, else the song's own picture. A new call
     * for the same `list` replaces the old one. `onDisk` only: the pictures
     * onto the disk, nothing decoded - for lists not on screen.
     */
    func prefetch(_ tracks: [Track], list: String, around: Int = 0, onDisk: Bool = false) {
        if onDisk { return prefetchToDisk(tracks) }
        let px = rowPx
        let order = tracks.indices.sorted { abs($0 - around) < abs($1 - around) }.map { tracks[$0] }
        let width = NetworkWatch.expensive ? 3 : 8
        let job = Task.detached(priority: .userInitiated) { [weak self] in
            var at = 0
            while at < order.count, !Task.isCancelled {
                let chunk = order[at..<min(at + width, order.count)]
                at += width
                await withTaskGroup(of: Void.self) { group in
                    for t in chunk { group.addTask { await self?.warmRow(t, px: px) } }
                }
            }
        }
        jobsLock.lock()
        jobs[list]?.cancel()
        jobs[list] = job
        jobsLock.unlock()
    }

    /** The best picture of `t` at `px` reachable without the droplet, into memory. */
    private func warmRow(_ t: Track, px: Int) async {
        let key = songKey(t, px: px)
        if !key.isEmpty, memory.object(forKey: key as NSString) != nil { return }
        if hasSong(t) {
            _ = await loadSong(t, px: px)
            return
        }
        if !t.artUrl.isEmpty { _ = await load(artKey: "", artUrl: t.artUrl, px: px) }
    }

    private func prefetchToDisk(_ tracks: [Track]) {
        let px = rowPx
        let urls = tracks.compactMap { t -> String? in
            guard !t.artUrl.isEmpty, !hasSong(t) else { return nil }
            let u = Self.sized(t.artUrl, px)
            return u.isEmpty || Self.size(of: diskFile(u)) > 0 ? nil : t.artUrl
        }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                // On 4G a few at a time, so the rows on screen and the music
                // are not crowded out.
                for _ in 0..<min(NetworkWatch.expensive ? 2 : 8, urls.count) {
                    let u = urls[next]; next += 1
                    group.addTask { _ = await self?.bytesFor(artKey: "", artUrl: u, px: px) }
                }
                while await group.next() != nil, next < urls.count {
                    let u = urls[next]; next += 1
                    group.addTask { _ = await self?.bytesFor(artKey: "", artUrl: u, px: px) }
                }
            }
        }
    }

    func loadSong(_ t: Track, px: Int) async -> UIImage? {
        let key = songKey(t, px: px)
        if key.isEmpty || px <= 0 { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let master = await masterFor(t), let image = scaled(master, px: px) else { return nil }
        memory.setObject(image, forKey: key as NSString, cost: px * px * 4)
        return image
    }

    private func masterFile(_ master: String) -> URL { songDir.appendingPathComponent(master + ".jpg") }

    /** The master picture for this song on disk, fetched once. */
    private func masterFor(_ t: Track) async -> URL? {
        if let have = withIndex({ index[t.artKey] }), Self.size(of: masterFile(have.master)) > 0 {
            return masterFile(have.master)
        }
        let q = Self.query(t).map { "\($0.0)=\(MaroClient.escape($0.1))" }.joined(separator: "&")
        guard let got = await client?.songCover(t.artKey, query: q) else { return nil }
        let master = got.master.isEmpty ? Self.safe(t.artKey) : got.master
        let file = masterFile(master)
        let same = withIndex { index.values.contains { $0.master == master && $0.version == got.version } }
        if !(same && Self.size(of: file) > 0) {
            try? got.bytes.write(to: file, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(at: songDir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.lastPathComponent.hasPrefix(master + "@") { try? FileManager.default.removeItem(at: f) }
        }
        withIndex {
            for (k, v) in index where v.master == master && v.version != got.version { index[k] = (master, got.version) }
            index[t.artKey] = (master, got.master.isEmpty ? 0 : got.version)
        }
        saveIndex()
        return file
    }

    /** The master at exactly px x px, made once and kept beside it. */
    private func scaled(_ master: URL, px: Int) -> UIImage? {
        let out = songDir.appendingPathComponent(master.deletingPathExtension().lastPathComponent + "@\(px).jpg")
        if let data = try? Data(contentsOf: out), let image = UIImage(data: data) { return image }
        guard let source = CGImageSourceCreateWithURL(master as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(full.width, full.height)
        let square = full.cropping(to: CGRect(x: (full.width - side) / 2, y: (full.height - side) / 2,
                                              width: side, height: side)) ?? full
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        }
        if let data = image.jpegData(compressionQuality: 0.92) { try? data.write(to: out, options: .atomic) }
        return image
    }

    /** Fix artwork: the droplet chooses the song's cover again; true when it found one. */
    func refresh(_ t: Track) async -> Bool {
        if t.artKey.isEmpty { return false }
        var hints: JSON = ["t": t.title, "a": t.artist]
        for (k, v) in Self.query(t) where ["yt", "sp", "sc"].contains(k) { hints[k] = v }
        if t.artUrl.hasPrefix("https://") { hints["arts"] = [t.artUrl] }
        guard await client?.refreshCover(t.artKey, hints: hints) == true else { return false }
        let master = withIndex { index[t.artKey]?.master }
        let same = withIndex { index.filter { $0.value.master == master }.map(\.key) }
        await forget(Set(t.trackIds + [t.artKey] + same))
        return true
    }

    /** Drop these keys' covers here, so they are fetched again when drawn. */
    @MainActor
    func forget(_ keys: Set<String>) {
        withIndex {
            var gone = Set<String>()
            for k in keys { if let e = index.removeValue(forKey: k) { gone.insert(e.master) } }
            let inUse = Set(index.values.map(\.master))
            let files = (try? FileManager.default.contentsOfDirectory(at: songDir, includingPropertiesForKeys: nil)) ?? []
            for m in gone.subtracting(inUse) {
                for f in files where f.lastPathComponent == m + ".jpg" || f.lastPathComponent.hasPrefix(m + "@") {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
        saveIndex()
        memory.removeAllObjects()
        epoch += 1
    }

    /**
     * Covers that changed on the droplet since the last look: dropped here, so
     * the rows showing them fetch the new picture. Old per-id copies are asked
     * about too, and dropped once the song has its proper cover.
     */
    func syncChanges() async {
        guard let got = await client?.coversChanged(since: withIndex({ since })) else { return }
        let now = got.int64("now")
        var stale = Set<String>()
        let (had, keys, old) = withIndex { (since, Set(index.keys), Array(index.filter { $0.value.version == 0 }.keys.prefix(20))) }
        if had > 0 {
            if got.bool("all") { stale.formUnion(keys) }
            for id in got.arr("ids") ?? [] { if let s = id as? String, keys.contains(s) { stale.insert(s) } }
        }
        for k in old {
            let master = await client?.songCoverMaster(k) ?? ""
            if !master.isEmpty { stale.insert(k) }
        }
        withIndex { since = max(since, now) }
        if stale.isEmpty { saveIndex() } else { await forget(stale) }
    }

    private static func safe(_ id: String) -> String {
        if id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil { return id }
        return Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // ---- playlist tiles ----------------------------------------------------

    /** The key a slot of [px] pixels is cached under, or "" when there is no art. */
    func key(artKey: String, artUrl: String, px: Int) -> String {
        let url = Self.sized(artUrl, px)
        if !url.isEmpty { return "u:\(url)@\(px)" }
        if !artKey.isEmpty { return "k:\(artKey)@\(px)" }
        return ""
    }

    func cached(_ key: String) -> UIImage? { key.isEmpty ? nil : memory.object(forKey: key as NSString) }

    func load(artKey: String, artUrl: String, px: Int) async -> UIImage? {
        let key = key(artKey: artKey, artUrl: artUrl, px: px)
        if key.isEmpty { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let bytes = await bytesFor(artKey: artKey, artUrl: artUrl, px: px),
              let image = Self.decode(bytes, px: px) else { return nil }
        memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    /**
     * The bytes for one cover at one slot size. When the exact size has
     * nothing on disk and its fetch fails, fall back to any other resolution
     * of the same art a sibling slot already cached.
     */
    private func bytesFor(artKey: String, artUrl: String, px: Int) async -> Data? {
        let url = Self.sized(artUrl, px)
        let file: URL
        if !url.isEmpty { file = diskFile(url) } else if !artKey.isEmpty { file = diskFile("key:\(artKey)") } else { return nil }
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        if !url.isEmpty, let data = await client?.coverURL(url), !data.isEmpty {
            try? data.write(to: file, options: .atomic)
            return data
        }
        if !artKey.isEmpty, let data = await client?.cover(artKey), !data.isEmpty {
            try? data.write(to: file, options: .atomic)
            return data
        }
        guard let found = fallback(artKey: artKey, artUrl: artUrl), let data = try? Data(contentsOf: found) else { return nil }
        if found != file { try? data.write(to: file, options: .atomic) }
        return data
    }

    /** Any already-cached resolution of the same art, largest first. */
    private func fallback(artKey: String, artUrl: String) -> URL? {
        var candidates: [String] = []
        if !artKey.isEmpty { candidates.append("key:\(artKey)") }
        if !artUrl.isEmpty {
            for px in [48, 80, 320, 640, 960, 1280] {
                let u = Self.sized(artUrl, px)
                if !u.isEmpty && u != artUrl && !candidates.contains(u) { candidates.append(u) }
            }
        }
        var best: (URL, Int64)?
        for c in candidates {
            let f = diskFile(c)
            let size = Self.size(of: f)
            if size > 0 && size > (best?.1 ?? 0) { best = (f, size) }
        }
        return best?.0
    }

    /** Forget one cover everywhere and redraw it; for "Download artwork". */
    @MainActor
    func invalidate(_ artKey: String) {
        try? FileManager.default.removeItem(at: diskFile("key:\(artKey)"))
        // NSCache cannot list its keys, so drop the lot; rows reload from disk.
        memory.removeAllObjects()
        epoch += 1
    }

    /** The copy kept for a cover fetched straight from its URL. */
    @MainActor
    func invalidate(url: String) {
        try? FileManager.default.removeItem(at: diskFile(url))
        memory.removeAllObjects()
        epoch += 1
    }

    func has(_ artKey: String) -> Bool { Self.size(of: diskFile("key:\(artKey)")) > 0 }

    func diskBytes() -> Int64 {
        let files = FileManager.default.enumerator(at: diskDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files.reduce(0) { $0 + Self.size(of: $1) }
    }

    @MainActor
    func clear() {
        memory.removeAllObjects()
        withIndex { index.removeAll(); since = 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        try? FileManager.default.createDirectory(at: songDir, withIntermediateDirectories: true)
        epoch += 1
    }

    static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func decode(_ bytes: Data, px: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options) else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(px, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func diskFile(_ id: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest + ".img")
    }

    /**
     * Ask the CDN for an image near [px]. Spotify's album art ids carry the
     * size (ab67616d 0000b273 = 640, 00001e02 = 300, 00004851 = 64); Google
     * image URLs end in =wN-hN.
     */
    static func sized(_ url: String, _ px: Int) -> String {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return "" }
        if url.contains("i.scdn.co/image/ab67616d") {
            let want = px <= 80 ? "00004851" : px <= 320 ? "00001e02" : "0000b273"
            return url.replacingOccurrences(of: "ab67616d0000(b273|1e02|4851)", with: "ab67616d\(want)", options: .regularExpression)
        }
        if (url.contains("googleusercontent.com") || url.contains("ggpht.com")),
           url.range(of: "=w\\d+-h\\d+", options: .regularExpression) != nil {
            let side = max(px, 60)
            return url.replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w\(side)-h\(side)", options: .regularExpression)
        }
        return url
    }
}
