import SwiftUI

/**
 * Spotify-style lyrics: the sung line bright, sung lines dimmed, the next ones
 * muted, the view gliding to keep the sung line a third of the way down.
 * Scrolling by hand pauses that for a few seconds; tapping a line seeks to it.
 */
struct LyricsView: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @State private var pausedUntil: Double = 0
    @State private var placed = false

    var body: some View {
        let lyrics = vm.lyrics
        let message = state.track == nil ? "Nothing playing"
            : lyrics.loading ? "Looking for lyrics…"
            : lyrics.lines.isEmpty ? "No lyrics found for this song" : ""
        if !message.isEmpty {
            OmpText(message, color: Omp.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let progress = vm.progress
            TimelineView(.periodic(from: .now, by: progress.playing ? 0.2 : 3600)) { _ in
                // A quarter second of lead, so the highlight lands with the voice.
                let current = lyrics.indexAt(progress.at(uptime()) + 0.25)
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lyrics.lines.indices, id: \.self) { index in
                                    line(lyrics, index, current)
                                }
                                if !lyrics.source.isEmpty {
                                    OmpText((lyrics.synced ? "Synced lyrics" : "Lyrics") + " from " + lyrics.source, size: Omp.TypeSize.caption, color: Omp.muted)
                                        .padding(.horizontal, m.pt(6))
                                        .padding(.vertical, m.pt(12))
                                }
                            }
                            .padding(.top, m.pt(8))
                            .padding(.bottom, geo.size.height * 0.5)
                        }
                        // A drag this view did not start is the user's: stop
                        // following for a few seconds, as Spotify does.
                        .simultaneousGesture(DragGesture().onChanged { _ in pausedUntil = uptime() + 3.5 })
                        .onChange(of: current) { follow(proxy, current, animated: placed) }
                        .onAppear { follow(proxy, current, animated: false) }
                        .onChange(of: lyrics.trackId) { placed = false }
                    }
                }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy, _ current: Int, animated: Bool) {
        guard current >= 0, uptime() >= pausedUntil else { return }
        let anchor = UnitPoint(x: 0, y: 0.3)
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(current, anchor: anchor) }
        } else {
            proxy.scrollTo(current, anchor: anchor)
        }
        placed = true
    }

    private func line(_ lyrics: SongLyrics, _ index: Int, _ current: Int) -> some View {
        let item = lyrics.lines[index]
        let relation = lyrics.synced ? (index < current ? -1 : index > current ? 1 : 0) : 0
        let color: Color = !lyrics.synced || relation == 0 ? Omp.foreground : relation < 0 ? Omp.foreground.opacity(0.32) : Omp.foreground.opacity(0.55)
        return Text(item.text.isEmpty && lyrics.synced ? "♪" : item.text)
            .font(Omp.font(m.pt(lyrics.synced ? 19 : Omp.TypeSize.body), bold: lyrics.synced && relation == 0))
            .foregroundColor(color)
            .lineSpacing(m.pt(lyrics.synced ? 7 : 6))
            .animation(.easeInOut(duration: 0.25), value: relation)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, m.pt(6))
            .padding(.vertical, m.pt(lyrics.synced ? 7 : 2))
            .contentShape(Rectangle())
            .onTapGesture {
                guard lyrics.synced, item.t >= 0 else { return }
                pausedUntil = 0
                vm.seek(item.t)
            }
            .id(index)
    }
}
