import Foundation

/**
 * YouTube audio in one request, straight from this phone: the desktop's
 * sidecar/yt_direct.py. YouTube's player API, asked as the Apple Vision Pro
 * app (client VISIONOS), answers with direct audio URLs - nothing to decipher
 * - in about 150 ms. It is the guest stream (about 130 kbps AAC); the droplet's
 * cache still has the 256 kbps Premium copies, and the phone plays those
 * when they are there. This is for when they are not, or the droplet is down.
 */
actor YouTubeDirect {
    static let shared = YouTubeDirect()

    struct Refused: Error { let reason: String }

    struct Stream {
        let url: URL
        let kbps: Int
        let codec: String
        let expires: Double
    }

    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let client: JSON = [
        "clientName": "VISIONOS", "clientVersion": "1.02", "userAgent": ua,
        "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
        "osName": "visionOS", "osVersion": "26.5.23O471",
        "hl": "en", "gl": "US", "utcOffsetMinutes": 0,
    ]
    private static let player = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&alt=json")!
    private static let visitorAge: Double = 6 * 3600

    private var visitorId = ""
    private var visitorAt: Double = 0
    private var cache: [String: Stream] = [:]
    private let http = URLSession(configuration: .ephemeral)

    /** A visitor id: the cookie-less identity a guest player request carries. */
    private func visitor(refresh: Bool) async -> String {
        let now = Date().timeIntervalSince1970
        if !refresh && !visitorId.isEmpty && now - visitorAt < Self.visitorAge { return visitorId }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!, timeoutInterval: 10)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await http.data(for: req) else { return visitorId }
        let text = String(decoding: data, as: UTF8.self)
        if let r = text.range(of: #""(Cg[A-Za-z0-9_\-%]{20,})""#, options: .regularExpression) {
            visitorId = String(text[r].dropFirst().dropLast())
            visitorAt = now
        }
        return visitorId
    }

    private func ask(_ videoId: String, _ vis: String) async throws -> JSON {
        var client = Self.client
        if !vis.isEmpty { client["visitorData"] = vis }
        let cpn = String((0..<16).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".randomElement()! })
        let body: JSON = [
            "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true, "cpn": cpn,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
            "context": ["client": client, "user": ["enableSafetyMode": false], "request": ["useSsl": true]],
        ]
        var req = URLRequest(url: Self.player, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = JSONText.data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("101", forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue("1.02", forHTTPHeaderField: "X-Youtube-Client-Version")
        if !vis.isEmpty { req.setValue(vis, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let (data, resp) = try await http.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Refused(reason: "YouTube answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return JSONText.parse(data) as? JSON ?? [:]
    }

    /**
     * Songs on YouTube Music for a search, asked from this phone (the
     * site's own search, songs only). Each row: title, then artists · album ·
     * length.
     */
    func search(_ q: String) async -> [Track] {
        let body: JSON = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20251006.01.00", "hl": "en", "gl": "US"]],
            "query": q,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D",      // songs
        ]
        var req = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.httpBody = JSONText.data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await http.data(for: req), let d = JSONText.parse(data) as? JSON else { return [] }
        let tabs = (d.obj("contents")?.obj("tabbedSearchResultsRenderer")?["tabs"] as? [JSON]) ?? []
        let sections = (tabs.first?.obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")?["contents"] as? [JSON]) ?? []
        var out: [Track] = []
        for section in sections {
            for item in (section.obj("musicShelfRenderer")?["contents"] as? [JSON]) ?? [] {
                guard let r = item.obj("musicResponsiveListItemRenderer"),
                      let videoId = r.obj("playlistItemData")?.str("videoId"), !videoId.isEmpty else { continue }
                let cols = ((r["flexColumns"] as? [JSON]) ?? []).map { col -> [String] in
                    ((col.obj("musicResponsiveListItemFlexColumnRenderer")?.obj("text")?["runs"] as? [JSON]) ?? []).map { $0.str("text") }
                }
                let meta = cols.count > 1 ? cols[1] : []
                // Runs between " • " separators: artists, album, length.
                var groups: [[String]] = [[]]
                for run in meta {
                    if run.trimmingCharacters(in: .whitespaces) == "\u{2022}" { groups.append([]) } else { groups[groups.count - 1].append(run) }
                }
                var t = Track()
                t.source = "ytm"
                t.id = videoId
                t.videoId = videoId
                t.title = cols.first?.joined() ?? ""
                t.artist = groups.first?.joined().trimmingCharacters(in: .whitespaces) ?? ""
                t.album = groups.count > 2 ? groups[1].joined().trimmingCharacters(in: .whitespaces) : ""
                if let length = groups.last?.joined().trimmingCharacters(in: .whitespaces), length.contains(":") {
                    t.duration = length.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
                }
                let thumbs = (r.obj("thumbnail")?.obj("musicThumbnailRenderer")?.obj("thumbnail")?["thumbnails"] as? [JSON]) ?? []
                t.artUrl = thumbs.last?.str("url") ?? ""
                out.append(t)
            }
        }
        return out
    }

    /**
     * YouTube's stream addresses are tied to the address they were asked
     * from: after a change of network every kept one answers 403.
     */
    func forgetStreams() { cache.removeAll() }

    /** The best AAC stream AVPlayer can open for this video, and its rate. */
    func audio(_ videoId: String) async throws -> Stream {
        if let hit = cache[videoId], hit.expires - Date().timeIntervalSince1970 > 300 { return hit }
        var data = try await ask(videoId, await visitor(refresh: false))
        var status = data.obj("playabilityStatus")?.str("status") ?? ""
        if status == "LOGIN_REQUIRED" {
            // A visitor YouTube has grown suspicious of: one fresh one, once.
            data = try await ask(videoId, await visitor(refresh: true))
            status = data.obj("playabilityStatus")?.str("status") ?? ""
        }
        guard status == "OK" else {
            throw Refused(reason: data.obj("playabilityStatus")?.str("reason").ifEmpty(status) ?? status)
        }
        let formats = ((data.obj("streamingData")?["adaptiveFormats"] as? [JSON]) ?? []).filter {
            !$0.str("url").isEmpty && $0.str("mimeType").hasPrefix("audio/mp4")   // AVPlayer: AAC, not WebM
        }
        guard let best = formats.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }),
              let url = URL(string: best.str("url")) else {
            throw Refused(reason: "YouTube gave no direct AAC audio for this track")
        }
        let bps = (best["averageBitrate"] as? Int) ?? (best["bitrate"] as? Int) ?? 0
        var expires = Date().timeIntervalSince1970 + 3600
        if let r = best.str("url").range(of: #"[?&]expire=(\d+)"#, options: .regularExpression),
           let n = Double(best.str("url")[r].split(separator: "=").last ?? "") { expires = n }
        let stream = Stream(url: url, kbps: Int((Double(bps) / 1000).rounded()), codec: "aac", expires: expires)
        cache[videoId] = stream
        if cache.count > 200 { cache.removeAll() }
        return stream
    }
}
