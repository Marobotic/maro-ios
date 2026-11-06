import CommonCrypto
import CryptoKit
import SwiftUI
import WebKit

/**
 * Signing in to a music service on this phone, on the service's own page in a
 * private web view - the desktop's sidecar/signin_window.py, same pages, same
 * proof of a finished sign-in, same session shapes. The result goes onto the
 * account (ServiceSessions.publish), where every client takes it.
 *
 *   YouTube Music: Google's sign-in in this phone's own persistent store (YtmDevice),
 *                  done at YouTube's SAPISID cookie; the session never leaves the phone.
 *   SoundCloud:    soundcloud.com/signin, done at its oauth_token cookie.
 *   Spotify:       Spotify's authorize page (PKCE, the desktop helper's client
 *                  and loopback address); the code is caught as the page heads
 *                  for 127.0.0.1, and the token goes to the Spotify player,
 *                  which turns it into a stored login.
 */
@MainActor
final class ServiceSignIn: NSObject, ObservableObject, WKNavigationDelegate, Identifiable {
    enum Outcome {
        case session(JSON)          // soundcloud: the payload for the account
        case device                 // ytm: signed in, in this phone's own store (YtmDevice)
        case spotifyToken(String)   // spotify: an access token for the player
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let service: String
    let title: String
    let webView: WKWebView
    @Published var status = ""
    private let onDone: (Outcome) -> Void
    private var finished = false
    private var poll: Task<Void, Never>?
    private var verifier = ""

    // The desktop helper's Spotify app and the loopback it registered.
    static let spotifyClient = "65b708073fc0480ea92a077233ca87bd"
    static let spotifyRedirect = "http://127.0.0.1:8898/login"
    static let spotifyScopes = ["streaming", "user-read-private", "user-read-email", "user-library-read",
                                "user-library-modify", "playlist-read-private", "playlist-read-collaborative",
                                "user-follow-read"]
    // Safari's own name, as a fallback only: the real one comes from the web
    // view itself (see safari(from:)).
    static let safariFallback = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /**
     * The web view's own name, turned into Safari's.
     *
     * Google refuses a sign-in whose user agent disagrees with what WebKit
     * says it is, so the fixed "iOS 18" string became a lie on any newer phone
     * and the sign-in came back 403. The default UA already names the real OS
     * and WebKit build; Safari's own name is that plus a "Version/<ios>"
     * before the "Mobile/15E148 Safari/604.1" tail.
     */
    static func safari(from ua: String) -> String {
        var out = ua.trimmingCharacters(in: .whitespaces)
        guard !out.contains("Safari/") else { return out }
        var version = "18.0"
        if let r = out.range(of: #"OS \d+(?:_\d+)*"#, options: .regularExpression) {
            version = String(out[r]).replacingOccurrences(of: "OS ", with: "")
                .replacingOccurrences(of: "_", with: ".")
        }
        let tail = "Version/\(version) Mobile/15E148 Safari/604.1"
        if out.contains("Mobile/15E148") {
            out = out.replacingOccurrences(of: "Mobile/15E148", with: tail)
        } else {
            out += " " + tail
        }
        return out
    }

    /** Google's wording for a browser it will not sign in from, in its 403 page. */
    static func refusedSignIn(_ pageText: String) -> Bool {
        let t = pageText.lowercased()
        return t.contains("disallowed_useragent") || t.contains("couldn't sign you in")
            || t.contains("couldn’t sign you in") || t.contains("browser or app may not be secure")
    }

    init(service: String, onDone: @escaping (Outcome) -> Void) {
        self.service = service
        self.onDone = onDone
        title = service == "spotify" ? "Sign in to Spotify" : service == "ytm" ? "Sign in to YouTube Music" : "Sign in to SoundCloud"
        let config = WKWebViewConfiguration()
        // YouTube Music signs in inside this phone's own persistent store, where
        // the session stays (round 2 H); the others in a fresh private one.
        config.websiteDataStore = service == "ytm" ? YtmDevice.shared.store : .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        // The web view's own name first (it answers on the blank page), then
        // the service's page with that name corrected: a promise to be Safari
        // has to match what WebKit tells Google it is, or the sign-in is
        // refused with 403.
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            guard let self else { return }
            if let real = value as? String, real.contains("AppleWebKit") {
                self.webView.customUserAgent = Self.safari(from: real)
            } else {
                self.webView.customUserAgent = Self.safariFallback
            }
            // The keeper visits YouTube Music under the same name the session was made with.
            if self.service == "ytm" { UserDefaults.standard.set(self.webView.customUserAgent, forKey: "ytmUserAgent") }
            self.load()
        }
    }

    private func load() {
        let url: URL
        switch service {
        case "spotify":
            verifier = Self.randomVerifier()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
            c.queryItems = [
                .init(name: "response_type", value: "code"),
                .init(name: "client_id", value: Self.spotifyClient),
                .init(name: "redirect_uri", value: Self.spotifyRedirect),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "scope", value: Self.spotifyScopes.joined(separator: " ")),
            ]
            url = c.url!
        case "ytm":
            url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!
        default:
            url = URL(string: "https://soundcloud.com/signin")!
        }
        webView.load(URLRequest(url: url))
        if service != "spotify" {
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, !self.finished else { return }
                    await self.checkCookies()
                }
            }
        }
    }

    func cancel() { finish(.cancelled) }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        poll?.cancel()
        webView.stopLoading()
        onDone(outcome)
    }

    // -- YouTube Music and SoundCloud: the cookies say when it is done ------

    private func checkCookies() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = webView.url?.host ?? ""
        if service == "ytm" {
            let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
            let names = Set(yt.map(\.name))
            guard names.contains("SAPISID") || names.contains("__Secure-3PAPISID"), host.hasSuffix("youtube.com") else { return }
            // The session stays in this phone's store; nothing is exported.
            status = "Signed in on this phone"
            finish(.device)
        } else {
            guard let token = cookies.first(where: { $0.name == "oauth_token" && $0.domain.hasSuffix("soundcloud.com") })?.value,
                  !token.isEmpty else { return }
            status = "Signed in - saving it to your account"
            finished = true
            poll?.cancel()
            // The desktop's shape: {"token", "user": {"id", "name"}}, the user
            // read from SoundCloud with that token.
            let user = await SoundCloud.shared.me(token: token)
            guard let user else { return onDone(.failed("SoundCloud did not accept that sign-in - try again")) }
            onDone(.session(["token": token, "user": user]))
        }
    }

    // -- Google's refusals, said in Jukebox's own words ----------------------

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard service != "spotify" else { return }
        webView.evaluateJavaScript("(document.body && document.body.innerText || '').slice(0, 4000)") { [weak self] value, _ in
            guard let self, let text = value as? String, self.status.isEmpty else { return }
            if Self.refusedSignIn(text) {
                self.status = "Google refused the sign-in from inside the app. " +
                    "Update iOS, then try again, or sign in on another device and it will reach this phone."
            }
        }
    }

    // -- Spotify: catch the code on its way to the loopback ------------------

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard service == "spotify", let url = action.request.url, url.absoluteString.hasPrefix(Self.spotifyRedirect) else {
            return .allow
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            finish(.failed(items.first { $0.name == "error" }?.value ?? "Spotify sign-in was not finished"))
            return .cancel
        }
        status = "Signed in - saving it to your account"
        let verifier = verifier
        Task { @MainActor in
            if let token = await Self.spotifyToken(code: code, verifier: verifier) {
                finish(.spotifyToken(token))
            } else {
                finish(.failed("Spotify did not accept that sign-in - try again"))
            }
        }
        return .cancel
    }

    private static func spotifyToken(code: String, verifier: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: spotifyRedirect),
            .init(name: "client_id", value: spotifyClient),
            .init(name: "code_verifier", value: verifier),
        ]
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let body = JSONText.parse(data) as? JSON else { return nil }
        let token = body.str("access_token")
        return token.isEmpty ? nil : token
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/** The sign-in page, full screen, with a way out. */
struct ServiceSignInSheet: View {
    @ObservedObject var signIn: ServiceSignIn

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                OmpText(signIn.title, size: Omp.TypeSize.bodySmall, bold: true)
                Spacer(minLength: 0)
                OmpButton(text: "Cancel") { signIn.cancel() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !signIn.status.isEmpty {
                OmpText(signIn.status, size: Omp.TypeSize.caption, color: Omp.muted)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            WebViewHost(webView: signIn.webView)
        }
        .background(Omp.card)
        .onAppear { signIn.start() }
    }
}

private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
