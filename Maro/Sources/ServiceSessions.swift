import CommonCrypto
import CryptoKit
import Foundation
import Security

/**
 * The music-service sessions, which live on the Jukebox account.
 *
 * Every client - this phone, the desktop, any other - is independent: it can
 * sign in to Spotify, YouTube Music and SoundCloud itself, and whichever
 * client signs in puts that session on the account (/service/<name>, sealed
 * with a key derived from the account password, so the droplet only holds
 * ciphertext). Every client takes the account's copy. The newest sign-in wins
 * everywhere, and a service signed out of anywhere is signed out everywhere.
 * Nothing comes from another device; any client works with the rest off.
 *
 * Mirrors the desktop's sidecar/service_creds.py and service_sync.sync() byte
 * for byte: change one, change both.
 */
final class ServiceSessions: @unchecked Sendable {
    static let shared = ServiceSessions()

    /// Slot names on the account. "librespot" is the Spotify player's login.
    static let soundcloud = "soundcloud"
    static let ytm = "ytm"
    static let librespot = "librespot"
    static let all = [librespot, ytm, soundcloud]

    private static let iterations: UInt32 = 210_000
    private static let info = "maro.music/service-credentials/v1"
    private static let blobVersion: [UInt8] = [0, 0, 0, 1]
    private static let keyItem = "account-key"

    private let lock = NSLock()
    private var cache: [String: JSON] = [:]

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

    // -- sealing ---------------------------------------------------------

    static func open(_ blob: String, key: Data) -> JSON? {
        guard let raw = Data(base64Encoded: blob), raw.count > 12 + 16,
              let nonce = try? AES.GCM.Nonce(data: raw.prefix(12)) else { return nil }
        let body = raw.dropFirst(12)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(blobVersion))
        else { return nil }
        return JSONText.parse(plain) as? JSON
    }

    static func seal(_ payload: JSON, key: Data) -> String? {
        let plain = JSONText.data(payload)
        guard let box = try? AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(),
                                          authenticating: Data(blobVersion)),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()       // nonce + ciphertext + tag
    }

    // -- in step with the account ----------------------------------------

    /**
     * Take every session the account holds that is newer than this phone's
     * copy, and drop the ones signed out of elsewhere. Returns the services
     * this phone can use. A slot the key cannot open means the password
     * changed: the key is dropped so Settings asks for it again.
     */
    @discardableResult
    func refresh(_ client: MaroClient) async -> [String] {
        guard let key = Keychain.get(Self.keyItem) else { return available }
        for name in Self.all {
            guard let got = await client.serviceBlob(name) else { continue }      // unreachable: keep ours
            let mine = Keychain.get("at." + name).map { String(decoding: $0, as: UTF8.self) }
            if got.blob.isEmpty {
                // Gone from the account: signed out of somewhere.
                if mine != nil { forgetLocal(name) }
                continue
            }
            if got.at == mine && Keychain.get("svc." + name) != nil { continue }
            guard let payload = Self.open(got.blob, key: key) else {
                Keychain.remove(Self.keyItem)
                break
            }
            store(name, payload, at: got.at)
        }
        return available
    }

    /**
     * A sign-in made on this phone: onto the account first (it is where the
     * session lives), then kept here. Returns nil, or why it failed.
     */
    func publish(_ name: String, _ payload: JSON, client: MaroClient) async -> String? {
        guard let key = Keychain.get(Self.keyItem) else { return "Enter your Jukebox password in Settings first" }
        guard let blob = Self.seal(payload, key: key) else { return "Could not seal the session" }
        guard let at = await client.putServiceBlob(name, blob) else { return "Could not save the session to your account" }
        store(name, payload, at: at)
        return nil
    }

    /** Signed out of here is signed out everywhere: off the account, then here. */
    func signOut(_ name: String, client: MaroClient) async {
        _ = await client.deleteServiceBlob(name)
        forgetLocal(name)
    }

    private func store(_ name: String, _ payload: JSON, at: String) {
        Keychain.set(JSONText.data(payload), "svc." + name)
        Keychain.set(Data(at.utf8), "at." + name)
        lock.lock(); cache[name] = payload; lock.unlock()
    }

    private func forgetLocal(_ name: String) {
        Keychain.remove("svc." + name)
        Keychain.remove("at." + name)
        lock.lock(); cache[name] = nil; lock.unlock()
    }

    func session(_ name: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        if let s = cache[name] { return s }
        let s = Keychain.get("svc." + name).flatMap { JSONText.parse($0) as? JSON }
        cache[name] = s
        return s
    }

    var available: [String] { Self.all.filter { session($0) != nil } }

    /**
     * Signing out of Jukebox on this phone: its key and its copies go. The
     * account's sessions stay - every other client is still signed in.
     */
    func forgetAll() {
        Keychain.remove(Self.keyItem)
        for name in Self.all { forgetLocal(name) }
        // The first build kept these under other names.
        for name in Self.all {
            Keychain.remove("own." + name)
            Keychain.remove("account." + name)
        }
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
