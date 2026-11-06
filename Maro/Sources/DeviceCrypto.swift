import CryptoKit
import Foundation

/**
 * Device-to-device messages (round 2 I.6), exactly as every Jukebox app does
 * them:
 *
 * - Encryption: HPKE (RFC 9180) base mode, DHKEM(X25519, HKDF-SHA256) /
 *   HKDF-SHA256 / AES-256-GCM; info = "jukebox-v1:" + type; aad =
 *   "<from>|<to>|<msgId>".
 * - Envelope: {"v":1, type, msgId, from, to, enc, ct, sig} with base64url
 *   fields; sig = Ed25519 over enc || ct || aad. Signed plain form (no
 *   credentials): {"v":1, type, msgId, from, to, body: "<json text>", sig}
 *   with sig over body bytes || aad.
 *
 * Only Foundation and CryptoKit: the unit test builds this file alone and
 * opens the shared interop vector (design/round2-hpke-vector.json).
 */
enum DeviceCrypto {
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_AES_GCM_256

    struct Invalid: Error { let why: String }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /** base64url or standard base64, with or without padding. */
    static func unb64(_ s: String) -> Data? {
        let clean = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: clean + String(repeating: "=", count: (4 - clean.count % 4) % 4))
    }

    static func aad(from: String, to: String, msgId: String) -> Data { Data("\(from)|\(to)|\(msgId)".utf8) }

    static func info(_ type: String) -> Data { Data("jukebox-v1:\(type)".utf8) }

    /** A sealed envelope for `to`, signed by the sender. */
    static func seal(_ plain: Data, type: String, msgId: String, from: String, to: String,
                     recipient: Curve25519.KeyAgreement.PublicKey, signer: Curve25519.Signing.PrivateKey) throws -> [String: Any] {
        let aad = aad(from: from, to: to, msgId: msgId)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info(type))
        let ct = try sender.seal(plain, authenticating: aad)
        let enc = sender.encapsulatedKey
        let sig = try signer.signature(for: enc + ct + aad)
        return ["v": 1, "type": type, "msgId": msgId, "from": from, "to": to,
                "enc": b64url(enc), "ct": b64url(ct), "sig": b64url(sig)]
    }

    /** A signed plain envelope (no credentials inside). */
    static func signed(_ body: String, type: String, msgId: String, from: String, to: String,
                       signer: Curve25519.Signing.PrivateKey) throws -> [String: Any] {
        let sig = try signer.signature(for: Data(body.utf8) + aad(from: from, to: to, msgId: msgId))
        return ["v": 1, "type": type, "msgId": msgId, "from": from, "to": to, "body": body, "sig": b64url(sig)]
    }

    /**
     * Verify an envelope against the sender's registered signing key and give
     * back its plaintext (sealed) or body (signed plain). Throws when it isn't
     * for `me`, the signature fails, or it doesn't open.
     */
    static func open(_ env: [String: Any], me: String, recipient: Curve25519.KeyAgreement.PrivateKey,
                     senderSignKey: Curve25519.Signing.PublicKey) throws -> Data {
        func s(_ k: String) -> String { env[k] as? String ?? "" }
        guard (env["v"] as? NSNumber)?.intValue == 1 || (env["v"] as? Int) == 1 else { throw Invalid(why: "version") }
        guard s("to") == me else { throw Invalid(why: "not for this device") }
        let aad = aad(from: s("from"), to: s("to"), msgId: s("msgId"))
        guard let sig = unb64(s("sig")) else { throw Invalid(why: "signature") }
        if let body = env["body"] as? String {
            guard senderSignKey.isValidSignature(sig, for: Data(body.utf8) + aad) else { throw Invalid(why: "bad signature") }
            return Data(body.utf8)
        }
        guard let enc = unb64(s("enc")), let ct = unb64(s("ct")) else { throw Invalid(why: "fields") }
        guard senderSignKey.isValidSignature(sig, for: enc + ct + aad) else { throw Invalid(why: "bad signature") }
        var r = try HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info(s("type")), encapsulatedKey: enc)
        return try r.open(ct, authenticating: aad)
    }
}
