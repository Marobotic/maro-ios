import XCTest

final class AppReleaseTests: XCTestCase {
    private let installed = AppRelease(version: "0.4.9", build: 49)

    private func update(_ json: String) throws -> IOSRelease? {
        try installed.update(from: Data(json.utf8))
    }

    func testOnlyHigherIOSBuildShowsBanner() throws {
        let newer = try update(#"{"ios":{"version":"0.5.0","build":50,"url":"https://example.com/app.ipa","sha256":"abc","size":123}}"#)
        XCTAssertEqual(newer?.banner, "Jukebox 0.5.0 is available - install it from your PC")
        XCTAssertNil(try update(#"{"ios":{"version":"9.0.0","build":49}}"#))
        XCTAssertNil(try update(#"{"ios":{"version":"9.0.0","build":47}}"#))
        // Build is authoritative even when the marketing version is unchanged.
        XCTAssertNotNil(try update(#"{"ios":{"version":"0.4.9","build":"50"}}"#))
        XCTAssertNil(try update(#"{"android":{"version":"9.0.0","build":500}}"#))
    }

    func testMalformedManifestIsRejected() throws {
        XCTAssertThrowsError(try update("not json"))
        XCTAssertThrowsError(try update(#"{"ios":{"version":"0.5.0","build":"oops"}}"#))
        XCTAssertThrowsError(try update(#"{"ios":{"version":"0.5.0"}}"#))
        XCTAssertNil(try update(#"{"ios":{"version":"  ","build":50}}"#))
        XCTAssertEqual(installed.displayVersion, "0.4.9 (49)")
    }
}
