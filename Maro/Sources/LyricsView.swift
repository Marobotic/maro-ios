import SwiftUI

/**
 * The lyrics tab as the desktop draws it: big bold lines, the sung one white
 * and the others greyer and smaller the further they are, the view gliding to
 * keep the sung line a little above the middle. Scrolling by hand stops that;
 * following comes back 3 s after the last scroll while the song plays. Tapping
 * a line seeks to it. Under it: where the lyrics are from, and Full screen.
 */
struct LyricsView: View {
    @Environment(\.openJam) private var openJam
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let lyrics = vm.lyrics
        let message = state.track == nil ? "Nothing playing"
            : lyrics.loading ? "Looking for lyrics…"
            : lyrics.lines.isEmpty ? "No lyrics found for this song" : ""
        VStack(spacing: 0) {
            ZStack {
                if message.isEmpty {
                    if lyrics.synced {
                        LyricLines(lyrics: lyrics, vm: vm)
                    } else {
                        PlainLyrics(lyrics: lyrics)
                    }
                } else {
                    OmpText(message, size: 13, color: Omp.t2, maxLines: 3, align: .center)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                OmpText(message.isEmpty && !lyrics.source.isEmpty
                        ? (lyrics.synced ? "Synced lyrics" : "Lyrics") + " from " + lyrics.source : "",
                        size: 10.5, color: Omp.t3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MButton("Full screen", icon: .expand, iconSize: 12, kind: .ghost, enabled: state.track != nil) { openJam() }
            }
            .padding(.leading, 20)
            .padding(.trailing, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }
}

/** Lyrics without times: plain text from the top, scrolled by hand. */
private struct PlainLyrics: View {
    let lyrics: SongLyrics

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lyrics.lines.indices, id: \.self) { i in
                    Text(lyrics.lines[i].text)
                        .font(Omp.font(17))
                        .foregroundColor(Omp.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
    }
}

/**
 * Synced lines, shared by the tab and the full-screen view: each line at
 * least `minLine` tall, the sung one at `anchor` of the height, the edges
 * fading out (the desktop's mask).
 */
struct LyricLines: View {
    let lyrics: SongLyrics
    @ObservedObject var vm: MaroViewModel
    var size: CGFloat = 20
    var minLine: CGFloat = 60
    var inset: CGFloat = 20
    var anchor: CGFloat = 0.36
    var fadeTop: CGFloat = 0.14
    var fadeBottom: CGFloat = 0.82
    @State private var free = false
    @State private var lastScroll: Double = 0
    @State private var placed = false
    @State private var resume: Task<Void, Never>? = nil

    var body: some View {
        let progress = vm.progress
        TimelineView(.periodic(from: .now, by: progress.playing ? 0.2 : 3600)) { _ in
            // A quarter second of lead, so the highlight lands with the voice.
            let current = lyrics.indexAt(progress.at(uptime()) + 0.25)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lyrics.lines.indices, id: \.self) { index in
                                line(index, current)
                            }
                        }
                        .padding(.horizontal, inset)
                        .padding(.top, geo.size.height * anchor)
                        .padding(.bottom, geo.size.height * (1 - anchor))
                    }
                    .scrollIndicators(.hidden)
                    // A drag this view did not start is the user's: stop
                    // following until 3 s after the last one, while playing.
                    .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in
                        free = true
                        lastScroll = uptime()
                        scheduleResume(proxy)
                    })
                    .onChange(of: current) { follow(proxy, current, animated: placed) }
                    .onAppear { follow(proxy, current, animated: false) }
                    .onChange(of: lyrics.trackId) {
                        placed = false
                        free = false
                    }
                    .onDisappear { resume?.cancel() }
                }
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fadeTop),
                    .init(color: .black, location: fadeBottom),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private func scheduleResume(_ proxy: ScrollViewProxy) {
        resume?.cancel()
        let model = self.vm
        let words = self.lyrics
        resume = Task { @MainActor in
            while !Task.isCancelled {
                await sleep(seconds: 0.5)
                if Task.isCancelled { return }
                // Paused: the clock only starts once it plays again.
                if !model.progress.playing { lastScroll = uptime() }
                if uptime() - lastScroll >= 3 {
                    free = false
                    let now = words.indexAt(model.progress.at(uptime()) + 0.25)
                    follow(proxy, now, animated: true)
                    return
                }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy, _ current: Int, animated: Bool) {
        guard !free else { return }
        let target = max(current, 0)
        guard lyrics.lines.indices.contains(target) else { return }
        let point = UnitPoint(x: 0, y: anchor)
        if animated {
            withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.7)) { proxy.scrollTo(target, anchor: point) }
        } else {
            proxy.scrollTo(target, anchor: point)
        }
        placed = true
    }

    @ViewBuilder
    private func line(_ index: Int, _ current: Int) -> some View {
        let item = lyrics.lines[index]
        let active = index == current
        let dist = abs(index - max(0, current))
        let opacity = active ? 1 : max(0.12, 0.52 - Double(dist) * 0.105)
        let scale = active ? 1 : max(0.84, 1 - CGFloat(dist) * 0.025)
        Group {
            if item.text.trimmingCharacters(in: .whitespaces).isEmpty {
                GapDots(size: size >= 24 ? 12 : 9)
                    .frame(maxWidth: .infinity, minHeight: minLine, alignment: .leading)
            } else {
                Text(item.text)
                    .font(Omp.font(size, bold: true))
                    .foregroundColor(active ? .white : Omp.foreground.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, minHeight: minLine, alignment: .topLeading)
            }
        }
        .opacity(opacity)
        .scaleEffect(scale, anchor: .leading)
        .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.55), value: current)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.t >= 0 else { return }
            resume?.cancel()
            free = false
            vm.seek(item.t)
        }
        .id(index)
    }
}

/** An instrumental gap: three small squares pulsing in turn. */
private struct GapDots: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: size) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t - Double(i) * 0.2).truncatingRemainder(dividingBy: 1.4) / 1.4
                    let wave = 0.5 - 0.5 * cos(phase * 2 * Double.pi)
                    Rectangle()
                        .fill(Color.white.opacity(0.4 + 0.6 * wave))
                        .frame(width: size, height: size)
                        .scaleEffect(0.7 + 0.5 * wave)
                }
            }
        }
    }
}
