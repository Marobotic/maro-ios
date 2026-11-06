import CryptoKit
import XCTest

/**
 * Round 2 I.6 interop: open the shared vector (written by another app) and
 * verify both signatures, then round-trip our own envelopes.
 */
final class DeviceCryptoTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "round2-hpke-vector", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func keys(_ v: [String: Any]) throws -> (Curve25519.KeyAgreement.PrivateKey, Curve25519.Signing.PublicKey, String) {
        let r = try XCTUnwrap(v["recipient"] as? [String: Any])
        let s = try XCTUnwrap(v["sender"] as? [String: Any])
        let sk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try XCTUnwrap(DeviceCrypto.unb64(r["x25519Private"] as? String ?? "")))
        let pk = try Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(DeviceCrypto.unb64(s["ed25519Public"] as? String ?? "")))
        return (sk, pk, r["deviceId"] as? String ?? "")
    }

    func testOpensSealedVector() throws {
        let v = try vector()
        let (sk, signKey, me) = try keys(v)
        let sealed = try XCTUnwrap(v["sealed"] as? [String: Any])
        let env = try XCTUnwrap(sealed["envelope"] as? [String: Any])
        let plain = try DeviceCrypto.open(env, me: me, recipient: sk, senderSignKey: signKey)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), sealed["plaintext"] as? String)
    }

    func testVerifiesSignedPlainVector() throws {
        let v = try vector()
        let (sk, signKey, me) = try keys(v)
        let signed = try XCTUnwrap(v["signedPlain"] as? [String: Any])
        let env = try XCTUnwrap(signed["envelope"] as? [String: Any])
        let body = try DeviceCrypto.open(env, me: me, recipient: sk, senderSignKey: signKey)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), env["body"] as? String)
        // A changed body must fail.
        var bad = env
        bad["body"] = (env["body"] as? String ?? "") + " "
        XCTAssertThrowsError(try DeviceCrypto.open(bad, me: me, recipient: sk, senderSignKey: signKey))
    }

    func testRoundTrip() throws {
        let rk = Curve25519.KeyAgreement.PrivateKey()
        let signer = Curve25519.Signing.PrivateKey()
        let plain = Data("{\"service\":\"spotify\"}".utf8)
        let env = try DeviceCrypto.seal(plain, type: "session.offer", msgId: "m1", from: "a", to: "b",
                                        recipient: rk.publicKey, signer: signer)
        XCTAssertEqual(try DeviceCrypto.open(env, me: "b", recipient: rk, senderSignKey: signer.publicKey), plain)
        XCTAssertThrowsError(try DeviceCrypto.open(env, me: "c", recipient: rk, senderSignKey: signer.publicKey))
    }
}
