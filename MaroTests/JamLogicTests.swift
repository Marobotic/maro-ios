import XCTest

/** Listen together: jam links, the host's playhead, and what a guest does with a push (social.rs). */
final class JamLogicTests: XCTestCase {
    func testJamCodesFromLinks() {
        XCTAssertEqual(JamLink.code("https://marobotic.dev/jukebox/jam/zyrug4fj"), "zyrug4fj")
        XCTAssertEqual(JamLink.code("https://marobotic.dev/jukebox/jam/zyrug4fj/"), "zyrug4fj")
        XCTAssertEqual(JamLink.code("jukebox://jam/zyrug4fj"), "zyrug4fj")
        XCTAssertEqual(JamLink.code("jukebox://jam/zyrug4fj/"), "zyrug4fj")
        XCTAssertEqual(JamLink.code("  zyrug4fj "), "zyrug4fj")
        XCTAssertEqual(JamLink.code("https://marobotic.dev/jukebox/app/?jam=zyrug4fj"), "zyrug4fj")
        XCTAssertEqual(JamLink.code("https://marobotic.dev/jukebox/jam/zyrug4fj?from=share"), "zyrug4fj")
        XCTAssertEqual(JamLink.code("ZYRUG4FJ"), "zyrug4fj")
        XCTAssertNil(JamLink.code("https://marobotic.dev/jukebox/zyrug4fj"))
        XCTAssertNil(JamLink.code("zyrug4f0"))
        XCTAssertNil(JamLink.code("hello"))
        XCTAssertNil(JamLink.code("jam buddy"))
        XCTAssertNil(JamLink.code(""))
        XCTAssertEqual(JamLink.link("zyrug4fj"), "https://marobotic.dev/jukebox/jam/zyrug4fj")
    }

    func testPlayheadAtReceipt() {
        // Playing: the time since the host's position was taken is added.
        XCTAssertEqual(JamClock.playhead(position: 12, positionAt: 1_000_000, serverNow: 1_002_500, playing: true), 14.5, accuracy: 1e-9)
        // Paused: the position as it is.
        XCTAssertEqual(JamClock.playhead(position: 12, positionAt: 1_000_000, serverNow: 1_002_500, playing: false), 12)
        // A server clock behind the stamp never moves it back.
        XCTAssertEqual(JamClock.playhead(position: 12, positionAt: 1_002_500, serverNow: 1_000_000, playing: true), 12)
    }

    func testPlayheadCountedOn() {
        XCTAssertEqual(JamClock.advanced(30, at: 100, playing: true, now: 103.25), 33.25, accuracy: 1e-9)
        XCTAssertEqual(JamClock.advanced(30, at: 100, playing: false, now: 103.25), 30)
    }

    func testSeeksOnlyPastTheDrift() {
        XCTAssertFalse(JamClock.needsSeek(local: 40, host: 41.4))
        XCTAssertFalse(JamClock.needsSeek(local: 41.4, host: 40))
        XCTAssertTrue(JamClock.needsSeek(local: 40, host: 41.6))
        XCTAssertTrue(JamClock.needsSeek(local: 43, host: 41))
    }

    private let keys = ["ytm:a", "ytm:b", "spotify:c"]
    private let lengths: [Double] = [200, 180, 240]

    private func decide(_ index: Int, _ target: Double, playing: Bool, optimistic: Bool? = nil, _ local: JamLocal) -> JamStep {
        JamFollow.decide(keys: keys, durations: lengths, index: index, target: target, playing: playing, optimistic: optimistic, local: local)
    }

    func testAnotherSongStartsOrIsSetCold() {
        XCTAssertEqual(decide(1, 20, playing: true, JamLocal()), .start(1))
        XCTAssertEqual(decide(1, 20, playing: false, JamLocal()), .cold(1))
        // Same index, another song there (the host's queue changed).
        let other = JamLocal(index: 1, key: "ytm:z", playing: true, position: 20, duration: 180)
        XCTAssertEqual(decide(1, 20, playing: true, other), .start(1))
    }

    func testSameSongFollowsPlayPauseAndDrift() {
        let playing = JamLocal(index: 0, key: "ytm:a", playing: true, position: 50, duration: 200)
        XCTAssertEqual(decide(0, 50.8, playing: true, playing), .nothing)
        XCTAssertEqual(decide(0, 53, playing: true, playing), .seek)
        XCTAssertEqual(decide(0, 50, playing: false, playing), .pause)
        var paused = playing
        paused.playing = false
        XCTAssertEqual(decide(0, 50, playing: true, paused), .resume)
        // Still starting here: no resume, no seek.
        paused.loading = true
        XCTAssertEqual(decide(0, 80, playing: true, paused), .nothing)
    }

    func testOptimisticPressWinsUntilConfirmed() {
        // Pressed pause here; the host's push still says playing: stay paused, no seek.
        let paused = JamLocal(index: 0, key: "ytm:a", playing: false, position: 50, duration: 200)
        XCTAssertEqual(decide(0, 60, playing: true, optimistic: false, paused), .nothing)
        let playing = JamLocal(index: 0, key: "ytm:a", playing: true, position: 50, duration: 200)
        XCTAssertEqual(decide(0, 60, playing: false, optimistic: true, playing), .nothing)
    }

    func testAheadOfTheHostAtTheSongsEnd() {
        // This phone moved on to the next song a moment before the host.
        let ahead = JamLocal(index: 1, key: "ytm:b", playing: true, position: 1, duration: 180)
        XCTAssertEqual(decide(0, 198.5, playing: true, ahead), .nothing)
        // Not near the end: the host's song it is.
        XCTAssertEqual(decide(0, 120, playing: true, ahead), .start(0))
    }

    func testNothingAtTheHostsIndex() {
        let playing = JamLocal(index: 0, key: "ytm:a", playing: true, position: 5, duration: 200)
        XCTAssertEqual(decide(-1, 0, playing: false, playing), .stop)
        XCTAssertEqual(decide(7, 0, playing: true, playing), .stop)
        XCTAssertEqual(decide(-1, 0, playing: false, JamLocal()), .nothing)
    }

    func testGuestControl() {
        XCTAssertTrue(JamFollow.allowed("toggle", guestsControl: true))
        XCTAssertFalse(JamFollow.allowed("toggle", guestsControl: false))
        XCTAssertFalse(JamFollow.allowed("seek", guestsControl: false))
        XCTAssertTrue(JamFollow.allowed("queue.add", guestsControl: false))
        XCTAssertTrue(JamFollow.allowed("queue.addNext", guestsControl: false))
    }
}

/** The Transfers list: rows, speeds, the overall line, Clear. */
final class TransferListTests: XCTestCase {
    func testRowsAndTotals() {
        var list = TransferList()
        let a = list.open("Song A", sub: "Artist", queued: false)
        let b = list.open("Song B", sub: "Artist", queued: true)
        list.progress(a, done: 1_000_000, total: 4_000_000)
        var t = list.totals
        XCTAssertEqual(t.done, 1_000_000)
        XCTAssertEqual(t.total, 4_000_000)
        XCTAssertEqual(t.left, 2)
        list.begin(b)
        list.progress(b, done: 0, total: 2_000_000)
        list.finish(a, now: 10)
        t = list.totals
        XCTAssertEqual(t.done, 4_000_000)
        XCTAssertEqual(t.total, 6_000_000)
        XCTAssertEqual(t.left, 1)
        list.fail(b, "no connection")
        XCTAssertEqual(list.items.first { $0.id == b }?.reason, "no connection")
        list.clear()
        XCTAssertTrue(list.items.isEmpty)
    }

    func testSpeedIsSmoothed() {
        var list = TransferList()
        let a = list.open("Song", sub: "", queued: false)
        list.progress(a, done: 500_000, total: 5_000_000)
        list.tick(dt: 0.5, now: 1)
        XCTAssertEqual(list.items[0].speed, 1_000_000, accuracy: 1)
        list.progress(a, done: 1_000_000, total: 5_000_000)
        list.tick(dt: 0.25, now: 1.25)
        // 0.7 of the old 1 MB/s and 0.3 of the new 2 MB/s.
        XCTAssertEqual(list.items[0].speed, 1_300_000, accuracy: 1)
    }

    func testAutomaticRowsLeaveAfterTheyFinish() {
        var list = TransferList()
        let kept = list.open("Played song", sub: "", queued: false, auto: true)
        let asked = list.open("Saved song", sub: "", queued: false)
        list.finish(kept, now: 100)
        list.finish(asked, now: 100)
        list.tick(dt: 0.25, now: 102)
        XCTAssertEqual(list.items.count, 2)
        list.tick(dt: 0.25, now: 105.5)
        XCTAssertEqual(list.items.map(\.id), [asked])
    }

    func testSizes() {
        XCTAssertEqual(TransferList.size(512_000), "512 KB")
        XCTAssertEqual(TransferList.size(4_260_000), "4.3 MB")
        XCTAssertEqual(TransferList.size(1_500_000_000), "1.50 GB")
        XCTAssertEqual(TransferList.rate(850_000), "850 KB/s")
        XCTAssertEqual(TransferList.rate(2_400_000), "2.4 MB/s")
    }
}
