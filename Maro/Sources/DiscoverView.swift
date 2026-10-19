import SwiftUI

/**
 * Discover: Discover Weekly from Spotify and YouTube Music, radio (from the
 * song playing, the songs played lately, and both services' stations), and
 * the other mixes made for the account. Rows of cards that scroll sideways;
 * a card opens its songs like a playlist.
 */
struct DiscoverView: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        if let item = state.discoverOpen {
            DiscoverDetail(item: item, state: state, vm: vm).id(item.id)
        } else {
            page
        }
    }

    private var page: some View {
        let sections = state.discover.filter { !$0.items.isEmpty || $0.key == "radio" }
        let now = state.displayState().track
        let shown = sections.reduce(0) { $0 + $1.items.count }
        return VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                if state.discoverBusy {
                    OmpSpinner(size: Omp.TypeSize.bodySmall, color: Omp.muted).padding(.horizontal, m.pt(8))
                } else {
                    OmpButton(icon: Omp.Icons.refresh, vertical: 4, horizontal: 6) { vm.loadDiscover(force: true) }
                }
            }
            .padding(.horizontal, m.pt(4))
            if shown == 0 && now == nil {
                if state.discoverBusy {
                    OmpSpinner(size: Omp.TypeSize.body, color: Omp.muted).frame(maxWidth: .infinity).frame(height: m.pt(54))
                    Spacer(minLength: 0)
                } else {
                    OmpText(state.services.isEmpty
                            ? "Sign in to Spotify or YouTube Music in Settings to see Discover Weekly, your mixes and radio."
                            : "Nothing here yet. Tap refresh to read Discover again.",
                            size: Omp.TypeSize.bodySmall, color: Omp.muted, maxLines: 3)
                        .padding(m.pt(4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.key) { sec in
                            let playing = sec.key == "radio" ? now : nil
                            let items = sec.items.filter { item in
                                // The song playing has its own card first.
                                guard let playing else { return true }
                                return !playing.trackIds.contains { item.id.hasSuffix(":radio:" + $0) }
                            }
                            if !items.isEmpty || playing != nil {
                                OmpText(sec.title.uppercased(), size: Omp.TypeSize.caption, color: Omp.accent, bold: true)
                                    .padding(.horizontal, m.pt(4))
                                    .padding(.top, m.pt(10))
                                    .padding(.bottom, m.pt(6))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: m.pt(10)) {
                                        if let playing { NowRadioCard(track: playing, vm: vm) }
                                        ForEach(items, id: \.id) { item in
                                            DiscoverCard(item: item, big: sec.key == "weekly")
                                                .onTapGesture { vm.openDiscover(item) }
                                                .onLongPressGesture {
                                                    present(.menu(title: item.name, items: [
                                                        .init(icon: Omp.Icons.play, label: "Play") { vm.playDiscover(item) },
                                                        .init(icon: Omp.Icons.list, label: "Open") { vm.openDiscover(item) },
                                                    ]))
                                                }
                                        }
                                    }
                                    .padding(.horizontal, m.pt(4))
                                }
                            }
                        }
                    }
                    .padding(.bottom, m.pt(8))
                }
            }
        }
    }
}

private struct DiscoverCard: View {
    @Environment(\.omp) private var m
    let item: DiscoverItem
    let big: Bool

    var body: some View {
        let side: CGFloat = big ? 140 : 112
        VStack(alignment: .leading, spacing: m.pt(4)) {
            CoverArt(artKey: item.art.ifBlank(item.id), artUrl: item.art, icon: Omp.sourceIcon(item.service), size: side)
            OmpText(item.name, size: Omp.TypeSize.bodySmall, bold: true)
            HStack(alignment: .top, spacing: m.pt(4)) {
                OmpIcon(Omp.sourceIcon(item.service), size: Omp.TypeSize.caption, color: Omp.sourceColor(item.service))
                OmpText(item.sub, size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 2)
            }
        }
        .frame(width: m.pt(side), alignment: .leading)
        .contentShape(Rectangle())
    }
}

/** Radio from the song playing: it keeps playing and the radio follows it. */
private struct NowRadioCard: View {
    @Environment(\.omp) private var m
    let track: Track
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(4)) {
            CoverArt(track: track, icon: Omp.Icons.radio, size: 112)
            OmpText(track.title + " Radio", size: Omp.TypeSize.bodySmall, bold: true)
            HStack(alignment: .top, spacing: m.pt(4)) {
                OmpIcon(Omp.Icons.radio, size: Omp.TypeSize.caption, color: Omp.themeAccent)
                OmpText("From the song playing", size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 2)
            }
        }
        .frame(width: m.pt(112), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { vm.startRadio(track) }
    }
}

private struct DiscoverDetail: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let item: DiscoverItem
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @StateObject private var visible = VisibleRows()

    var body: some View {
        let tracks = state.discoverTracks
        let ago = Omp.agoText(Int64(state.discoverAt))
        let updated = ago.isEmpty ? "" : ago == "now" ? "  ·  updated now" : "  ·  updated \(ago) ago"
        VStack(spacing: 0) {
            HStack(spacing: m.pt(8)) {
                OmpButton(icon: Omp.Icons.back, vertical: 4, horizontal: 6) { vm.closeDiscover() }
                VStack(alignment: .leading, spacing: 0) {
                    OmpText(item.name, size: Omp.TypeSize.bodySmall, bold: true)
                    if !tracks.isEmpty {
                        OmpText("\(tracks.count) tracks" + updated,
                                size: Omp.TypeSize.caption, color: Omp.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OmpButton(icon: Omp.Icons.refresh, vertical: 4, horizontal: 6) { vm.refreshDiscoverList() }
                if !tracks.isEmpty {
                    OmpButton(icon: Omp.Icons.play, text: "Play all", fontSize: Omp.TypeSize.caption) { vm.playDiscover(item) }
                }
            }
            .padding(.horizontal, m.pt(4))
            .frame(height: m.pt(38))
            if state.discoverLoading && tracks.isEmpty {
                OmpSpinner(size: Omp.TypeSize.body, color: Omp.muted).frame(maxWidth: .infinity).frame(height: m.pt(54))
                Spacer(minLength: 0)
            } else if tracks.isEmpty {
                OmpText("Nothing in this list right now", size: Omp.TypeSize.bodySmall, color: Omp.muted)
                    .padding(m.pt(4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let current = state.displayState().currentRow(tracks)
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(
                                track: track,
                                isCurrent: index == current,
                                liked: state.isLiked(track),
                                vm: vm,
                                available: state.canPlay(track),
                                onPlay: { vm.playTrack(track, context: tracks, name: item.name, index: index) },
                                onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
                            )
                            .onAppear { visible.appear(index, tracks, vm) }
                            .onDisappear { visible.disappear(index) }
                        }
                    }
                }
            }
        }
    }
}
