import Combine
import Foundation

struct ConsoleEntry: Identifiable {
    let id = UUID()
    let time: String
    let tag: String
    let message: String

    var line: String { "\(time)  \(tag)  \(message)" }
}

/** In-memory diagnostic ring buffer. Request bodies and credentials are never stored. */
final class ConsoleLog: ObservableObject {
    static let shared = ConsoleLog()
    private static let capacity = 500

    @Published private(set) var entries: [ConsoleEntry] = []
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private var stored: [ConsoleEntry] = []

    private init() {}

    func log(_ tag: String, _ message: String) {
        lock.lock()
        let entry = ConsoleEntry(
            time: formatter.string(from: Date()),
            tag: tag,
            message: message.replacingOccurrences(of: "\n", with: " ")
        )
        stored.append(entry)
        if stored.count > Self.capacity { stored.removeFirst(stored.count - Self.capacity) }
        let snapshot = stored
        DispatchQueue.main.async { [weak self] in self?.entries = snapshot }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        stored.removeAll(keepingCapacity: true)
        DispatchQueue.main.async { [weak self] in self?.entries = [] }
        lock.unlock()
    }
}
