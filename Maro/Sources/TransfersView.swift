import SwiftUI

/**
 * The list of downloads, live (TransferList), with a four-times-a-second
 * ticker that runs only while something moves. Any thread may report: the
 * calls hop to the main actor.
 */
@MainActor
final class Transfers: ObservableObject {
    static let shared = Transfers()

    @Published private(set) var list = TransferList()
    private var ticker: Task<Void, Never>?

    func open(_ label: String, sub: String, queued: Bool, auto: Bool = false) -> Int {
        let id = list.open(label, sub: sub, queued: queued, auto: auto)
        tick()
        return id
    }

    func begin(_ id: Int) { list.begin(id); tick() }
    func progress(_ id: Int, done: Int64, total: Int64) { list.progress(id, done: done, total: total) }
    func finish(_ id: Int) { list.finish(id, now: uptime()); tick() }
    func fail(_ id: Int, _ why: String) { list.fail(id, why) }
    func drop(_ id: Int) { list.drop(id) }
    func clear() { list.clear() }

    private func tick() {
        if ticker != nil { return }
        ticker = Task { [weak self] in
            var last = uptime()
            while let self, !Task.isCancelled {
                await sleep(seconds: 0.25)
                let now = uptime()
                self.list.tick(dt: now - last, now: now)
                last = now
                // Finished automatic rows still to linger keep it going a little.
                if !self.list.moving && !self.list.items.contains(where: { $0.auto && $0.state == .done }) {
                    self.ticker = nil
                    return
                }
            }
        }
    }
}

/** The download of one stored copy, told to `Transfers` as its bytes arrive. */
final class TransferWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock(); self.task = task; lock.unlock()
    }

    /** (received, expected) so far; expected is 0 while the server hasn't said. */
    var bytes: (Int64, Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let task else { return (0, 0) }
        return (task.countOfBytesReceived, max(0, task.countOfBytesExpectedToReceive))
    }
}

/**
 * The Transfers tab (the desktop's): what is downloading, its size, a bar,
 * the speed and its state, the overall line on top while anything moves, and
 * Clear for the finished rows. Shown only while it has rows.
 */
struct TransfersView: View {
    @ObservedObject private var transfers = Transfers.shared

    var body: some View {
        let list = transfers.list
        let items = list.items
        let live = items.filter(\.live)
        let finished = items.count - live.count
        VStack(spacing: 0) {
            TabHead(text: live.isEmpty ? "\(finished) finished" : "Transferring") {
                if finished > 0 { MButton("Clear", kind: .ghost) { withAnimation(.easeOut(duration: 0.2)) { transfers.clear() } } }
            }
            .padding(.horizontal, 8)
            if !live.isEmpty {
                let t = list.totals
                let pct = t.total > 0 ? min(100, Int((Double(t.done) / Double(t.total) * 100).rounded())) : 0
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        OmpText("\(TransferList.size(t.done)) of \(TransferList.size(t.total))  \u{B7}  \(pct)%  \u{B7}  \(t.left) \(t.left == 1 ? "item" : "items") left",
                                size: 11.5, color: Omp.t2)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        if t.speed > 0 { OmpText(TransferList.rate(t.speed), size: 11.5, color: Omp.foreground).monospacedDigit() }
                    }
                    TransferBar(fraction: t.total > 0 ? Double(t.done) / Double(t.total) : 0, color: Omp.themeAccent)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Omp.line).frame(height: 1) }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { TransferRow(item: $0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        let failed = item.state == .failed, done = item.state == .done
        let word: String = {
            switch item.state {
            case .queued: return "Queued"
            case .active: return "Downloading"
            case .done: return "Done"
            case .failed: return "Failed"
            }
        }()
        let left = failed ? item.reason.ifEmpty("it did not finish")
            : item.state == .queued ? "Waiting"
            : item.total > 0 ? "\(TransferList.size(item.done)) of \(TransferList.size(item.total))" : TransferList.size(item.done)
        let right = item.state == .active && item.speed > 0 ? TransferList.rate(item.speed) : done ? TransferList.size(item.total) : ""
        let tint = done ? Omp.qualityGood : failed ? Color(hex: 0xE5534B) : Omp.themeAccent
        HStack(alignment: .top, spacing: 10) {
            OmpText("\u{2193}", size: 14, color: Omp.t2).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        OmpText(item.label, size: 13, color: Omp.foreground, bold: true).layoutPriority(1)
                        if !item.sub.isEmpty { OmpText(item.sub, size: 12, color: Omp.t2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    OmpText(word, size: 12, color: done ? Omp.qualityGood : failed ? Omp.danger : Omp.t2).monospacedDigit()
                }
                HStack(spacing: 12) {
                    OmpText(left, size: 11.5, color: failed ? Omp.danger : Omp.t2).monospacedDigit()
                    Spacer(minLength: 0)
                    if !right.isEmpty { OmpText(right, size: 11.5, color: Omp.t2).monospacedDigit() }
                }
                TransferBar(fraction: item.fraction, color: tint, unknown: item.state == .active && item.total == 0)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, 4)
        .opacity(item.state == .queued ? 0.55 : 1)
        .overlay(alignment: .bottom) { Rectangle().fill(Omp.line).frame(height: 1) }
    }
}

/** The 3 pt bar: a track and its fill; a size not known yet slides a block across. */
private struct TransferBar: View {
    let fraction: Double
    let color: Color
    var unknown = false
    @State private var slide = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Omp.foreground.opacity(0.08))
                if unknown {
                    Rectangle().fill(color).frame(width: w * 0.3)
                        .offset(x: slide ? w : -w * 0.3)
                        .onAppear {
                            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { slide = true }
                        }
                } else {
                    Rectangle().fill(color).frame(width: w * min(max(fraction, 0), 1))
                        .animation(.linear(duration: 0.25), value: fraction)
                }
            }
            .clipped()
        }
        .frame(height: 3)
    }
}
