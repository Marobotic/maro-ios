import CommonCrypto
import CryptoKit
import Foundation
import Security

/**
 * The music-service sessions the account holds, so this phone can play from
 * Spotify, YouTube Music and SoundCloud itself instead of through the desktop.
 *
 * The desktop uploads each of its sign-ins to the droplet at /service/<name>,
 * sealed with a key derived from the account password (the droplet only ever
 * holds ciphertext). This derives the same key at sign-in, keeps it in the
 * Keychain, and pulls and opens each session. A sign-in made on this phone
 * itself always wins over the account's copy.
 *
 * Mirrors the desktop's sidecar/service_creds.py byte for byte: change one,
 * change both.
 */
final class ServiceSessions: @unchecked Sendable {
    static let shared = ServiceSessions()

    /// Slot names on the droplet. "librespot" is the Spotify player's own
    /// login (what plays audio); "spotify" is the old Web API token.
    static let soundcloud = "soundcloud"
    static let ytm = "ytm"
    static let librespot = "librespot"
    static let all = [soundcloud, ytm, librespot]

    private static let iterations: UInt32 = 210_000
    private static let info = "maro.music/service-credentials/v1"
    private static let blobVersion: [UInt8] = [0, 0, 0, 1]
    private static let keyItem = "account-key"

    private let lock = NSLock()
    private var sessions: [String: JSON] = [:]

    // -- the key ---------------------------------------------------------

    /** sha256(lowercased email) as hex, first 20: the desktop's account slug. */
    static func accountId(_ email: String) -> String {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let hex = SHA256.hash(data: Data(e.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(20))
    }

    static func deriveKey(password: String, email: String) -> Data? {
        let salt = Data(SHA256.hash(data: Data((info + "/salt/" + accountId(email)).utf8)).prefix(16))
        let pass = Data(password.utf8)
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { k in
            salt.withUnsafeBytes { s in
                pass.withUnsafeBytes { p in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         p.baseAddress?.assumingMemoryBound(to: CChar.self), pass.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         k.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /** Derive and keep the key; ~0.2 s of PBKDF2, so off the main thread. */
    func unlock(password: String, email: String) async -> Bool {
        let key = await Task.detached { Self.deriveKey(password: password, email: email) }.value
        guard let key else { return false }
        Keychain.set(key, Self.keyItem)
        return true
    }

    var hasKey: Bool { Keychain.get(Self.keyItem) != nil }

    // -- the blobs -------------------------------------------------------

    static func open(_ blob: String, key: Data) -> JSON? {
        guard let raw = Data(base64Encoded: blob), raw.count > 12 + 16,
              let nonce = try? AES.GCM.Nonce(data: raw.prefix(12)) else { return nil }
        let body = raw.dropFirst(12)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(blobVersion))
        else { return nil }
        return JSONText.parse(plain) as? JSON
    }

    /**
     * Pull every slot the account holds. A missing slot leaves what this phone
     * already has; a slot the key cannot open means the password changed, and
     * the key is dropped so Settings asks for it again.
     * Returns the services now usable.
     */
    @discardableResult
    func refresh(_ client: MaroClient) async -> [String] {
        guard let key = Keychain.get(Self.keyItem) else { return available }
        for name in Self.all {
            if Keychain.get("own." + name) != nil { continue }   // signed in here: keep it
            guard let blob = await client.serviceBlob(name) else { continue }
            if blob.isEmpty {
                Keychain.remove("account." + name)               // signed out on the desktop
                continue
            }
            guard let payload = Self.open(blob, key: key) else {
                Keychain.remove(Self.keyItem)
                break
            }
            Keychain.set(JSONText.data(payload), "account." + name)
        }
        lock.lock(); sessions = [:]; lock.unlock()
        return available
    }

    /** This phone's own sign-in to a service, which outranks the account's. */
    func setOwn(_ name: String, _ payload: JSON?) {
        if let payload { Keychain.set(JSONText.data(payload), "own." + name) }
        else { Keychain.remove("own." + name) }
        lock.lock(); sessions[name] = nil; lock.unlock()
    }

    func session(_ name: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[name] { return s }
        let data = Keychain.get("own." + name) ?? Keychain.get("account." + name)
        let s = data.flatMap { JSONText.parse($0) as? JSON }
        sessions[name] = s
        return s
    }

    /** Where a service's session came from: "phone", "account" or "". */
    func origin(_ name: String) -> String {
        if Keychain.get("own." + name) != nil { return "phone" }
        if Keychain.get("account." + name) != nil { return "account" }
        return ""
    }

    var available: [String] { Self.all.filter { session($0) != nil } }

    /** Signing out of the Jukebox account forgets every service with it. */
    func forgetAll() {
        Keychain.remove(Self.keyItem)
        for name in Self.all {
            Keychain.remove("own." + name)
            Keychain.remove("account." + name)
        }
        lock.lock(); sessions = [:]; lock.unlock()
    }
}

/** Generic-password items for this app, readable after first unlock (so
 *  playback keeps working with the phone locked in a pocket). */
enum Keychain {
    private static let service = "dev.marobotic.maro.sessions"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ data: Data, _ account: String) {
        let q = query(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
