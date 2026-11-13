import Foundation

/** Who holds the account's shared player (Foundation only, so the unit tests build it alone). */
enum PlayerOwner {
    /**
     * Another device holds the shared player only while it is live: it has
     * songs queued and the account lists it as connected (paused counts). A
     * gone owner (a phone that went away days ago) holds it like nobody, and
     * this device takes the player when it plays or a device is picked.
     */
    static func otherHolds(owner: String, me: String, queueCount: Int, connected: Set<String>) -> Bool {
        if owner.isEmpty || owner == me || queueCount == 0 { return false }
        return connected.contains(owner)
    }
}
