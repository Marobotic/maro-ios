import Foundation

/**
 * What size of a cover to ask for. Every image server Jukebox reads serves
 * the same picture at several sizes, so a box asks for the smallest one that
 * still fills it: a 56 pt row on a 3x screen is 168 px, not a 1200 px sleeve.
 * Foundation only, so the macOS unit tests check it without the app.
 */
enum ArtSize {
    /** The droplet's sizes for /covers/<id>?px= (it rounds up to one of these). */
    static let steps = [64, 96, 128, 160, 192, 256, 320, 384, 512, 640, 800, 1024]

    /** The droplet's step for a box of `px` pixels: the first one that fills it. */
    static func step(_ px: Int) -> Int { steps.first { $0 >= px } ?? steps[steps.count - 1] }

    /**
     * The URL of the same picture near `px`, "" for what is not a web URL.
     *   Spotify      i.scdn.co album 64 / 300 / 640, artist 160 / 320 / 640, mosaic 60 / 300 / 640
     *   Google       lh3.googleusercontent.com / ggpht.com  =wN-hN or =sN, any size
     *   YouTube      i.ytimg.com stills: mqdefault (320x180, no bars), hqdefault (480x360), as given above
     *   SoundCloud   i1.sndcdn.com artworks-...-t67x67 / large (100) / t300x300 / t500x500
     * Anything else comes back as it is.
     */
    static func sized(_ url: String, _ px: Int) -> String {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return "" }
        if url.contains("i.scdn.co/image/ab67616d") {
            let want = px <= 64 ? "00004851" : px <= 300 ? "00001e02" : "0000b273"
            return url.replacingOccurrences(of: "ab67616d0000(b273|1e02|4851)", with: "ab67616d\(want)", options: .regularExpression)
        }
        if url.contains("i.scdn.co/image/ab676161") {
            let want = px <= 160 ? "0000f178" : px <= 320 ? "00005174" : "0000e5eb"
            return url.replacingOccurrences(of: "ab6761610000(e5eb|5174|f178)", with: "ab676161\(want)", options: .regularExpression)
        }
        if url.contains("mosaic.scdn.co/") {
            let want = px <= 60 ? 60 : px <= 300 ? 300 : 640
            return url.replacingOccurrences(of: "mosaic\\.scdn\\.co/\\d+/", with: "mosaic.scdn.co/\(want)/", options: .regularExpression)
        }
        if url.contains("googleusercontent.com") || url.contains("ggpht.com") {
            let side = max(px, 60)
            if url.range(of: "=w\\d+-h\\d+", options: .regularExpression) != nil {
                return url.replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w\(side)-h\(side)", options: .regularExpression)
            }
            if url.range(of: "=s\\d+", options: .regularExpression) != nil {
                return url.replacingOccurrences(of: "=s\\d+", with: "=s\(side)", options: .regularExpression)
            }
            return url
        }
        if url.contains("ytimg.com/vi") {
            // The 16:9 still with no bars fills a square box up to 180 px; the
            // 4:3 one (bars in it) only when a box needs more.
            let pattern = "/(maxresdefault|sddefault|hqdefault|mqdefault|default)\\.(jpg|webp)(\\?[^#]*)?$"
            guard let range = url.range(of: pattern, options: .regularExpression) else { return url }
            let ext = url[range].contains(".webp") ? "webp" : "jpg"
            let have = String(url[range].dropFirst().prefix { $0 != "." })
            let rank = ["default": 0, "mqdefault": 1, "hqdefault": 2, "sddefault": 3, "maxresdefault": 4]
            let want = px <= 180 ? "mqdefault" : px <= 360 ? "hqdefault" : have
            // Never a bigger one than the URL named: it may not exist.
            let name = (rank[want] ?? 0) <= (rank[have] ?? 0) ? want : have
            return url.replacingCharacters(in: range, with: "/\(name).\(ext)")
        }
        if url.contains("sndcdn.com/") {
            let want = px <= 67 ? "t67x67" : px <= 100 ? "large" : px <= 300 ? "t300x300" : "t500x500"
            return url.replacingOccurrences(of: "-(large|t500x500|t300x300|t67x67|original|crop|small|tiny|mini|badge|t120x120|t240x240)\\.(jpg|png)",
                                            with: "-\(want).jpg", options: .regularExpression)
        }
        return url
    }
}
