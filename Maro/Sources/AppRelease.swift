import Foundation

/** Bundle metadata and the banner-only iOS release advertised by the website. */
struct AppRelease {
    let version: String
    let build: Int

    static let installed = AppRelease(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
        build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    )

    var displayVersion: String { "\(version) (\(build))" }

    func update(from data: Data) throws -> IOSRelease? {
        let release = try JSONDecoder().decode(ReleaseManifest.self, from: data).ios
        guard let release, release.build > build, !release.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return release
    }
}

private struct ReleaseManifest: Decodable {
    let ios: IOSRelease?
}

struct IOSRelease: Decodable, Equatable {
    let version: String
    let build: Int

    var banner: String { "Jukebox \(version) is available - install it from your PC" }

    private enum CodingKeys: String, CodingKey { case version, build }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        // Bundle builds and website generators may encode this as a string.
        if let number = try? values.decode(Int.self, forKey: .build) {
            build = number
        } else {
            let text = try values.decode(String.self, forKey: .build)
            guard let number = Int(text) else {
                throw DecodingError.dataCorruptedError(forKey: .build, in: values, debugDescription: "Invalid iOS build")
            }
            build = number
        }
    }
}
