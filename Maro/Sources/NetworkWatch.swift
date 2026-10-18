import Foundation
import Network

/**
 * Which network the phone is on. A connection opened on Wi-Fi is dead the
 * moment the phone walks out to 4G, yet nothing closes it: the Spotify
 * player kept waiting on its old connection and every song loaded forever.
 * A change of network is told to whoever holds such connections.
 */
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()
    private var kind = ""
    /** Called with the new kind ("wifi", "cellular", "wired", "other") when it changes. */
    var onChange: ((String, String) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: String
            if path.status != .satisfied {
                kind = "none"
            } else if path.usesInterfaceType(.wifi) {
                kind = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                kind = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = "wired"
            } else {
                kind = "other"
            }
            Task { @MainActor in self?.changed(kind) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.marobotic.maro.network"))
    }

    private func changed(_ new: String) {
        let old = kind
        kind = new
        // The first answer is where the app started, not a change; losing the
        // network is waited out until there is one again.
        if old.isEmpty || new == old || new == "none" { return }
        onChange?(old, new)
    }
}
