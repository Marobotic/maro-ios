import Foundation
import WebKit

/**
 * This phone's YouTube Music session (round 2 H): one session per device,
 * kept fresh on the device, never exported.
 *
 * Google binds a session to the browser that holds it, and kills one that
 * turns up in two places - which is what kept signing Maro out while the
 * desktop's session was copied to every device. So, like Kaset, Metrolist and
 * the other clients that stay signed in: the phone signs in once in its own
 * persistent web view store (ServiceSignIn uses `store`), and that session
 * never leaves the phone - not to the account, not to the server.
 *
 * - The cookies live in a persistent WKWebsiteDataStore of their own, backed
 *   up to the Keychain (restored if WebKit ever loses them).
 * - A hidden web view opens music.youtube.com at start and about every 20
 *   minutes while the app runs, so Google rotates the cookies in place.
 * - YouTube Music calls send that store's cookies, and every cookie an answer
 *   sets goes back into the store.
 */
@MainActor
final class YtmDevice: NSObject, WKNavigationDelegate {
    static let shared = YtmDevice()

    /** The store's fixed identity: the same persistent store on every launch. */
    private static let storeId = UUID(uuidString: "6A7E0C1E-5B0B-4F55-9C8E-3D2A9B4E7101")!
    private static let backupItem = "ytm.device.cookies"
    private static let refreshEvery: Double = 20 * 60

    /** The persistent store the sign-in page and the keeper share. */
    let store: WKWebsiteDataStore
    /** The account name YouTube Music last gave for this session ("" unknown). */
    private(set) var account = ""
    /** When the keeper last finished a visit. */
    private(set) var freshAt: Date?

    private var started = false
    private var keeper: WKWebView?
    private var keeperDone: CheckedContinuation<Void, Never>?
    private var loop: Task<Void, Never>?

    private override init() {
        store = WKWebsiteDataStore(forIdentifier: Self.storeId)
        super.init()
    }

    var signedIn: Bool { !YtmJar.shared.header.isEmpty }

    /**
     * At start: restore, read, and keep it fresh every 20 minutes. Every
     * caller waits for the same first read; later calls return at once.
     */
    func start() async {
        if let starting {
            await starting.value
            return
        }
        let first = Task { @MainActor in await self.firstStart() }
        starting = first
        await first.value
    }

    private var starting: Task<Void, Never>?

    private func firstStart() async {
        if started { return }
        started = true
        // The copies older builds took from the account: never used again.
        Keychain.remove("svc.ytm")
        Keychain.remove("at.ytm")
        await restoreIfNeeded()
        await readCookies()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.signedIn { await self.visit() }
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshEvery * 1_000_000_000))
            }
        }
    }

    /** A sign-in just finished in `store`: read it, back it up, and visit once. */
    func signedInNow() async {
        await readCookies()
        Task { await visit() }
    }

    /**
     * Read the store again (a call was turned away): true when the cookies
     * changed, so the call is worth trying once more. A visit follows.
     */
    func reread() async -> Bool {
        let before = YtmJar.shared.header
        await readCookies()
        Task { await visit() }
        return YtmJar.shared.header != before
    }

    /** Cookies a YouTube Music answer set: into the store, so the session rotates in one place. */
    func absorb(_ cookies: [HTTPCookie]) async {
        guard !cookies.isEmpty else { return }
        for c in cookies { await store.httpCookieStore.setCookie(c) }
        await readCookies()
    }

    func setAccount(_ name: String) { account = name }

    /** The name the session was made under (the keeper visits with it). */
    var userAgent: String { UserDefaults.standard.string(forKey: "ytmUserAgent") ?? ServiceSignIn.safariFallback }

    /**
     * The Google and YouTube cookies as a Netscape cookies.txt, for a
     * hand-over (round 2 I.5/I.6; the caller seals it to the target).
     */
    func exportNetscape() async -> String {
        let all = await store.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com") }
        guard all.contains(where: Self.isSignIn) else { return "" }
        var lines = ["# Netscape HTTP Cookie File"]
        for c in all {
            let domain = c.domain
            let flag = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expires = Int(c.expiresDate?.timeIntervalSince1970 ?? 0)
            lines.append([(c.isHTTPOnly ? "#HttpOnly_" : "") + domain, flag, c.path.isEmpty ? "/" : c.path,
                          c.isSecure ? "TRUE" : "FALSE", "\(expires)", c.name, c.value].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /** Cookies handed over by the previous holder (Netscape): into this phone's store, then read. */
    func importNetscape(_ text: String, userAgent: String) async {
        if !userAgent.isEmpty { UserDefaults.standard.set(userAgent, forKey: "ytmUserAgent") }
        var rows: [JSON] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
                httpOnly = true
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, !f[5].isEmpty else { continue }
            var o: JSON = ["domain": f[0], "path": f[2], "secure": f[3] == "TRUE", "name": f[5], "value": f[6], "httpOnly": httpOnly]
            if let e = Double(f[4]), e > 0 { o["expires"] = e }
            rows.append(o)
        }
        await setRows(rows)
        await readCookies()
    }

    /** Signed out on this phone: the store and its backup wiped. */
    func signOut() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        Keychain.remove(Self.backupItem)
        YtmJar.shared.set("")
        account = ""
        freshAt = nil
    }

    // -- the store --------------------------------------------------------

    private static func isSignIn(_ c: HTTPCookie) -> Bool {
        (c.name == "SAPISID" || c.name == "__Secure-3PAPISID") && c.domain.hasSuffix("youtube.com")
    }

    /** The store's YouTube cookies as the Cookie header (one value per name), and a Keychain backup. */
    private func readCookies() async {
        let all = await store.httpCookieStore.allCookies()
        let live = all.filter { $0.expiresDate.map { $0 > Date() } ?? true }
        guard live.contains(where: Self.isSignIn) else {
            YtmJar.shared.set("")
            return
        }
        var order: [String] = []
        var values: [String: String] = [:]
        // music.youtube.com's own cookies win over .youtube.com's of the same name.
        for c in live.filter({ $0.domain.hasSuffix("youtube.com") }).sorted(by: { $0.domain.count < $1.domain.count }) {
            if values[c.name] == nil { order.append(c.name) }
            values[c.name] = c.value
        }
        YtmJar.shared.set(order.map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; "))
        backup(live.filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com") })
    }

    private static func rows(_ cookies: [HTTPCookie]) -> [JSON] {
        cookies.map { c in
            var o: JSON = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                           "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let e = c.expiresDate { o["expires"] = e.timeIntervalSince1970 }
            if let s = c.sameSitePolicy { o["sameSite"] = s.rawValue }
            return o
        }
    }

    private func backup(_ cookies: [HTTPCookie]) {
        Keychain.set(JSONText.data(Self.rows(cookies)), Self.backupItem)
    }

    /** WebKit lost the cookies (a cleared store): put the Keychain backup back. */
    private func restoreIfNeeded() async {
        let all = await store.httpCookieStore.allCookies()
        if all.contains(where: Self.isSignIn) { return }
        guard let data = Keychain.get(Self.backupItem), let rows = JSONText.parse(data) as? [JSON] else { return }
        await setRows(rows)
        ConsoleLog.shared.log("YouTubeMusic", "restored this phone's sign-in from the Keychain backup")
    }

    /** Cookie rows (backup or hand-over) into the store. */
    private func setRows(_ rows: [JSON]) async {
        let now = Date().timeIntervalSince1970
        for o in rows {
            let expires = o.double("expires")
            if expires > 0 && expires < now { continue }
            var p: [HTTPCookiePropertyKey: Any] = [
                .name: o.str("name"), .value: o.str("value"), .domain: o.str("domain"), .path: o.str("path", "/"),
            ]
            if o.bool("secure") { p[.secure] = "TRUE" }
            if expires > 0 { p[.expires] = Date(timeIntervalSince1970: expires) }
            if o.bool("httpOnly") { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if !o.str("sameSite").isEmpty { p[.sameSitePolicy] = o.str("sameSite") }
            if let c = HTTPCookie(properties: p) { await store.httpCookieStore.setCookie(c) }
        }
    }

    // -- the keeper: music.youtube.com in a hidden web view -------------------

    /** One visit: open music.youtube.com, give its scripts time, read what Google rotated. */
    private func visit() async {
        guard keeper == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.customUserAgent = UserDefaults.standard.string(forKey: "ytmUserAgent") ?? ServiceSignIn.safariFallback
        view.navigationDelegate = self
        keeper = view
        view.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        // The page loaded (or a minute passed), then its scripts get a while.
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            keeperDone = k
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.keeperDone?.resume()
                self?.keeperDone = nil
            }
        }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        keeper = nil
        await readCookies()
        freshAt = Date()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === keeper, webView.url?.host?.hasSuffix("youtube.com") == true else { return }
        keeperDone?.resume()
        keeperDone = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === keeper else { return }
        keeperDone?.resume()
        keeperDone = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === keeper else { return }
        keeperDone?.resume()
        keeperDone = nil
    }
}

/** The device session's Cookie header, readable from any thread (the YouTubeMusic actor). */
final class YtmJar: @unchecked Sendable {
    static let shared = YtmJar()
    private let lock = NSLock()
    private var _header = ""

    var header: String {
        lock.lock(); defer { lock.unlock() }
        return _header
    }

    func set(_ header: String) {
        lock.lock(); _header = header; lock.unlock()
    }
}
