import Foundation

/**
 * Listening together, the parts with no UI (Foundation only, so the macOS test
 * target builds them): a jam code from whatever was pasted or opened, the
 * host's playhead, and what a guest does to stay on it. The desktop's
 * app/src/social.rs, step for step.
 */
enum JamLink {
    static let site = "https://marobotic.dev/jukebox/jam/"

    /** A jam code from a link, a jukebox:// address or the bare 8-letter code; nil for anything else. */
    static func code(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        let tail = t.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "=" }.last.map(String.init) ?? ""
        let last = (tail.split(omittingEmptySubsequences: false) { $0 == "?" || $0 == "#" }.first.map(String.init) ?? "").lowercased()
        let ok = last.count == 8 && last.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "2" && $0 <= "9") }
        let shaped = t.lowercased() == last || t.contains("/jam/") || t.contains("jam=") || t.hasPrefix("jukebox:")
        return ok && shaped ? last : nil
    }

    static func link(_ code: String) -> String { site + code }
}

/** The host's playhead, as the server reports it, and how far a guest may drift from it. */
enum JamClock {
    /** The guest's playhead is moved only when it is this far from the host's. */
    static let drift: Double = 1.5

    /** Where the host is at the moment the server answered: `position + (serverNow - positionAt)/1000` while playing. */
    static func playhead(position: Double, positionAt: Double, serverNow: Double, playing: Bool) -> Double {
        guard playing else { return position }
        return position + max(0, (serverNow - positionAt) / 1000)
    }

    /** That playhead counted on with the local clock (seconds) since it arrived at `at`. */
    static func advanced(_ target: Double, at: Double, playing: Bool, now: Double) -> Double {
        playing ? target + max(0, now - at) : target
    }

    static func needsSeek(local: Double, host: Double) -> Bool { abs(local - host) > drift }
}

/** What a guest's phone does with one push of the host's player. */
enum JamStep: Equatable {
    case nothing
    /** The host has nothing at its index: silence here too. */
    case stop
    /** Start the song at this index, at the host's second. */
    case start(Int)
    /** The host is paused on another song: set it here at its second, silent. */
    case cold(Int)
    case pause
    case resume
    case seek
}

/** The guest's own player, as `JamFollow.decide` needs to see it. */
struct JamLocal: Equatable {
    var index = -1
    /** The song set here ("source:id"), nil for none. */
    var key: String?
    var playing = false
    /** A song is still starting here. */
    var loading = false
    var position: Double = 0
    var duration: Double = 0
}

enum JamFollow {
    static func key(source: String, id: String) -> String { source + ":" + id }

    /**
     * One push: the host's queue (keys and lengths), its index, its playhead
     * and whether it plays; `optimistic` is a press of this guest's shown
     * before the host confirms it (play or pause), nil for none.
     */
    static func decide(keys: [String], durations: [Double], index: Int, target: Double, playing: Bool,
                       optimistic: Bool?, local: JamLocal) -> JamStep {
        guard index >= 0 && index < keys.count else {
            return local.key != nil || local.playing ? .stop : .nothing
        }
        let same = local.index == index && local.key == keys[index]
        // This phone finished the song a moment before the host did and moved
        // on by itself: the host catches up, nothing to undo.
        let length = index < durations.count ? durations[index] : 0
        let ahead = !same && local.index == index + 1 && local.duration > 0 && length > 0 && target > length - 3
        if ahead { return .nothing }
        if !same { return playing ? .start(index) : .cold(index) }
        let want = optimistic ?? playing
        if want && !local.playing && !local.loading { return .resume }
        if !want && local.playing { return .pause }
        if !local.loading && optimistic == nil && JamClock.needsSeek(local: local.position, host: target) { return .seek }
        return .nothing
    }

    /** Actions a guest may send; with guest control off only the two queue adds. */
    static let queueAdds: Set<String> = ["queue.add", "queue.addNext"]

    static func allowed(_ action: String, guestsControl: Bool) -> Bool {
        guestsControl || queueAdds.contains(action)
    }
}
