import Combine
import Foundation

/** Only checks release metadata. Sideloaded apps are installed from the PC. */
@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var available: IOSRelease?
    private static let interval: TimeInterval = 30 * 60
    private var checkedAt: Date?
    private var checking = false
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func monitor() async {
        while !Task.isCancelled {
            await checkIfDue()
            let age = checkedAt.map { Date().timeIntervalSince($0) } ?? 0
            let delay = max(1, Self.interval - age)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
        }
    }

    func checkIfDue() async {
        guard !checking, checkedAt.map({ Date().timeIntervalSince($0) >= Self.interval }) ?? true else { return }
        checking = true
        checkedAt = Date()
        defer { checking = false }
        do {
            let request = URLRequest(url: URL(string: "https://marobotic.dev/apps/jukebox/latest.json")!,
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await http.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return }
            available = try AppRelease.installed.update(from: data)
        } catch {
            // An unreachable or malformed manifest must never interrupt listening.
        }
    }
}
