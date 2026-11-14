import Foundation

/**
 * Every song this phone downloads, in one list (the desktop's transfers.rs):
 * saved offline or with a playlist, and the copies it keeps as songs play.
 * Foundation only, so the test target builds it; `Transfers` publishes it.
 */
struct TransferItem: Identifiable, Equatable {
    enum State: String { case queued, active, done, failed }

    let id: Int
    var label: String
    var sub: String
    var state: State
    var done: Int64 = 0
    var total: Int64 = 0
    /** Bytes a second, smoothed. */
    var speed: Double = 0
    var lastDone: Int64 = 0
    var reason = ""
    /** Made by the app itself (a song kept as it played): leaves the list soon after it succeeds. */
    var auto = false
    /** Uptime when it finished, for an automatic row's linger. */
    var finishedAt: Double = 0

    var live: Bool { state == .queued || state == .active }
    var fraction: Double { state == .done ? 1 : total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

struct TransferList: Equatable {
    /** How long a finished automatic row stays before it removes itself. */
    static let autoLinger: Double = 5

    private(set) var items: [TransferItem] = []
    private var next = 1

    @discardableResult
    mutating func open(_ label: String, sub: String, queued: Bool, auto: Bool = false) -> Int {
        let id = next
        next += 1
        items.append(TransferItem(id: id, label: label, sub: sub, state: queued ? .queued : .active, auto: auto))
        return id
    }

    private mutating func edit(_ id: Int, _ f: (inout TransferItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) }
    }

    mutating func begin(_ id: Int) { edit(id) { if $0.state == .queued { $0.state = .active } } }

    mutating func progress(_ id: Int, done: Int64, total: Int64) {
        edit(id) {
            $0.done = max(0, done)
            if total > 0 { $0.total = total }
        }
    }

    mutating func finish(_ id: Int, now: Double) {
        edit(id) {
            if $0.total == 0 || $0.done > $0.total { $0.total = $0.done } else { $0.done = $0.total }
            $0.state = .done
            $0.speed = 0
            $0.finishedAt = now
        }
    }

    mutating func fail(_ id: Int, _ why: String) {
        edit(id) {
            $0.state = .failed
            $0.reason = why
            $0.speed = 0
        }
    }

    /** Nothing to show after all (already on the phone). */
    mutating func drop(_ id: Int) { items.removeAll { $0.id == id } }

    /** Clear: finished and failed rows go. */
    mutating func clear() { items.removeAll { !$0.live } }

    /**
     * Once every `dt` seconds while anything moves: speeds smoothed (EMA over
     * about a second) from the bytes counted since the last tick, and the
     * automatic rows that finished a while ago removed.
     */
    mutating func tick(dt: Double, now: Double) {
        let dt = max(dt, 0.05)
        for i in items.indices {
            if items[i].state == .active {
                let inst = Double(max(0, items[i].done - items[i].lastDone)) / dt
                items[i].speed = items[i].speed == 0 ? inst : items[i].speed * 0.7 + inst * 0.3
            }
            items[i].lastDone = items[i].done
        }
        items.removeAll { $0.auto && $0.state == .done && now - $0.finishedAt >= Self.autoLinger }
    }

    var moving: Bool { items.contains { $0.live } }

    /** The overall line: bytes of the rows with a known size, their total, the speed, rows still to go. */
    var totals: (done: Int64, total: Int64, speed: Double, left: Int) {
        let total = items.reduce(Int64(0)) { $0 + $1.total }
        let done = items.filter { $0.total > 0 }.reduce(Int64(0)) { $0 + min($1.done, $1.total) }
        let speed = items.filter { $0.state == .active }.reduce(0) { $0 + $1.speed }
        return (done, total, speed, items.filter(\.live).count)
    }

    static func size(_ n: Int64) -> String {
        let b = Double(max(0, n))
        if b >= 1e9 { return String(format: "%.2f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.1f MB", b / 1e6) }
        return "\(Int((b / 1e3).rounded())) KB"
    }

    static func rate(_ n: Double) -> String {
        n >= 1e6 ? String(format: "%.1f MB/s", n / 1e6) : "\(Int((n / 1e3).rounded())) KB/s"
    }
}
