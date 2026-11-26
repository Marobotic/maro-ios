import CryptoKit
import Foundation
import Network

/**
 * Sign in once, every device works (round 2 I, I.5, I.6).
 *
 * Every device of a Jukebox account has two key pairs (X25519 to encrypt,
 * Ed25519 to sign; private keys in the Keychain) and is registered on the
 * account (`PUT /cache/devices/self`). Devices talk with typed messages in the
 * I.6 envelope (DeviceCrypto): on the local network first (the envelope POSTed
 * to the device's LAN port, 300 ms; this phone serves one while open), else
 * through the server's relay (`POST /cache/relay/to/<id>`). Anything carrying
 * a credential is HPKE-sealed to the recipient; everything is signed, and
 * checked against the sender's registered key.
 *
 * - Spotify and SoundCloud: the session itself is shared (`session.request` /
 *   `session.offer`); the account's sealed /service copy stays the fallback.
 * YouTube Music is independent on each device and never uses this link.
 */
enum DeviceKeys {
    private static let encItem = "device.x25519"
    private static let signItem = "device.ed25519"

    static let encryption: Curve25519.KeyAgreement.PrivateKey = {
        if let raw = Keychain.get(encItem), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.KeyAgreement.PrivateKey()
        Keychain.set(key.rawRepresentation, encItem)
        return key
    }()

    static let signing: Curve25519.Signing.PrivateKey = {
        if let raw = Keychain.get(signItem), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        Keychain.set(key.rawRepresentation, signItem)
        return key
    }()

    static var publicKey: String { DeviceCrypto.b64url(encryption.publicKey.rawRepresentation) }
    static var signKey: String { DeviceCrypto.b64url(signing.publicKey.rawRepresentation) }
}

/** Another device of the account, as the registry lists it. */
struct PeerDevice: Equatable {
    var id = ""
    var name = ""
    var kind = ""
    var publicKey = ""
    var signKey = ""
    var spotify = false
    var soundcloud = false
    var lanAddr = ""
    var lanPort = 0
    var online = false
    var lastSeen: Date?

    static func from(_ o: JSON) -> PeerDevice {
        let s = o.obj("services") ?? [:]
        let lan = o.obj("lan")
        return PeerDevice(id: o.str("deviceId"), name: o.str("name"), kind: o.str("kind"), publicKey: o.str("publicKey"),
                          signKey: o.str("signKey"), spotify: s.bool("spotify"), soundcloud: s.bool("soundcloud"),
                          lanAddr: lan?.str("addr") ?? "", lanPort: lan?.int("port") ?? 0,
                          online: o.bool("online"), lastSeen: ISO8601DateFormatter.flexible(o.str("lastSeen")))
    }

    var encKey: Curve25519.KeyAgreement.PublicKey? {
        DeviceCrypto.unb64(publicKey).flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
    }

    var verifyKey: Curve25519.Signing.PublicKey? {
        DeviceCrypto.unb64(signKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /** Can be written to: both keys registered. */
    var reachable: Bool { encKey != nil && verifyKey != nil }
}

/** What the view model gives the link. */
@MainActor
protocol DeviceLinkHost: AnyObject {
    /** Shared sessions changed: recount the services. */
    func linkChanged()
}

@MainActor
final class DeviceLink {
    static let shared = DeviceLink()

    var client: MaroClient?
    weak var host: DeviceLinkHost?
    /** This phone's relay id and the name it shows. */
    var deviceId = ""
    var deviceName = ""
    /** A person is using this phone now (I.5: `active` in the registry). */
    var active = true

    private(set) var peers: [PeerDevice] = []
    /** Where each service comes from: "spotify", "soundcloud" -> "here" | "peer:<name>" | "account" | "". */
    private(set) var sources: [String: String] = [:]

    private var waiting: [String: CheckedContinuation<JSON?, Never>] = [:]
    private var seenIds: [String] = []
    private var lan: LanServer?

    // -- the registry ---------------------------------------------------------

    /** This device on the account: its keys, what it holds, its local route. */
    func register() async {
        guard let client, !deviceId.isEmpty else { return }
        var body: JSON = [
            "deviceId": deviceId, "name": deviceName, "kind": "phone",
            // What others see this phone as in a jam ("iPhone").
            "platform": "ios",
            "appVersion": SettingsPage.version, "publicKey": DeviceKeys.publicKey, "signKey": DeviceKeys.signKey,
            "services": [
                "spotify": ServiceSessions.shared.session(ServiceSessions.librespot) != nil,
                "soundcloud": ServiceSessions.shared.session(ServiceSessions.soundcloud) != nil,
            ] as JSON,
            "active": active,
        ]
        if let lan, let addr = LanServer.wifiAddress(), lan.port > 0 {
            body["lan"] = ["addr": addr, "port": lan.port] as JSON
        } else {
            body["lan"] = NSNull()
        }
        _ = await client.registerDevice(body)
    }

    func refreshPeers() async {
        guard let doc = await client?.devicesDoc() else { return }
        peers = ((doc.arr("devices") ?? []).compactMap { $0 as? JSON }).map(PeerDevice.from).filter { $0.id != deviceId }
    }

    // -- the local route --------------------------------------------------------

    /** Serve the local route while the app is open. */
    func startLan() {
        guard lan == nil else { return }
        let server = LanServer { [weak self] env in self?.acceptLan(env) ?? false }
        lan = server
        server.onReady = { [weak self] in Task { await self?.register() } }
        server.start()
    }

    func stopLan() {
        lan?.stop()
        lan = nil
        Task { await register() }
    }

    /** An envelope from the local route: only for this phone, signed by a registered device. */
    private func acceptLan(_ env: JSON) -> Bool {
        let from = env.str("from")
        guard env.str("to") == deviceId, peers.contains(where: { $0.id == from }) else { return false }
        handle(["type": env.str("type"), "from": from, "payload": env])
        return true
    }

    // -- sending -------------------------------------------------------------------

    /**
     * A message to one device in the I.6 envelope: sealed when it carries a
     * credential, signed always. The local network first, the relay else.
     */
    @discardableResult
    func send(_ type: String, _ body: JSON, to peer: PeerDevice, sealed: Bool = false) async -> Bool {
        let msgId = UUID().uuidString.lowercased()
        let env: [String: Any]
        do {
            if sealed {
                guard let key = peer.encKey else { return false }
                env = try DeviceCrypto.seal(JSONText.data(body), type: type, msgId: msgId, from: deviceId, to: peer.id,
                                            recipient: key, signer: DeviceKeys.signing)
            } else {
                env = try DeviceCrypto.signed(JSONText.string(body), type: type, msgId: msgId, from: deviceId, to: peer.id,
                                              signer: DeviceKeys.signing)
            }
        } catch {
            ConsoleLog.shared.log("DeviceLink", "couldn't seal \(type) for \(peer.name)")
            return false
        }
        if !peer.lanAddr.isEmpty && peer.lanPort > 0, let url = URL(string: "http://\(peer.lanAddr):\(peer.lanPort)/jukebox/v1/msg") {
            var req = URLRequest(url: url, timeoutInterval: 0.3)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSONText.data(env)
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
        }
        return await client?.relayTo(peer.id, envelope: env) ?? false
    }

    /** Send and wait for the answer that names the same reqId (up to `wait` seconds). */
    private func ask(_ type: String, _ body: JSON, to peer: PeerDevice, wait: Double) async -> JSON? {
        let reqId = UUID().uuidString.lowercased()
        var b = body
        b["reqId"] = reqId
        guard await send(type, b, to: peer) else { return nil }
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
            let holders = peers.filter { $0.online && $0.reachable && (service == "spotify" ? $0.spotify : $0.soundcloud) }
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

    /** A session.offer's plaintext {service, payload}: kept here as that device's. */
    private func acceptOffer(_ p: JSON, from peer: PeerDevice) -> Bool {
        guard let slot = Self.slot(p.str("service")), let payload = p.obj("payload") else { return false }
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

    /**
     * Every direct message, from the relay ({type, payload: envelope, from,
     * sentAt}) or the local route. Envelopes are verified against the
     * sender's registered signing key and opened; only the server's own
     * device registry notices come plain.
     */
    func handle(_ msg: JSON) {
        let type = msg.str("type").ifEmpty(msg.str("action"))
        let from = msg.str("from")
        let sentAt = ISO8601DateFormatter.flexible(msg.str("sentAt"))
        Task {
            if type == "devices.changed" {
                await refreshPeers()
                host?.linkChanged()
                return
            }
            guard let env = msg.obj("payload"), env["v"] != nil else { return }
            // Older than 5 minutes, or seen before: dropped.
            if let sentAt, Date().timeIntervalSince(sentAt) > 300 { return }
            let msgId = env.str("msgId")
            guard !msgId.isEmpty, !seenIds.contains(msgId) else { return }
            seenIds.append(msgId)
            if seenIds.count > 500 { seenIds.removeFirst(100) }
            if peers.first(where: { $0.id == from }) == nil { await refreshPeers() }
            guard let peer = peers.first(where: { $0.id == from }), let verify = peer.verifyKey,
                  let plain = try? DeviceCrypto.open(env, me: deviceId, recipient: DeviceKeys.encryption, senderSignKey: verify),
                  let body = JSONText.parse(plain) as? JSON else {
                ConsoleLog.shared.log("DeviceLink", "dropped a \(type) from \(from): not verified")
                return
            }
            // An answer someone is waiting for.
            let reqId = body.str("reqId")
            if type == "session.offer", !reqId.isEmpty, let k = waiting.removeValue(forKey: reqId) {
                k.resume(returning: body)
                return
            }
            switch type {
            case "session.request": await answerSessionRequest(body, to: peer)
            case "session.offer": if acceptOffer(body, from: peer) { updateSources(); host?.linkChanged() }
            default: break
            }
        }
    }

    private func answerSessionRequest(_ p: JSON, to peer: PeerDevice) async {
        let service = p.str("service")
        guard let slot = Self.slot(service), let session = ServiceSessions.shared.session(slot) else { return }
        await send("session.offer", ["service": service, "payload": session, "reqId": p.str("reqId")], to: peer, sealed: true)
        ConsoleLog.shared.log("DeviceLink", "\(service) session offered to \(peer.name)")
    }

}

/**
 * The local route's listener: a tiny HTTP server on the Wi-Fi interface while
 * the app is open, taking one envelope (POST /jukebox/v1/msg) per connection.
 */
final class LanServer: @unchecked Sendable {
    typealias Accept = @MainActor (_ envelope: JSON) -> Bool

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
            let ok = accept(o)
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
