import AVFoundation
import Foundation
import os

private let slog = Logger(subsystem: "dev.marobotic.maro", category: "Stream")

/**
 * The start of a song, on the phone before the tap - the iPhone's version of
 * the Android app's ExoPlayer cache.
 *
 * A song from the droplet (or YouTube's own stream) took 2-8 s to start on
 * 4G: AVPlayer reads the head of the file (the index and the first seconds)
 * in several round trips before it plays. Here the first `headBytes` of the
 * songs on screen and next in the queue are fetched ahead with one request
 * each, and the player reads through this loader: what is in the head comes
 * from memory at once, the rest streams from the network behind it.
 */
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamLoader()

    /** About 8 s of 256 kbps audio, past the index and the first fragment. */
    static let headBytes = 256 * 1024
    private static let scheme = "jbstream"
    private static let keep = 60

    private struct Source { let url: URL; let headers: [String: String] }
    private struct Head { let data: Data; let total: Int64 }

    let queue = DispatchQueue(label: "dev.marobotic.maro.stream")
    private let lock = NSLock()
    private var sources: [String: Source] = [:]
    private var heads: [String: Head] = [:]
    private var headOrder: [String] = []
    private var fetching: [String: [(Head?) -> Void]] = [:]
    private var running = 0
    /** Asked and answered 404: not on the droplet (the player's failure says so). */
    private var missing: Set<String> = []
    private var waiting: [String] = []

    private lazy var session: URLSession = {
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: ops)
    }()

    // -- the asset ---------------------------------------------------------

    /** An asset that plays `url` through the head kept here. */
    func asset(_ url: URL, headers: [String: String]) -> AVURLAsset {
        let key = url.absoluteString
        lock.lock()
        sources[key] = Source(url: url, headers: headers)
        lock.unlock()
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "stream"
        c.queryItems = [URLQueryItem(name: "u", value: key)]
        let asset = AVURLAsset(url: c.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /** Whether the start of `url` is on the phone. */
    func hasHead(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return heads[url.absoluteString] != nil
    }

    // -- fetching heads ahead ---------------------------------------------

    /** Fetch the start of `url` in the background, three at a time. */
    func prefetch(_ url: URL, headers: [String: String]) {
        let key = url.absoluteString
        lock.lock()
        sources[key] = Source(url: url, headers: headers)
        let skip = heads[key] != nil || fetching[key] != nil || waiting.contains(key)
        if !skip { waiting.append(key) }
        lock.unlock()
        if !skip { queue.async { self.pump() } }
    }

    /** Ahead-of-time fetches waiting for a slot are dropped: a tap comes first. */
    func dropWaiting() {
        lock.lock(); waiting.removeAll(); lock.unlock()
    }

    private func pump() {
        while true {
            lock.lock()
            guard running < 3, !waiting.isEmpty else { lock.unlock(); return }
            let key = waiting.removeFirst()
            running += 1
            lock.unlock()
            fetchHead(key) { _ in
                self.lock.lock(); self.running -= 1; self.lock.unlock()
                self.pump()
            }
        }
    }

    /** The head of `key`: from memory, or one ranged request. Calls back on `queue`. */
    private func fetchHead(_ key: String, _ done: @escaping (Head?) -> Void) {
        lock.lock()
        if let h = heads[key] { lock.unlock(); queue.async { done(h) }; return }
        if fetching[key] != nil { fetching[key]!.append(done); lock.unlock(); return }
        guard let src = sources[key] else { lock.unlock(); queue.async { done(nil) }; return }
        fetching[key] = [done]
        lock.unlock()
        var req = URLRequest(url: src.url, timeoutInterval: 15)
        for (k, v) in src.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-\(Self.headBytes - 1)", forHTTPHeaderField: "Range")
        let task = URLSession.shared.dataTask(with: req) { data, response, _ in
            var head: Head?
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                self.lock.lock(); self.missing.insert(key); self.lock.unlock()
            }
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 {
                var total = Int64(data.count)
                if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = range.lastIndex(of: "/"), let n = Int64(range[range.index(after: slash)...]) {
                    total = n
                }
                head = Head(data: data, total: total)
            }
            self.lock.lock()
            if let head {
                self.heads[key] = head
                self.headOrder.removeAll { $0 == key }
                self.headOrder.append(key)
                while self.headOrder.count > Self.keep { self.heads.removeValue(forKey: self.headOrder.removeFirst()) }
            }
            let callbacks = self.fetching.removeValue(forKey: key) ?? []
            self.lock.unlock()
            self.queue.async { callbacks.forEach { $0(head) } }
        }
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    // -- serving the player ------------------------------------------------

    private struct Pending {
        let request: AVAssetResourceLoadingRequest
        let end: Int64
    }
    private var pending: [Int: Pending] = [:]   // URLSession task id -> request (queue only)

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value
        else { return false }
        lock.lock(); let had = heads[key] != nil; lock.unlock()
        let asked = Date()
        fetchHead(key) { head in
            if loadingRequest.contentInformationRequest != nil {
                slog.info("head \(had ? "on the phone" : "fetched", privacy: .public) in \(Int(Date().timeIntervalSince(asked) * 1000)) ms (\(head?.data.count ?? -1) bytes)")
            }
            guard let head else {
                // CoreMedia's code for an HTTP 404, which PhonePlayer reads as "not on the droplet".
                self.lock.lock(); let gone = self.missing.remove(key) != nil; self.lock.unlock()
                loadingRequest.finishLoading(with: NSError(domain: "dev.marobotic.maro.stream", code: gone ? -12938 : -1,
                                                           userInfo: [NSLocalizedDescriptionKey: gone ? "404 not on the server" : "The stream did not start"]))
                return
            }
            self.serve(loadingRequest, key: key, head: head)
        }
        return true
    }

    private func serve(_ loading: AVAssetResourceLoadingRequest, key: String, head: Head) {
        if loading.isCancelled { return }
        if let info = loading.contentInformationRequest {
            info.contentType = AVFileType.m4a.rawValue
            info.contentLength = head.total
            info.isByteRangeAccessSupported = true
        }
        guard let data = loading.dataRequest else { loading.finishLoading(); return }
        let start = data.currentOffset
        let end = data.requestsAllDataToEndOfResource ? head.total : min(head.total, data.requestedOffset + Int64(data.requestedLength))
        if start < Int64(head.data.count) {
            let upTo = min(end, Int64(head.data.count))
            data.respond(with: head.data.subdata(in: Int(start)..<Int(upTo)))
        }
        let from = data.currentOffset
        if from >= end { loading.finishLoading(); return }
        lock.lock()
        let src = sources[key]
        lock.unlock()
        guard let src else { loading.finishLoading(with: URLError(.cannotLoadFromNetwork)); return }
        var req = URLRequest(url: src.url, timeoutInterval: 20)
        for (k, v) in src.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(from)-\(end - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: req)
        task.priority = URLSessionTask.highPriority
        pending[task.taskIdentifier] = Pending(request: loading, end: end)
        task.resume()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, p) in pending where p.request === loadingRequest {
            pending.removeValue(forKey: id)
            session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == id }?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = pending[dataTask.taskIdentifier] else { return dataTask.cancel() }
        if p.request.isCancelled { pending.removeValue(forKey: dataTask.taskIdentifier); return dataTask.cancel() }
        p.request.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = pending.removeValue(forKey: task.taskIdentifier), !p.request.isCancelled else { return }
        if let error { p.request.finishLoading(with: error) } else { p.request.finishLoading() }
    }
}
