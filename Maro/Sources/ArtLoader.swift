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
    private let memory = NSCache<NSString, UIImage>()

    private init() {
        // Application Support, not Caches: iOS may purge the cache directory
        // any time it needs space, and covers are meant to stay for good.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        diskDir = support.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memory.totalCostLimit = 24 * 1024 * 1024
    }

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

    func has(_ artKey: String) -> Bool { Self.size(of: diskFile("key:\(artKey)")) > 0 }

    func diskBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { $0 + Self.size(of: $1) }
    }

    @MainActor
    func clear() {
        memory.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
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
