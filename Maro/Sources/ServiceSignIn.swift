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
 *   YouTube Music: Google's sign-in, done when YouTube's SAPISID cookie is set
 *                  and the page is back on youtube.com.
 *   SoundCloud:    soundcloud.com/signin, done at its oauth_token cookie.
 *   Spotify:       Spotify's authorize page (PKCE, the desktop helper's client
 *                  and loopback address); the code is caught as the page heads
 *                  for 127.0.0.1, and the token goes to the Spotify player,
 *                  which turns it into a stored login.
 */
@MainActor
final class ServiceSignIn: NSObject, ObservableObject, WKNavigationDelegate, Identifiable {
    enum Outcome {
        case session(JSON)          // ytm / soundcloud: the payload for the account
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
    // Safari's own name: Google turns away sign-ins from anything that says
    // it is an embedded web view.
    static let safari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    init(service: String, onDone: @escaping (Outcome) -> Void) {
        self.service = service
        self.onDone = onDone
        title = service == "spotify" ? "Sign in to Spotify" : service == "ytm" ? "Sign in to YouTube Music" : "Sign in to SoundCloud"
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()      // a fresh sign-in, nobody else's cookies
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safari
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
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
            status = "Signed in - saving it to your account"
            finish(.session(Self.youtubeSession(yt)))
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

    /**
     * The desktop's YouTube Music session: ytmusicapi's browser headers (the
     * cookie header and a SAPISIDHASH) and the same cookies as the Netscape
     * file yt-dlp reads.
     */
    static func youtubeSession(_ cookies: [HTTPCookie]) -> JSON {
        let origin = "https://music.youtube.com"
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let sapisid = cookies.first { $0.name == "SAPISID" }?.value
            ?? cookies.first { $0.name == "__Secure-3PAPISID" }?.value ?? ""
        let ts = Int(Date().timeIntervalSince1970)
        let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
        let headers: JSON = [
            "accept": "*/*",
            "accept-encoding": "gzip, deflate",
            "accept-language": "en-US,en;q=0.5",
            "authorization": "SAPISIDHASH \(ts)_\(hash)",
            "content-encoding": "gzip",
            "content-type": "application/json",
            "cookie": header,
            "origin": origin,
            "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
            "x-goog-authuser": "0",
        ]
        var lines = ["# Netscape HTTP Cookie File", ""]
        for c in cookies {
            let domain = c.domain.hasPrefix(".") ? c.domain : "." + c.domain
            let expires = Int(c.expiresDate?.timeIntervalSince1970 ?? 0)
            lines.append([domain, "TRUE", c.path.isEmpty ? "/" : c.path, c.isSecure ? "TRUE" : "FALSE",
                          "\(expires)", c.name, c.value].joined(separator: "\t"))
        }
        return ["headers": headers, "cookies": lines.joined(separator: "\n") + "\n", "oauth": NSNull()]
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
