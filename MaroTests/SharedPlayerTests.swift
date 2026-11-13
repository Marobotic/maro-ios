import XCTest

/** Another device holds the shared player only while it is live. */
final class SharedPlayerTests: XCTestCase {
    private let me = "phone-me"

    func testLiveOwnerHoldsThePlayer() {
        XCTAssertTrue(PlayerOwner.otherHolds(owner: "desk", me: me, queueCount: 3, connected: ["desk"]))
    }

    func testGoneOwnerHoldsNothing() {
        // Listed as not connected, or not listed at all (a phone gone for days).
        XCTAssertFalse(PlayerOwner.otherHolds(owner: "phone-be956e9d", me: me, queueCount: 3, connected: ["desk"]))
        XCTAssertFalse(PlayerOwner.otherHolds(owner: "phone-be956e9d", me: me, queueCount: 3, connected: []))
    }

    func testEmptyQueueOrOwnPlayerHoldsNothing() {
        XCTAssertFalse(PlayerOwner.otherHolds(owner: "desk", me: me, queueCount: 0, connected: ["desk"]))
        XCTAssertFalse(PlayerOwner.otherHolds(owner: me, me: me, queueCount: 3, connected: [me]))
        XCTAssertFalse(PlayerOwner.otherHolds(owner: "", me: me, queueCount: 3, connected: ["desk"]))
    }
}
