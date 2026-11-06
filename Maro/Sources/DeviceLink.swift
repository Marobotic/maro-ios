import CryptoKit
import Foundation
import Network

/**
 * Sign in once, every device works (round 2 I and I.5).
 *
 * Every device of a Jukebox account has its own key pair and is registered on
 * the account (`PUT /cache/devices/self`). Devices talk with typed messages:
 * on the local network first (a signed HTTP POST, 300 ms), else through the
 * server's relay (`POST /cache/relay/to/<id>`). Anything that carries a
 * credential is sealed to the recipient's public key, so the server only ever
 * relays ciphertext.
 *
 * - Spotify and SoundCloud: the session itself is shared (`session.request` /
 *   `session.offer`); the account's sealed /service copy stays the fallback.
 * - YouTube Music is never copied: one device (the "holder", prefs.ytmHolder)
 *   keeps the Google session (YtmDevice) and the others borrow it
 *   (`ytm.request` / `ytm.result`); writes wait in /cache/ytm/pending while it
 *   is away. The role moves to the device in use (`ytm.handover`: sealed to
 *   the target, the old holder deletes its cookies first, the target imports,
 *   refreshes, takes prefs.ytmHolder and acks).
 *
 * Wire formats (for every app):
 * - Sealed: base64( epk[32] | nonce[12] | ciphertext | tag[16] ), AES-256-GCM
 *   with key = HKDF-SHA256(ikm: X25519(ephemeral, recipient), salt: epk |
 *   recipient public key, info: "jukebox sealed v1", 32 bytes).
 * - Local route: POST http://<lan.addr>:<lan.port>/jukebox/v1/msg with JSON
 *   {from, ts, msg, mac}: msg = the JSON text of {type, payload}, ts = epoch
 *   seconds, mac = base64 HMAC-SHA256(key, "<ts>\n<from>\n<msg>") with key =
 *   HKDF-SHA256(ikm: X25519(sender, receiver), salt: empty, info: "jukebox lan
 *   v1", 32 bytes). Accepted within 120 s of `ts`, only from registered devices.
 */
enum DeviceKeys {
    private static let item = "device.x25519"

    static let privateKey: Curve25519.KeyAgreement.PrivateKey = {
        if let raw = Keychain.get(item), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.KeyAgreement.PrivateKey()
        Keychain.set(key.rawRepresentation, item)
        return key
    }()

    static var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    private static func peerKey(_ b64: String) -> Curve25519.KeyAgreement.PublicKey? {
        let clean = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = clean + String(repeating: "=", count: (4 - clean.count % 4) % 4)
        guard let raw = Data(base64Encoded: padded) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    /** Seal bytes to a device's public key; nil when the key is unusable. */
    static func seal(_ plain: Data, to recipient: String) -> String? {
        guard let rpk = peerKey(recipient) else { return nil }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: rpk) else { return nil }
        let epk = eph.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: epk + rpk.rawRepresentation,
                                                 sharedInfo: Data("jukebox sealed v1".utf8), outputByteCount: 32)
        guard let box = try? AES.GCM.seal(plain, using: key), let combined = box.combined else { return nil }
        return (epk + combined).base64EncodedString()
    }

    /** Open something sealed to this device; nil when it isn't ours or was altered. */
    static func open(_ sealed: String) -> Data? {
        guard let raw = Data(base64Encoded: sealed), raw.count > 32 + 12 + 16,
              let epk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw.prefix(32)),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: epk) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: raw.prefix(32) + privateKey.publicKey.rawRepresentation,
                                                 sharedInfo: Data("jukebox sealed v1".utf8), outputByteCount: 32)
        guard let box = try? AES.GCM.SealedBox(combined: raw.dropFirst(32)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /** The local route's MAC key with one other device. */
    static func lanKey(_ peer: String) -> SymmetricKey? {
        guard let pk = peerKey(peer), let shared = try? privateKey.sharedSecretFromKeyAgreement(with: pk) else { return nil }
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("jukebox lan v1".utf8), outputByteCount: 32)
    }

    static func mac(_ key: SymmetricKey, ts: Int, from: String, msg: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("\(ts)\n\(from)\n\(msg)".utf8), using: key)).base64EncodedString()
    }
}

/** Another device of the account, as the registry lists it. */
struct PeerDevice: Equatable {
    var id = ""
    var name = ""
    var kind = ""
    var publicKey = ""
    var spotify = false
    var soundcloud = false
    var ytmHolder = false
    var lanAddr = ""
    var lanPort = 0
    var online = false
    var lastSeen: Date?

    static func from(_ o: JSON) -> PeerDevice {
        let s = o.obj("services") ?? [:]
        let lan = o.obj("lan")
        return PeerDevice(id: o.str("deviceId"), name: o.str("name"), kind: o.str("kind"), publicKey: o.str("publicKey"),
                          spotify: s.bool("spotify"), soundcloud: s.bool("soundcloud"), ytmHolder: s.str("ytm") == "holder",
                          lanAddr: lan?.str("addr") ?? "", lanPort: lan?.int("port") ?? 0, online: o.bool("online"),
                          lastSeen: ISO8601DateFormatter.flexible(o.str("lastSeen")))
    }
}

/** What the view model gives the link. */
@MainActor
protocol DeviceLinkHost: AnyObject {
    /** Sessions or the YouTube Music holder changed: recount the services. */
    func linkChanged()
    func linkStatus(_ message: String, _ kind: String)
    /** The shared player's device (the one in use), "" when none. */
    var linkPlayingDevice: String { get }
    /** Whether this phone is playing right now. */
    var linkPlayingHere: Bool { get }
    /** Set prefs.ytmHolder on the account (nil clears it). */
    func linkSetHolder(_ deviceId: String?) async
}

@MainActor
final class DeviceLink {
    static let shared = DeviceLink()

    var client: MaroClient?
    weak var host: DeviceLinkHost?
    /** This phone's relay id and the name it shows. */
    var deviceId = ""
    var deviceName = ""

    private(set) var peers: [PeerDevice] = []
    /** prefs.ytmHolder as last read: the one device holding YouTube Music. */
    private(set) var holder = ""
    /** Where each service comes from: "spotify", "soundcloud" -> "here" | "peer:<name>" | "account". */
    private(set) var sources: [String: String] = [:]

    private var waiting: [String: CheckedContinuation<JSON?, Never>] = [:]
    private var lan: LanServer?

    var amHolder: Bool { !holder.isEmpty && holder == deviceId && YtmDevice.shared.signedIn }
    var holderPeer: PeerDevice? { peers.first { $0.id == holder } }

    // -- the registry ---------------------------------------------------------

    /** This device on the account: its key, what it holds, its local route. */
    func register() async {
        guard let client, !deviceId.isEmpty else { return }
        var body: JSON = [
            "deviceId": deviceId, "name": deviceName, "kind": "phone",
            "appVersion": SettingsPage.version, "publicKey": DeviceKeys.publicKey,
            "services": [
                "spotify": ServiceSessions.shared.session(ServiceSessions.librespot) != nil,
                "soundcloud": ServiceSessions.shared.session(ServiceSessions.soundcloud) != nil,
                "ytm": amHolder ? "holder" : "none",
            ] as JSON,
        ]
        if let lan, let addr = LanServer.wifiAddress(), lan.port > 0 { body["lan"] = ["addr": addr, "port": lan.port] as JSON }
        _ = await client.registerDevice(body)
    }

    func refreshPeers() async {
        guard let list = await client?.devices() else { return }
        peers = list.map(PeerDevice.from).filter { $0.id != deviceId }
    }

    /** prefs.ytmHolder changed (or was read): only one device may hold Google cookies. */
    func holderIs(_ id: String) async {
        let changed = id != holder
        holder = id
        if !id.isEmpty && id != deviceId && YtmDevice.shared.signedIn {
            // Someone else holds YouTube Music now: this phone lets go of its cookies.
            ConsoleLog.shared.log("DeviceLink", "YouTube Music is held by another device; signing out here")
            await YtmDevice.shared.signOut()
        } else if id.isEmpty && YtmDevice.shared.signedIn {
            // Nobody holds it and this phone has a session: this phone is the holder.
            await host?.linkSetHolder(deviceId)
        }
        if changed { host?.linkChanged() }
    }

    // -- the local route --------------------------------------------------------

    /** Serve the local route while the app is open. */
    func startLan() {
        guard lan == nil else { return }
        let server = LanServer { [weak self] from, ts, msg, mac in
            self?.acceptLan(from: from, ts: ts, msg: msg, mac: mac) ?? false
        }
        lan = server
        server.onReady = { [weak self] in Task { await self?.register() } }
        server.start()
    }

    func stopLan() {
        lan?.stop()
        lan = nil
        Task { await register() }
    }

    private func acceptLan(from: String, ts: Int, msg: String, mac: String) -> Bool {
        guard abs(Int(Date().timeIntervalSince1970) - ts) < 120,
              let peer = peers.first(where: { $0.id == from }), let key = DeviceKeys.lanKey(peer.publicKey),
              DeviceKeys.mac(key, ts: ts, from: from, msg: msg) == mac,
              let m = JSONText.object(msg) else { return false }
        var full = m
        full["from"] = from
        handle(full)
        return true
    }

    // -- sending -------------------------------------------------------------------

    /** A message to one device: the local network first, the relay else. */
    @discardableResult
    func send(_ type: String, _ payload: JSON, to peer: PeerDevice) async -> Bool {
        if !peer.lanAddr.isEmpty && peer.lanPort > 0, let key = DeviceKeys.lanKey(peer.publicKey),
           let url = URL(string: "http://\(peer.lanAddr):\(peer.lanPort)/jukebox/v1/msg") {
            let msg = JSONText.string(["type": type, "payload": payload] as JSON)
            let ts = Int(Date().timeIntervalSince1970)
            var req = URLRequest(url: url, timeoutInterval: 0.3)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSONText.data(["from": deviceId, "ts": ts, "msg": msg, "mac": DeviceKeys.mac(key, ts: ts, from: deviceId, msg: msg)] as JSON)
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
        }
        return await client?.relayTo(peer.id, type: type, payload: payload, from: deviceId) ?? false
    }

    /** Send and wait for the answer that names the same reqId (up to `wait` seconds). */
    private func ask(_ type: String, _ payload: JSON, to peer: PeerDevice, wait: Double) async -> JSON? {
        let reqId = UUID().uuidString.lowercased()
        var body = payload
        body["reqId"] = reqId
        guard await send(type, body, to: peer) else { return nil }
        return await withCheckedContinuation { (k: CheckedContinuation<JSON?, Never>) in
            waiting[reqId] = k
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self?.waiting.removeValue(forKey: reqId)?.resume(returning: nil)
            }
        }
    }

    // -- Spotify and SoundCloud: the session shared --------------------------------

    private static func slot(_ service: String) -> String? {
        service == "spotify" ? ServiceSessions.librespot : service == "soundcloud" ? ServiceSessions.soundcloud : nil
    }

    /** Ask the devices that hold a service this phone lacks; the first offer wins. True when one arrived. */
    @discardableResult
    func askForSessions() async -> Bool {
        var got = false
        for service in ["spotify", "soundcloud"] {
            guard let slot = Self.slot(service), ServiceSessions.shared.session(slot) == nil else { continue }
            let holders = peers.filter { $0.online && !$0.publicKey.isEmpty && (service == "spotify" ? $0.spotify : $0.soundcloud) }
            for peer in holders {
                if let offer = await ask("session.request", ["service": service], to: peer, wait: 4), acceptOffer(offer, from: peer) {
                    got = true
                    break
                }
            }
        }
        if got { host?.linkChanged() }
        updateSources()
        return got
    }

    private func acceptOffer(_ p: JSON, from peer: PeerDevice) -> Bool {
        guard let slot = Self.slot(p.str("service")), let plain = DeviceKeys.open(p.str("sealed")),
              let payload = JSONText.parse(plain) as? JSON else { return false }
        ServiceSessions.shared.adopt(slot, payload, from: peer.name)
        ConsoleLog.shared.log("DeviceLink", "\(p.str("service")) session received from \(peer.name)")
        return true
    }

    /** Where each service on this phone comes from, for onboarding and Settings. */
    func updateSources() {
        for service in ["spotify", "soundcloud"] {
            guard let slot = Self.slot(service) else { continue }
            sources[service] = ServiceSessions.shared.source(slot)
        }
    }

    // -- incoming messages -----------------------------------------------------------

    /** Every direct message, from the relay or the local route ({type, payload, from}). */
    func handle(_ msg: JSON) {
        let type = msg.str("type").ifEmpty(msg.str("action"))
        let p = msg.obj("payload") ?? [:]
        let from = msg.str("from")
        // An answer someone is waiting for.
        let reqId = p.str("reqId")
        if (type == "session.offer" || type == "ytm.result"), !reqId.isEmpty, let k = waiting.removeValue(forKey: reqId) {
            k.resume(returning: p)
            return
        }
        Task {
            if peers.first(where: { $0.id == from }) == nil { await refreshPeers() }
            let peer = peers.first { $0.id == from }
            switch type {
            case "session.request":
                if let peer { await answerSessionRequest(p, to: peer) }
            case "session.offer":
                if let peer, acceptOffer(p, from: peer) { updateSources(); host?.linkChanged() }
            case "ytm.request":
                if let peer { await answerYtmRequest(p, to: peer) }
            case "ytm.pending":
                if amHolder { await applyPending() }
            case "ytm.handover":
                if let peer { await takeHandover(p, from: peer) }
            case "ytm.handover.ack":
                ConsoleLog.shared.log("DeviceLink", "YouTube Music moved to \(peer?.name ?? from)")
            case "devices.changed", "ytm.holder":
                await refreshPeers()
                host?.linkChanged()
            default:
                break
            }
        }
    }

    private func answerSessionRequest(_ p: JSON, to peer: PeerDevice) async {
        let service = p.str("service")
        guard let slot = Self.slot(service), let session = ServiceSessions.shared.session(slot),
              let sealed = DeviceKeys.seal(JSONText.data(session), to: peer.publicKey) else { return }
        await send("session.offer", ["service": service, "sealed": sealed, "reqId": p.str("reqId")], to: peer)
        ConsoleLog.shared.log("DeviceLink", "\(service) session offered to \(peer.name)")
    }

    // -- YouTube Music: borrowed from the holder --------------------------------------

    /**
     * A YouTube Music call that needs the account, done by the holder with its
     * own session (this phone isn't the holder). nil when it can't be reached
     * or said no: the caller goes on anonymously.
     */
    func borrow(_ endpoint: String, _ body: JSON) async -> JSON? {
        guard !amHolder, let peer = holderPeer, peer.online, !peer.publicKey.isEmpty else { return nil }
        guard let answer = await ask("ytm.request", ["op": "call", "args": ["endpoint": endpoint, "body": body] as JSON], to: peer, wait: 8),
              answer.bool("ok") else { return nil }
        return answer.obj("data")
    }

    /**
     * A YouTube Music change (like, playlist edit): the holder does it now, or
     * it waits on the account until the holder is back.
     */
    func ytmWrite(_ op: String, _ args: JSON) async -> Bool {
        if amHolder { return (try? await Self.perform(op, args)) != nil }
        if let peer = holderPeer, peer.online,
           let answer = await ask("ytm.request", ["op": op, "args": args], to: peer, wait: 8), answer.bool("ok") { return true }
        return await client?.addPending(op, args, from: deviceId) ?? false
    }

    private func answerYtmRequest(_ p: JSON, to peer: PeerDevice) async {
        let reqId = p.str("reqId")
        guard amHolder else {
            await send("ytm.result", ["reqId": reqId, "ok": false, "error": "not the holder"], to: peer)
            return
        }
        do {
            let data = try await Self.perform(p.str("op"), p.obj("args") ?? [:])
            // The relay carries up to 256 KB; a bigger answer is declined, so the asker goes anonymous.
            if JSONText.data(data).count > 200_000 {
                await send("ytm.result", ["reqId": reqId, "ok": false, "error": "too large"], to: peer)
            } else {
                await send("ytm.result", ["reqId": reqId, "ok": true, "data": data], to: peer)
            }
        } catch {
            await send("ytm.result", ["reqId": reqId, "ok": false, "error": "\(error)"], to: peer)
        }
    }

    struct Unsupported: Error {}

    /** One account operation, done here with this phone's own session (the holder's side). */
    static func perform(_ op: String, _ a: JSON) async throws -> JSON {
        let yt = YouTubeMusic.shared
        let list = a.str("playlistId").replacingOccurrences(of: "^VL", with: "", options: .regularExpression)
        switch op {
        case "call":
            return try await yt.call(a.str("endpoint"), a.obj("body") ?? [:], signed: true)
        case "like":
            return try await yt.call("like/like", ["target": ["videoId": a.str("videoId")]], signed: true)
        case "unlike":
            return try await yt.call("like/removelike", ["target": ["videoId": a.str("videoId")]], signed: true)
        case "playlist.add":
            return try await yt.call("browse/edit_playlist", ["playlistId": list, "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": a.str("videoId")]]], signed: true)
        case "playlist.remove":
            return try await yt.call("browse/edit_playlist", ["playlistId": list, "actions": [["action": "ACTION_REMOVE_VIDEO", "removedVideoId": a.str("videoId"), "setVideoId": a.str("setVideoId")]]], signed: true)
        case "playlist.create":
            return try await yt.call("playlist/create", ["title": a.str("name"), "privacyStatus": "PRIVATE", "videoIds": a.arr("videoIds") ?? []], signed: true)
        case "playlist.rename":
            return try await yt.call("browse/edit_playlist", ["playlistId": list, "actions": [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": a.str("name")]]], signed: true)
        case "playlist.delete":
            return try await yt.call("playlist/delete", ["playlistId": list], signed: true)
        default:
            throw Unsupported()
        }
    }

    /** The holder applies the changes that waited for it, and clears each one done. */
    func applyPending() async {
        guard amHolder, let client, let items = await client.pending() else { return }
        for item in items {
            let op = item.str("op")
            do {
                _ = try await Self.perform(op, item.obj("args") ?? [:])
                _ = await client.deletePending(item.str("id"))
            } catch is Unsupported {
                _ = await client.deletePending(item.str("id"))      // nothing this phone can do with it
            } catch {
                ConsoleLog.shared.log("DeviceLink", "a waiting YouTube Music change (\(op)) failed; kept for later")
            }
        }
    }

    // -- the holder moves with you (I.5) -------------------------------------------------

    /** Where the role goes: the device playing on the shared player, else the most recently active one. */
    private func handoverTarget() -> PeerDevice? {
        let usable = peers.filter { !$0.publicKey.isEmpty && $0.online }
        if let playing = host?.linkPlayingDevice, let p = usable.first(where: { $0.id == playing }) { return p }
        return usable.max { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
    }

    /**
     * Give the YouTube Music role away: the cookies sealed to the target, this
     * phone's copy deleted BEFORE the target can use them, then sent. If it
     * can't be sent, the cookies come back here (never two live copies).
     */
    func handOver(reason: String) async {
        guard amHolder else { return }
        await refreshPeers()
        guard let target = handoverTarget() else { return }
        let rows = await YtmDevice.shared.exportCookies()
        guard !rows.isEmpty, let sealed = DeviceKeys.seal(JSONText.data(rows), to: target.publicKey) else { return }
        await YtmDevice.shared.signOut()
        if await send("ytm.handover", ["sealed": sealed, "reason": reason], to: target) {
            ConsoleLog.shared.log("DeviceLink", "YouTube Music handed to \(target.name) (\(reason))")
            host?.linkChanged()
        } else {
            await YtmDevice.shared.importCookies(rows)
            ConsoleLog.shared.log("DeviceLink", "YouTube Music hand-over to \(target.name) failed; kept here")
        }
    }

    /** The role arrives here: import, refresh once, take prefs.ytmHolder, ack. */
    private func takeHandover(_ p: JSON, from peer: PeerDevice) async {
        guard let plain = DeviceKeys.open(p.str("sealed")), let rows = JSONText.parse(plain) as? [JSON] else { return }
        await YtmDevice.shared.importCookies(rows)
        await YtmDevice.shared.signedInNow()
        holder = deviceId
        await host?.linkSetHolder(deviceId)
        await send("ytm.handover.ack", ["ok": YtmDevice.shared.signedIn], to: peer)
        host?.linkChanged()
        if YtmDevice.shared.signedIn {
            ConsoleLog.shared.log("DeviceLink", "YouTube Music moved here from \(peer.name)")
            await applyPending()
        } else {
            host?.linkStatus("Google didn't keep the moved sign-in - Sign in to YouTube Music (usually no password)", "error")
        }
    }
}

/**
 * The local route's listener: a tiny HTTP server on the Wi-Fi interface while
 * the app is open, taking one signed POST per connection.
 */
final class LanServer: @unchecked Sendable {
    typealias Accept = @MainActor (_ from: String, _ ts: Int, _ msg: String, _ mac: String) -> Bool

    private var listener: NWListener?
    private let accept: Accept
    private let queue = DispatchQueue(label: "dev.marobotic.maro.lan")
    private(set) var port = 0
    var onReady: (@MainActor () -> Void)?

    init(accept: @escaping Accept) { self.accept = accept }

    func start() {
        guard let l = try? NWListener(using: .tcp) else { return }
        listener = l
        l.stateUpdateHandler = { [weak self] st in
            guard let self, case .ready = st else { return }
            self.port = Int(l.port?.rawValue ?? 0)
            let ready = self.onReady
            Task { @MainActor in ready?() }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ have: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = have
            if let data { buf.append(data) }
            if buf.count > 300_000 || error != nil { return c.cancel() }
            if let req = Self.request(buf) {
                self.answer(c, req)
            } else if done {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    /** The body of a whole POST request in `buf`, or nil while more is coming. */
    private static func request(_ buf: Data) -> Data? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).lowercased()
        var length = 0
        for line in head.split(separator: "\r\n") where line.hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = buf[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    private func answer(_ c: NWConnection, _ body: Data) {
        let o = JSONText.parse(body) as? JSON ?? [:]
        let accept = self.accept
        Task { @MainActor in
            let ok = accept(o.str("from"), o.int("ts"), o.str("msg"), o.str("mac"))
            let text = ok ? "{\"ok\":true}" : "{\"ok\":false}"
            let reply = "HTTP/1.1 \(ok ? "200 OK" : "403 Forbidden")\r\nContent-Type: application/json\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
            c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }

    /** This phone's Wi-Fi IPv4 address, or nil off Wi-Fi. */
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
