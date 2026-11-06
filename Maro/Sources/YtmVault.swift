import Foundation

/**
 * The YouTube Music session as Jukebox online keeps it (round 2 C).
 *
 * Google kept signing Maro out because several apps each held, rotated and
 * pushed their own copy of the same session. Now the droplet holds the only
 * one: a real Chrome there opens YouTube Music every 20 minutes so Google
 * rotates the cookies itself, and every app takes its latest export from
 * `GET /cache/ytm/session`. This phone never rotates or writes back a
 * cookie, and never puts the session on the account's sealed /service/ytm
 * blob again: a sign-in here seeds the droplet (`POST`), then the sign-in
 * page's own cookies are thrown away.
 *
 * The copy is read at start, every 10 minutes, and at once when YouTube Music
 * turns the session away (then the call is tried once more). Offline, the
 * last copy fetched keeps working, read-only. Kept in the keychain so a
 * launch without a connection still has it.
 */
final class YtmVault: @unchecked Sendable {
    static let shared = YtmVault()

    /** Set once at start-up. */
    var client: MaroClient? {
        get { lock.lock(); defer { lock.unlock() }; return _client }
        set { lock.lock(); _client = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _client: MaroClient?
    /** The last answer that carried cookies: {state, account, at, cookies, headers}. */
    private var copy: JSON?
    /** "unknown" (never asked), "none" (not seeded), "ok", "expired" or "error". */
    private var vaultState = "unknown"
    private var account = ""
    private var at: Date?
    /** Whether the last ask reached the droplet (false: showing the kept copy). */
    private var reached = false
    private var refusedAt: Double = -.infinity
    private static let item = "vault.ytm"

    private init() {
        if let data = Keychain.get(Self.item), let kept = JSONText.parse(data) as? JSON {
            copy = kept
            vaultState = kept.str("state", "ok").ifEmpty("ok")
            account = kept.str("account")
            at = Self.date(kept["at"])
        }
    }

    // -- what the rest of the app reads ----------------------------------

    /** The Cookie header for music.youtube.com, or "" when there is no session. */
    var cookie: String {
        lock.lock(); defer { lock.unlock() }
        guard let copy else { return "" }
        let header = copy.obj("headers")?.str("cookie") ?? ""
        return header.isEmpty ? Self.cookieHeader(fromNetscape: copy.str("cookies")) : header
    }

    /** Which Google account in the jar (X-Goog-AuthUser); "0" unless the droplet says otherwise. */
    var authUser: String {
        lock.lock(); defer { lock.unlock() }
        return copy?.obj("headers")?.str("x-goog-authuser").ifEmpty("0") ?? "0"
    }

    /** The droplet's state, its Google account and when it last refreshed the session. */
    var status: (state: String, account: String, at: Date?, reached: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (vaultState, account, at, reached)
    }

    /** Jukebox online holds a session for this account (working or not). */
    var seeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ["ok", "expired", "error"].contains(vaultState) || copy != nil
    }

    /**
     * Only while Jukebox online has never held a session may the account's
     * older sealed copy be used (read-only, never written back), so YouTube
     * Music keeps working until the first sign-in seeds the droplet.
     */
    var mayUseLegacy: Bool {
        lock.lock(); defer { lock.unlock() }
        return copy == nil && (vaultState == "none" || vaultState == "unknown")
    }

    // -- in step with the droplet ----------------------------------------

    /**
     * The droplet's latest copy. True when the cookie changed (a call that
     * failed is worth trying again). Unreachable: the kept copy stays.
     */
    @discardableResult
    func refresh() async -> Bool {
        guard let client, client.session != nil else { return false }
        let before = cookie
        guard let got = await client.ytmSession() else {
            unreached()
            return false
        }
        take(got)
        return cookie != before
    }

    /** Just the state (Settings > Health): no cookies travel. */
    func refreshStatus() async {
        guard let client, client.session != nil else { return }
        guard let got = await client.ytmSession(withCookies: false) else {
            unreached()
            return
        }
        take(got, cookies: false)
    }

    /**
     * YouTube Music turned the session away (401, 403, or a signed-out
     * answer): a fresh copy at once, at most once a minute. True when there
     * is a new cookie to try the call with.
     */
    func refreshAfterRefusal() async -> Bool {
        guard claimRefusal() else { return false }
        return await refresh()
    }

    // The lock is only ever taken in these synchronous helpers, never across an await.
    private func unreached() {
        lock.lock(); reached = false; lock.unlock()
    }

    private func claimRefusal() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = uptime()
        if now - refusedAt < 60 { return false }
        refusedAt = now
        return true
    }

    /**
     * A sign-in made on this phone, handed to the droplet: it imports the
     * cookies into its own Chrome and keeps them alive from then on. nil when
     * it took them, else why not. The phone keeps nothing of its own.
     */
    func seed(_ session: JSON) async -> String? {
        guard let client, client.session != nil else { return "Sign in to Jukebox first" }
        let cookies = session.str("cookies")
        guard !cookies.isEmpty else { return "The sign-in carried no cookies - try again" }
        guard let got = await client.seedYtmSession(cookies: cookies, headers: session.obj("headers") ?? [:]) else {
            return "Couldn't reach Jukebox online to keep the sign-in - try again"
        }
        guard got.ok else {
            let why = got.body.str("error")
            return why.isEmpty ? "Jukebox online did not take the sign-in - try again" : "Jukebox online: \(why)"
        }
        take(got.body, cookies: false)
        // Its fresh export, the copy every app uses.
        await refresh()
        return nil
    }

    /** Signed out of YouTube Music: the droplet's keeper stopped and wiped, and the copy here gone. */
    func signOut() async {
        _ = await client?.deleteYtmSession()
        forgetLocal(state: "none")
    }

    /** Signing out of Jukebox on this phone: the copy here goes (the droplet keeps it for the other devices). */
    func forgetLocal(state: String = "unknown") {
        lock.lock()
        copy = nil
        vaultState = state
        account = ""
        at = nil
        lock.unlock()
        Keychain.remove(Self.item)
    }

    private func take(_ got: JSON, cookies: Bool = true) {
        let state = got.str("state").ifEmpty(got.bool("ok") ? "ok" : "error")
        lock.lock()
        reached = true
        vaultState = state
        account = got.str("account")
        at = Self.date(got["at"]) ?? at
        var keep: JSON?
        if state == "none" {
            copy = nil
        } else if cookies, !got.str("cookies").isEmpty || !(got.obj("headers")?.str("cookie") ?? "").isEmpty {
            var c = got
            c["state"] = state
            c.removeValue(forKey: "ok")
            copy = c
            keep = c
        } else if var c = copy {
            c["state"] = state
            c["account"] = account
            if let at { c["at"] = at.timeIntervalSince1970 }
            copy = c
            keep = c
        }
        lock.unlock()
        if let keep {
            Keychain.set(JSONText.data(keep), Self.item)
        } else if state == "none" {
            Keychain.remove(Self.item)
        }
    }

    // -- helpers ---------------------------------------------------------

    /** "at" as the droplet writes it: epoch seconds or milliseconds, or an ISO date. */
    static func date(_ value: Any?) -> Date? {
        var seconds: Double?
        switch value {
        case let n as NSNumber: seconds = n.doubleValue
        case let s as String:
            if let d = ISO8601DateFormatter.flexible(s) { return d }
            seconds = Double(s)
        default: return nil
        }
        guard var v = seconds, v > 0 else { return nil }
        if v > 100_000_000_000 { v /= 1000 }
        return Date(timeIntervalSince1970: v)
    }

    /**
     * The Cookie header from a Netscape cookies.txt: every youtube.com cookie
     * (the "#HttpOnly_" lines included), one value per name.
     */
    static func cookieHeader(fromNetscape text: String) -> String {
        var order: [String] = []
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, f[0].hasSuffix("youtube.com"), !f[5].isEmpty else { continue }
            if values[f[5]] == nil { order.append(f[5]) }
            values[f[5]] = f[6]
        }
        return order.map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
    }

    /** "4 min ago", "2 h ago", "just now". */
    static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }
}
