import SwiftUI

struct ViewArea: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let queueJump: Int

    var body: some View {
        switch state.view {
        case Sync.viewLyrics: LyricsView(state: state, vm: vm)
        case Sync.viewPlaylists: PlaylistsView(state: state, vm: vm)
        case Sync.viewSongs: SongsView(state: state, vm: vm)
        case Sync.viewRecent: RecentView(state: state, vm: vm)
        case Sync.viewSearch: SearchView(state: state, vm: vm)
        default: QueueView(state: state, vm: vm, jump: queueJump)
        }
    }
}

private struct Empty: View {
    @Environment(\.omp) private var m
    let message: String

    var body: some View {
        OmpText(message, size: Omp.TypeSize.bodySmall, color: Omp.muted, maxLines: 3)
            .padding(m.pt(4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/**
 * When the list comes to rest, hand the songs on screen to the view model so
 * their first seconds are on the phone before a tap.
 */
@MainActor
final class VisibleRows: ObservableObject {
    private var shown = Set<Int>()
    private var settle: Task<Void, Never>?

    func appear(_ i: Int, _ tracks: [Track], _ vm: MaroViewModel) {
        shown.insert(i)
        schedule(tracks, vm)
    }

    func disappear(_ i: Int) { shown.remove(i) }

    private func schedule(_ tracks: [Track], _ vm: MaroViewModel) {
        settle?.cancel()
        settle = Task { [weak self] in
            await sleep(seconds: 0.35)
            guard let self, !Task.isCancelled else { return }
            let visible = self.shown.sorted().compactMap { tracks[safe: $0] }
            if !visible.isEmpty { vm.prefetchVisible(visible) }
        }
    }
}

@MainActor
private func trackMenu(_ track: Track, liked: Bool, vm: MaroViewModel) -> OmpDialog {
    .menu(title: track.title.ifBlank(track.id), items: [
        .init(icon: Omp.Icons.add, label: "Play next") { vm.queueNext(track) },
        .init(icon: Omp.Icons.list, label: "Add to queue") { vm.addToQueue(track) },
        .init(icon: Omp.Icons.cloud, label: "Save offline") { vm.saveOffline(track) },
        .init(icon: Omp.Icons.paintbrush, label: "Download artwork") { vm.artFetch(track.artKey.ifBlank(track.id)) },
        .init(icon: liked ? Omp.Icons.like : Omp.Icons.likeFull, label: liked ? "Unlike" : "Like") { vm.likeTrack(track) },
        .init(icon: Omp.Icons.bell, label: "Set as alarm") { vm.setAsAlarm(track) },
        .init(icon: Omp.Icons.spotify, label: "Share on Spotify") { vm.shareSpotifyLink(track) },
        .init(icon: Omp.Icons.ytm, label: "Share on YouTube Music") { vm.shareYouTubeLink(track) },
    ])
}

private struct QueueView: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let jump: Int
    @StateObject private var visible = VisibleRows()

    var body: some View {
        if state.queue.isEmpty {
            Empty(message: "Queue is empty. Open a playlist or search to add tracks.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: m.pt(6)) {
                    OmpText("Up next  ·  \(state.queue.count) tracks", size: Omp.TypeSize.caption, color: Omp.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    OmpButton(icon: Omp.Icons.clear, text: "Clear all", fontSize: Omp.TypeSize.caption) { vm.clearQueue() }
                }
                .padding(.horizontal, m.pt(4))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(state.queue.enumerated()), id: \.offset) { index, track in
                                let isCurrent = index == state.queueIndex
                                QueueRow(
                                    index: index,
                                    track: track,
                                    isCurrent: isCurrent,
                                    playing: isCurrent && state.playing,
                                    available: state.canPlay(track),
                                    dimmed: state.repeat == "one" ? !isCurrent : state.repeat == "off" ? index < state.queueIndex : false,
                                    liked: state.isLiked(track),
                                    vm: vm
                                ) { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
                                .id(index)
                                .onAppear { visible.appear(index, state.queue, vm) }
                                .onDisappear { visible.disappear(index) }
                            }
                        }
                        .padding(.top, m.pt(4))
                    }
                    // Follow the current song: when it changes, when the tab
                    // opens, and when the tab is tapped again. Two rows stay
                    // above it for context.
                    .onAppear { follow(proxy, animated: false) }
                    .onChange(of: state.queueIndex) { follow(proxy, animated: true) }
                    .onChange(of: jump) { follow(proxy, animated: true) }
                }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard state.queue.indices.contains(state.queueIndex) else { return }
        let target = max(state.queueIndex - 2, 0)
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }
}

/**
 * The tick inside the saved dot, drawn rather than typed: a font glyph sits
 * wherever its metrics put it, so it was off-centre, and differently on each
 * platform. Same points on desktop, Android and iOS.
 */
private struct SavedTick: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            Path { p in
                p.move(to: CGPoint(x: w * 0.27, y: w * 0.52))
                p.addLine(to: CGPoint(x: w * 0.43, y: w * 0.68))
                p.addLine(to: CGPoint(x: w * 0.74, y: w * 0.35))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.15, lineCap: .round, lineJoin: .round))
        }
    }
}

/** Second line of a track row; a saved song gets Spotify's small filled dot before the artist. */
private struct ArtistLine: View {
    @Environment(\.omp) private var m
    let text: String
    let color: Color
    let saved: Bool

    var body: some View {
        HStack(spacing: 0) {
            if saved {
                SavedTick()
                    .frame(width: m.pt(11), height: m.pt(11))
                    .background(Omp.themeAccent, in: Circle())
                    .padding(.trailing, m.pt(4))
            }
            OmpText(text, size: Omp.TypeSize.caption, color: color)
        }
    }
}

private struct QueueRow: View {
    @Environment(\.omp) private var m
    let index: Int
    let track: Track
    let isCurrent: Bool
    let playing: Bool
    let available: Bool
    let dimmed: Bool
    let liked: Bool
    @ObservedObject var vm: MaroViewModel
    let onMenu: () -> Void

    var body: some View {
        let tint = Omp.sourceColor(isCurrent && track.viaYoutube ? "ytm" : track.source)
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        HStack(spacing: m.pt(8)) {
            CoverArt(artKey: track.artKey, artUrl: track.artUrl, icon: Omp.sourceIcon(track.source), size: Omp.rowArt)
            HeartButton(liked: liked) { vm.likeTrack(track) }
            VStack(alignment: .leading, spacing: 0) {
                OmpText(track.title.ifBlank(track.id), size: Omp.TypeSize.bodySmall, bold: isCurrent)
                ArtistLine(text: available ? track.artist : "not on this phone", color: available ? Omp.muted : Omp.urgent, saved: track.saved && available)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OmpIcon(isCurrent ? (playing ? Omp.Icons.pause : Omp.Icons.play) : "\(index + 1)", size: Omp.TypeSize.caption, color: isCurrent ? Omp.foreground : Omp.muted)
                .frame(width: m.pt(Omp.queueMarkWidth))
            OmpButton(icon: Omp.Icons.close, vertical: 6, horizontal: 6) { vm.removeQueueIndex(index) }
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(40))
        .background(isCurrent ? tint.opacity(0.22) : Color.clear, in: shape)
        .overlay { if isCurrent { shape.stroke(tint, lineWidth: 1) } }
        .contentShape(shape)
        .opacity(dimmed || !available ? 0.4 : 1)
        .onTapGesture { vm.playQueueIndex(index) }
        .onLongPressGesture(perform: onMenu)
    }
}

private struct PlaylistsView: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        if let row = state.selectedPlaylist {
            PlaylistDetail(row: row, state: state, vm: vm).id(row.source + ":" + row.id)
        } else if state.library.isEmpty {
            Empty(message: "No playlists yet")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.library.enumerated()), id: \.offset) { _, row in
                        if row.isHeader {
                            HeaderRow(row: row)
                        } else {
                            PlaylistRow(row: row, vm: vm, job: state.downloadOf(row)) { present(playlistMenu(row)) }
                        }
                    }
                    Button {
                        present(.name(title: "Create playlist", placeholder: "Playlist name", confirm: "Create", initial: "") { vm.createPlaylist($0, from: nil) })
                    } label: {
                        HStack(spacing: m.pt(8)) {
                            OmpIcon(Omp.Icons.add, size: Omp.TypeSize.subtitle, color: Omp.muted)
                            OmpText("Create playlist")
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, m.pt(4))
                        .frame(height: m.pt(36))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, m.pt(4))
            }
        }
    }

    private func playlistMenu(_ row: LibraryRow) -> OmpDialog {
        .menu(title: row.name, items: [
            .init(icon: Omp.Icons.play, label: "Play") { vm.playPlaylist(row) },
            .init(icon: Omp.Icons.cloud, label: "Save offline") { vm.savePlaylistOffline(row) },
            .init(icon: Omp.Icons.grid, label: "Download to this phone") { vm.downloadPlaylist(row) },
            .init(icon: Omp.Icons.paintbrush, label: "Download artwork") { vm.artFetch(row.art.ifBlank(row.id)) },
            // Rename and Delete open their own dialog instead of closing.
            .init(icon: Omp.Icons.edit, label: "Rename", closes: false) {
                present(.name(title: "Rename playlist", placeholder: row.name, confirm: "Rename", initial: row.name) { vm.renamePlaylist(row.id, $0) })
            },
            .init(icon: Omp.Icons.trash, label: "Delete", closes: false) {
                present(.confirm(message: "Delete \(row.name)?", confirm: "Delete") { vm.deletePlaylist(row.id) })
            },
        ])
    }
}

private struct PlaylistDetail: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let row: LibraryRow
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @StateObject private var visible = VisibleRows()

    var body: some View {
        let tracks = state.playlistTracks
        VStack(spacing: 0) {
            HStack(spacing: m.pt(8)) {
                OmpButton(icon: Omp.Icons.back, vertical: 4, horizontal: 6) { vm.closePlaylist() }
                VStack(alignment: .leading, spacing: 0) {
                    OmpText(row.name, size: Omp.TypeSize.bodySmall, bold: true)
                    let count = state.playlistTotal > 0 ? state.playlistTotal : row.count
                    if count > 0 { OmpText("\(count) tracks", size: Omp.TypeSize.caption, color: Omp.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !tracks.isEmpty {
                    OmpButton(icon: Omp.Icons.play, text: "Play all", fontSize: Omp.TypeSize.caption) { vm.playOpenPlaylist() }
                }
            }
            .padding(.horizontal, m.pt(4))
            .frame(height: m.pt(38))
            if state.playlistLoading {
                OmpSpinner(size: Omp.TypeSize.body, color: Omp.muted).frame(maxWidth: .infinity).frame(height: m.pt(54))
                Spacer(minLength: 0)
            } else if !state.playlistError.isEmpty && tracks.isEmpty {
                OmpText(state.playlistError, size: Omp.TypeSize.caption, color: Omp.urgent, maxLines: 3).padding(m.pt(8))
                Spacer(minLength: 0)
            } else if tracks.isEmpty {
                Empty(message: "This playlist has no playable tracks")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(
                                track: track,
                                isCurrent: track.sameAs(state.track),
                                liked: state.isLiked(track),
                                vm: vm,
                                available: state.canPlay(track),
                                onPlay: { vm.playTrack(track, context: tracks, name: row.name, index: index) },
                                onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
                            )
                            .onAppear {
                                visible.appear(index, tracks, vm)
                                // Ask for the next page well before the end, so it lands before the list runs out.
                                if index >= tracks.count - 20 && state.playlistHasMore { vm.loadMorePlaylist() }
                            }
                            .onDisappear { visible.disappear(index) }
                        }
                        if state.playlistLoadingMore {
                            OmpSpinner(size: Omp.TypeSize.bodySmall, color: Omp.muted).frame(height: m.pt(40))
                        }
                    }
                }
            }
        }
    }
}

private struct HeaderRow: View {
    @Environment(\.omp) private var m
    let row: LibraryRow

    var body: some View {
        HStack(alignment: .bottom) {
            OmpText(row.label.uppercased(), size: Omp.TypeSize.caption, color: Omp.accent, bold: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            OmpText("\(row.count)", size: Omp.TypeSize.caption, color: Omp.muted)
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(28), alignment: .bottom)
    }
}

private struct PlaylistRow: View {
    @Environment(\.omp) private var m
    let row: LibraryRow
    @ObservedObject var vm: MaroViewModel
    let job: DownloadJob?
    let onMenu: () -> Void

    var body: some View {
        let downloading = job?.running == true || (job.map { $0.total > 0 && !$0.finished } ?? false)
        let progress: String = {
            guard let job else { return "\(row.count) tracks  ·  \(Omp.sourceLabel(row.source))" }
            if job.running && job.total > 0 { return "Downloading \(job.done + job.failed)/\(job.total)" }
            if job.finished { return "Saved \(job.done) · \(job.failed) skipped" }
            return "Preparing download…"
        }()
        ZStack(alignment: .bottom) {
            HStack(spacing: m.pt(8)) {
                // A playlist's "art" is either a CDN URL or the droplet's cover key.
                CoverArt(artKey: row.art, artUrl: row.art, icon: Omp.sourceIcon(row.source), size: Omp.rowArt)
                VStack(alignment: .leading, spacing: 0) {
                    OmpText(row.name, size: Omp.TypeSize.bodySmall)
                    OmpText(progress, size: Omp.TypeSize.caption, color: job != nil ? Omp.accent : Omp.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OmpButton(icon: Omp.Icons.more, vertical: 6, horizontal: 8, action: onMenu)
            }
            .frame(maxHeight: .infinity)
            if downloading {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Omp.foreground.opacity(0.10)
                        Omp.accent.frame(width: geo.size.width * (job?.fraction ?? 0))
                    }
                }
                .frame(height: m.pt(2))
            }
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(downloading ? 48 : 40))
        .contentShape(Rectangle())
        .onTapGesture { vm.openPlaylist(row) }
        // Artwork lands in the background as soon as the row shows, and stays on disk.
        .task(id: row) { vm.prefetchArt(row.art.ifBlank(row.id)) }
    }
}

private struct SongsView: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        if state.songs.isEmpty {
            Empty(message: "Nothing saved yet. Tracks you play are kept here automatically.")
        } else {
            TrackList(tracks: state.songs, state: state, vm: vm) { i, _ in vm.playOfflineAt(i) }
        }
    }
}

private struct RecentView: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        if state.recent.isEmpty {
            Empty(message: "Nothing played yet")
        } else {
            TrackList(tracks: state.recent, state: state, vm: vm, meta: { Omp.agoText($0.playedAt) }, footer: AnyView(
                Button { vm.clearHistory() } label: {
                    OmpText("Clear history", size: Omp.TypeSize.caption, color: Omp.urgent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, m.pt(10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            )) { i, t in vm.playTrack(t, context: state.recent, name: "Recently played", index: i) }
        }
    }
}

private struct TrackList: View {
    @Environment(\.presentDialog) private var present
    let tracks: [Track]
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    var meta: (Track) -> String = { _ in "" }
    var footer: AnyView?
    let onPlay: (Int, Track) -> Void
    @StateObject private var visible = VisibleRows()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(
                        track: track,
                        isCurrent: track.sameAs(state.track),
                        liked: state.isLiked(track),
                        vm: vm,
                        meta: meta(track),
                        available: state.canPlay(track),
                        onPlay: { onPlay(index, track) },
                        onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
                    )
                    .onAppear { visible.appear(index, tracks, vm) }
                    .onDisappear { visible.disappear(index) }
                }
                if let footer { footer }
            }
        }
    }
}

private struct TrackRow: View {
    @Environment(\.omp) private var m
    let track: Track
    let isCurrent: Bool
    let liked: Bool
    @ObservedObject var vm: MaroViewModel
    var meta = ""
    var available = true
    let onPlay: () -> Void
    let onMenu: () -> Void

    var body: some View {
        let tint = Omp.sourceColor(isCurrent && track.viaYoutube ? "ytm" : track.source)
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        let line: String = {
            if !available { return "not on this phone" }
            if !meta.isEmpty && !track.artist.isEmpty { return "\(track.artist)  ·  \(meta)" }
            return meta.isEmpty ? track.artist : meta
        }()
        HStack(spacing: m.pt(8)) {
            CoverArt(artKey: track.artKey, artUrl: track.artUrl, icon: Omp.sourceIcon(track.source), size: Omp.rowArt)
            HeartButton(liked: liked) { vm.likeTrack(track) }
            VStack(alignment: .leading, spacing: 0) {
                OmpText(track.title.ifBlank(track.id), size: Omp.TypeSize.bodySmall, bold: isCurrent)
                ArtistLine(text: line, color: available ? Omp.muted : Omp.urgent, saved: track.saved && available)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OmpText(track.duration > 0 ? Omp.fmtTime(track.duration) : "", size: Omp.TypeSize.caption, color: Omp.muted)
                .frame(width: m.pt(36), alignment: .leading)
            OmpButton(icon: Omp.Icons.more, vertical: 6, horizontal: 8, action: onMenu)
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(40))
        .background(isCurrent ? tint.opacity(0.22) : Color.clear, in: shape)
        .overlay { if isCurrent { shape.stroke(tint, lineWidth: 1) } }
        .contentShape(shape)
        .opacity(available ? 1 : 0.4)
        .onTapGesture(perform: onPlay)
        .onLongPressGesture(perform: onMenu)
    }
}

private let searchSources: [(String, String)] = [("", "All"), ("spotify", "Spotify"), ("ytm", "YouTube Music")]

private struct SearchView: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(spacing: 0) {
            OmpTextField(
                text: Binding(get: { vm.state.searchText }, set: { vm.setSearchText($0) }),
                placeholder: "Search, or paste Spotify / YouTube link",
                keyboard: .webSearch,
                onSubmit: { vm.doSearch() }
            )
            .padding(.horizontal, m.pt(4))
            HStack(spacing: m.pt(4)) {
                ForEach(searchSources, id: \.0) { source in
                    OmpButton(text: source.1, selected: state.searchSource == source.0) { vm.pickSearchSource(source.0) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, m.pt(4))
            .padding(.vertical, m.pt(4))
            if state.searching {
                OmpSpinner(size: Omp.TypeSize.bodySmall, color: Omp.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.searchResults.isEmpty {
                Empty(message: "Type a query, then hit enter")
            } else {
                TrackList(tracks: state.searchResults, state: state, vm: vm) { i, t in
                    vm.playTrack(t, context: state.searchResults, name: "Search", index: i)
                }
            }
        }
        .padding(.top, m.pt(4))
    }
}
