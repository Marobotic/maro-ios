import SwiftUI

/**
 * Discover as the desktop's phone layout draws it: "Made for you" and the
 * refresh, then each section (Discover Weekly, radio from the song playing and
 * the songs played lately, the stations and mixes) as a grid of square tiles.
 * A tile opens its songs; holding it offers Play.
 */
struct DiscoverView: View {
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
        let services = [state.services.contains(ServiceSessions.librespot) || state.spotifyConnected ? "Spotify" : "",
                        state.services.contains(ServiceSessions.ytm) || state.ytmConnected ? "YouTube Music" : ""]
            .filter { !$0.isEmpty }
        return VStack(spacing: 0) {
            TabHead(text: (["Made for you"] + services).joined(separator: " · ")) {
                if state.discoverBusy {
                    OmpSpinner(size: 14, color: Omp.themeAccent).frame(width: 32, height: 32)
                } else {
                    MButton("", icon: .refreshAlt, iconColor: Omp.foreground, kind: .ghost) { vm.loadDiscover(force: true) }
                }
            }
            if shown == 0 && now == nil {
                if state.discoverBusy {
                    LoadingNote()
                } else {
                    EmptyNote(message: services.isEmpty
                              ? "Sign in to Spotify or YouTube Music in Settings to see Discover Weekly, your mixes and radio."
                              : "Nothing here yet. Press refresh to read Discover again.")
                }
            } else {
                GeometryReader { geo in
                    let columns = max(1, Int((geo.size.width + 10) / (96 + 10)))
                    let side = (geo.size.width - CGFloat(columns - 1) * 10) / CGFloat(columns)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(sections.enumerated()), id: \.element.key) { at, sec in
                                let playing = sec.key == "radio" ? now : nil
                                let items = sec.items.filter { item in
                                    // The song playing has its own tile first.
                                    guard let playing else { return true }
                                    return !playing.trackIds.contains { item.id.hasSuffix(":radio:" + $0) }
                                }
                                if !items.isEmpty || playing != nil {
                                    OmpText(sec.title, size: 12, color: Omp.foreground, bold: true)
                                        .padding(.top, at == 0 ? 4 : 22)
                                        .padding(.bottom, 12)
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 10, alignment: .top), count: columns),
                                              alignment: .leading, spacing: 12) {
                                        if let playing { NowRadioTile(track: playing, side: side, vm: vm) }
                                        ForEach(items, id: \.id) { item in
                                            DiscoverTile(item: item, side: side, active: state.displayState().queueName == item.name)
                                                .onTapGesture { vm.openDiscover(item) }
                                                .onLongPressGesture {
                                                    present(.menu(title: item.name, items: [
                                                        .init(icon: .playSmall, label: "Play") { vm.playDiscover(item) },
                                                        .init(icon: .addQueue, label: "Open") { vm.openDiscover(item) },
                                                    ]))
                                                }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .padding(.top, 2)
    }
}

/** A square tile: the cover, the accent outline and Play square when it is what plays, the name. */
private struct DiscoverTile: View {
    let item: DiscoverItem
    let side: CGFloat
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArt(artKey: item.art.ifBlank(item.id), artUrl: item.art, icon: Omp.sourceGlyph(item.service), size: side)
                .overlay { if active { Rectangle().strokeBorder(Omp.themeAccent, lineWidth: 1) } }
                .overlay(alignment: .bottomTrailing) {
                    if active {
                        EqBars(color: .white)
                            .frame(width: 36, height: 36)
                            .background(Omp.themeAccent)
                            .padding(8)
                    }
                }
                .padding(.bottom, 6)
            OmpText(item.name, size: 11.5, color: Omp.foreground, bold: true)
        }
        .frame(width: side, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/** Radio from the song playing: it keeps playing and the radio follows it. */
private struct NowRadioTile: View {
    let track: Track
    let side: CGFloat
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArt(track: track, icon: .radio, size: side)
                .padding(.bottom, 6)
            OmpText(track.title + " Radio", size: 11.5, color: Omp.foreground, bold: true)
        }
        .frame(width: side, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { vm.startRadio(track) }
    }
}

/** An opened list: back, its name and count, Play all and refresh, then its songs. */
private struct DiscoverDetail: View {
    @Environment(\.presentDialog) private var present
    let item: DiscoverItem
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @StateObject private var visible = VisibleRows()

    var body: some View {
        let tracks = state.discoverTracks
        let shown = state.displayState()
        let ago = Omp.agoText(Int64(state.discoverAt))
        let updated = ago.isEmpty ? "" : ago == "now" ? " · updated now" : " · updated \(ago) ago"
        let count = tracks.isEmpty ? "" : " · \(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MButton("Discover", icon: .back, kind: .ghost) { vm.closeDiscover() }
                    .padding(.leading, -8)
                OmpText(item.name + count + updated, size: 12, color: Omp.t2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !tracks.isEmpty {
                    MButton("Play all", icon: .playSmall, iconSize: 12, kind: .primary) { vm.playDiscover(item) }
                }
                MButton("", icon: .refreshAlt, iconColor: Omp.foreground, kind: .ghost) { vm.refreshDiscoverList() }
            }
            .frame(minHeight: 36)
            .padding(.top, 2)
            if state.discoverLoading && tracks.isEmpty {
                LoadingNote()
            } else if tracks.isEmpty {
                EmptyNote(message: "Nothing in this list right now.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let current = shown.currentRow(tracks)
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            SongRow(
                                index: index,
                                track: track,
                                isCurrent: index == current,
                                playing: shown.playing,
                                liked: state.isLiked(track),
                                vm: vm,
                                available: state.canPlay(track),
                                loading: !shown.loadingKey.isEmpty,
                                onPlay: { vm.playTrack(track, context: tracks, name: item.name, index: index) },
                                onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm, present: present)) }
                            )
                            .onAppear { visible.appear(index, tracks, vm) }
                            .onDisappear { visible.disappear(index) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
