import XCTest

/** Small boxes ask for small pictures; a big box (the full player) for a big one. */
final class ArtSizeTests: XCTestCase {
    func testDropletSteps() {
        XCTAssertEqual(ArtSize.step(1), 64)
        XCTAssertEqual(ArtSize.step(132), 160)      // a 44 pt row on a 3x screen
        XCTAssertEqual(ArtSize.step(600), 640)      // the lock screen
        XCTAssertEqual(ArtSize.step(5000), 1024)
    }

    func testSpotify() {
        let album = "https://i.scdn.co/image/ab67616d0000b273abcdef0123456789abcdef01"
        XCTAssertEqual(ArtSize.sized(album, 132), "https://i.scdn.co/image/ab67616d00001e02abcdef0123456789abcdef01")
        XCTAssertEqual(ArtSize.sized(album, 48), "https://i.scdn.co/image/ab67616d00004851abcdef0123456789abcdef01")
        XCTAssertEqual(ArtSize.sized(album, 1000), album)
        let artist = "https://i.scdn.co/image/ab6761610000e5ebabcdef0123456789abcdef01"
        XCTAssertEqual(ArtSize.sized(artist, 150), "https://i.scdn.co/image/ab6761610000f178abcdef0123456789abcdef01")
        XCTAssertEqual(ArtSize.sized("https://mosaic.scdn.co/640/a/b/c/d", 132), "https://mosaic.scdn.co/300/a/b/c/d")
    }

    func testGoogle() {
        XCTAssertEqual(ArtSize.sized("https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj", 132),
                       "https://lh3.googleusercontent.com/abc=w132-h132-l90-rj")
        XCTAssertEqual(ArtSize.sized("https://yt3.ggpht.com/abc=s900-c-k", 192), "https://yt3.ggpht.com/abc=s192-c-k")
    }

    func testYouTube() {
        XCTAssertEqual(ArtSize.sized("https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg", 132),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        XCTAssertEqual(ArtSize.sized("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg?sqp=abc&rs=x", 300),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        XCTAssertEqual(ArtSize.sized("https://i.ytimg.com/vi_webp/dQw4w9WgXcQ/sddefault.webp", 1000),
                       "https://i.ytimg.com/vi_webp/dQw4w9WgXcQ/sddefault.webp")
        // Never a bigger still than the one named.
        XCTAssertEqual(ArtSize.sized("https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg", 300),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg")
    }

    func testSoundCloud() {
        XCTAssertEqual(ArtSize.sized("https://i1.sndcdn.com/artworks-000123-abc-t500x500.jpg", 132),
                       "https://i1.sndcdn.com/artworks-000123-abc-t300x300.jpg")
        XCTAssertEqual(ArtSize.sized("https://i1.sndcdn.com/artworks-000123-abc-large.jpg", 60),
                       "https://i1.sndcdn.com/artworks-000123-abc-t67x67.jpg")
    }

    func testNotAWebURL() {
        XCTAssertEqual(ArtSize.sized("VIDEOID1234", 100), "")
        XCTAssertEqual(ArtSize.sized("https://example.com/a.png", 100), "https://example.com/a.png")
    }
}

final class PfpURLTests: XCTestCase {
    func testAccountPictureAtTheServersSize() {
        XCTAssertEqual(PfpURL.sized("https://marobotic.dev/cache/avatar/abc?v=3", px: 96), "https://marobotic.dev/cache/avatar/abc?v=3&s=96")
        XCTAssertEqual(PfpURL.sized("https://marobotic.dev/cache/avatar/abc", px: 33), "https://marobotic.dev/cache/avatar/abc?s=64")
        XCTAssertEqual(PfpURL.sized("https://marobotic.dev/cache/avatar/abc", px: 400), "https://marobotic.dev/cache/avatar/abc?s=128")
    }

    func testGuestDrawingAsAPNG() {
        XCTAssertEqual(PfpURL.sized("https://marobotic.dev/jukebox/guestart/otter.svg", px: 96), "https://marobotic.dev/jukebox/guestart/otter-96.png")
        XCTAssertEqual(PfpURL.sized("https://marobotic.dev/jukebox/guestart/otter.svg?v=2", px: 64), "https://marobotic.dev/jukebox/guestart/otter-64.png")
    }

    func testAnythingElseGetsInitials() {
        XCTAssertEqual(PfpURL.sized("", px: 96), "")
        XCTAssertEqual(PfpURL.sized("http://marobotic.dev/cache/avatar/abc", px: 96), "")
        XCTAssertEqual(PfpURL.sized("https://example.com/me.png", px: 96), "")
        XCTAssertEqual(PfpURL.initials("Maro Ahmed"), "MA")
        XCTAssertEqual(PfpURL.initials("maro"), "M")
        XCTAssertEqual(PfpURL.initials("  "), "?")
    }
}
