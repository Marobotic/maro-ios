import AVFoundation
import Foundation

/**
 * The real per-second bitrate of a song, from its own compressed samples -
 * what the desktop counts with ffprobe. AVAssetReader hands over the samples
 * without decoding them (outputSettings nil), so each second's bytes are just
 * summed.
 *
 * It reads a file on this phone. A saved song already is one; a stream is
 * fetched whole first (an HLS stream as its init segment plus every piece,
 * which joined together is an ordinary fragmented MP4). That is a second
 * download of the song, so streams are only measured while the "?" panel is
 * open, and each song once.
 */
actor RateMeter {
    static let shared = RateMeter()

    private var lines: [String: [Int]] = [:]
    private var busy: Set<String> = []
    private let http = URLSession(configuration: .ephemeral)

    func known(_ key: String) -> [Int]? { lines[key] }

    /** Measure `source` under `key`, once; nil while busy or on failure. */
    func measure(key: String, file: URL? = nil, stream: URL? = nil, hls: Bool = false) async -> [Int]? {
        if let line = lines[key] { return line }
        guard !busy.contains(key) else { return nil }
        busy.insert(key)
        defer { busy.remove(key) }
        var temp: URL?
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        let path: URL
        if let file {
            path = file
        } else if let stream {
            guard let got = try? await (hls ? fetchHLS(stream) : fetch(stream)) else { return nil }
            temp = got
            path = got
        } else {
            return nil
        }
        guard let line = await Self.count(path), !line.isEmpty else { return nil }
        lines[key] = line
        if lines.count > 64 { lines.removeAll(); lines[key] = line }
        return line
    }

    private func tempFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rate-\(UUID().uuidString).\(ext)")
    }

    private func fetch(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue(YouTubeDirect.ua, forHTTPHeaderField: "User-Agent")
        let (downloaded, _) = try await http.download(for: req)
        let out = tempFile(url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
        try FileManager.default.moveItem(at: downloaded, to: out)
        return out
    }

    /** An HLS VOD playlist joined into one file: its map (init) then each piece. */
    private func fetchHLS(_ playlist: URL) async throws -> URL {
        let (data, _) = try await http.data(from: playlist)
        let text = String(decoding: data, as: UTF8.self)
        var parts: [URL] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), let r = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let uri = line[r].dropFirst(5).dropLast()
                if let u = URL(string: String(uri), relativeTo: playlist) { parts.insert(u.absoluteURL, at: 0) }
            } else if !line.isEmpty && !line.hasPrefix("#"), let u = URL(string: line, relativeTo: playlist) {
                parts.append(u.absoluteURL)
            }
        }
        guard !parts.isEmpty else { throw URLError(.cannotParseResponse) }
        let out = tempFile("mp4")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        for part in parts {
            let (bytes, _) = try await http.data(from: part)
            try handle.write(contentsOf: bytes)
        }
        return out
    }

    /** Sum each second's compressed sample bytes, as kbps. */
    static func count(_ file: URL) async -> [Int]? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var seconds: [Int: Int] = [:]
        while let buffer = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0 else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let each = CMSampleBufferGetDuration(buffer).seconds / Double(count)
            for i in 0..<count {
                let t = start + Double(i) * (each.isFinite ? each : 0)
                guard t.isFinite, t >= 0 else { continue }
                seconds[Int(t), default: 0] += CMSampleBufferGetSampleSize(buffer, at: i)
            }
        }
        guard reader.status == .completed, let last = seconds.keys.max() else { return nil }
        return (0...last).map { Int((Double(seconds[$0] ?? 0) * 8 / 1000).rounded()) }
    }
}
