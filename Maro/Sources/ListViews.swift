import SwiftUI

struct ViewArea: View {
    @Environment(\.queueOnly) private var queueOnly
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let queueJump: Int
    /** Wide: the queue has its own tile, so the queue tab shows the lyrics. */
    var wide = false

    var body: some View {
        let view = queueOnly ? Sync.viewQueue : wide && state.view == Sync.viewQueue ? Sync.viewLyrics : state.view
        if !queueOnly, let page = state.pages.last {
            DetailPageView(page: page, state: state, vm: vm)
                .id(page.key + "#\(state.pages.count)")
                .transition(.opacity.combined(with: .offset(x: 12)))
        } else {
            tab(view)
        }
    }

    private func tab(_ view: String) -> some View {
        Group {
            switch view {
            case Sync.viewLyrics: LyricsView(state: state, vm: vm)
            case Sync.viewPlaylists: PlaylistsView(state: state, vm: vm)
            case Sync.viewDiscover: DiscoverView(state: state, vm: vm)
            case Sync.viewSongs: SongsView(state: state, vm: vm)
            case Sync.viewRecent: RecentView(state: state, vm: vm)
            case Sync.viewSearch: SearchView(state: state, vm: vm)
            default: QueueView(state: state, vm: vm, jump: queueJump)
            }
        }
        .id(view)
        .transition(.opacity.combined(with: .offset(x: 12)))
    }
}

/** The tabs' empty state: a centred #A0A0A0 line. */
struct EmptyNote: View {
    let message: String
    var boxed = false

    var body: some View {
        OmpText(message, size: 12, color: Omp.t2, maxLines: 4, align: .center)
            .padding(.vertical, 40)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(boxed ? Omp.row : Color.clear)
            .padding(boxed ? 4 : 0)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/** A tab's head line: grey text on the left, compact buttons on the right. */
struct TabHead<Trailing: View>: View {
    let text: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            OmpText(text, size: 12, color: Omp.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 36)
    }
}

/** Loading in a tab: the desktop's ring and a word. */
struct LoadingNote: View {
    var text = "Loading…"

    var body: some View {
        HStack(spacing: 10) {
            OmpSpinner(size: 16, color: Omp.themeAccent)
            OmpText(text, size: 12, color: Omp.t2)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    private var coversFrom = -1

    func appear(_ i: Int, _ tracks: [Track], _ vm: MaroViewModel) {
        shown.insert(i)
        // Covers from wherever the list is now, outwards - also while it
        // moves, every ten rows (not for each row, the order is re-sorted).
        if coversFrom < 0 || abs(i - coversFrom) >= 10 {
            coversFrom = i
            ArtLoader.shared.prefetch(tracks, list: "visible", around: i)
        }
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
func trackMenu(_ track: Track, liked: Bool, vm: MaroViewModel) -> OmpDialog {
    typealias Item = OmpDialog.Item
    // Tapping the row already plays it; this is for when you care
    // where it comes from. Each falls back if that service cannot.
    var items: [Item] = [
        Item(icon: .spotify, label: "Play on Spotify", tint: Omp.spotify) { vm.playOn(track, "spotify") },
        Item(icon: .ytm, label: "Play on YouTube Music", tint: Omp.ytm) { vm.playOn(track, "ytm") },
        Item(icon: .sc, label: "Play on SoundCloud", tint: Omp.sc) { vm.playOn(track, "sc") },
        Item(icon: .next, label: "Play next") { vm.queueNext(track) },
        // Songs like this one: Spotify's radio for a Spotify song, YouTube Music's otherwise.
        Item(icon: .radio, label: "Start radio") { vm.startRadio(track) },
    ]
    if !track.artist.isEmpty {
        items.append(Item(icon: .user, label: "Go to artist") { vm.openArtist(track.artistNames.first ?? track.artist, id: track.artistId) })
    }
    if !track.album.isEmpty {
        items.append(Item(icon: .disc, label: "Go to album") { vm.openAlbum(of: track) })
    }
    // "Add to queue" only for a song that is not queued yet; "Play next" moves one that is.
    if !vm.isQueued(track) {
        items.append(Item(icon: .addQueue, label: "Add to queue") { vm.addToQueue(track) })
    }
    items += [
        Item(icon: .download, label: "Save offline") { vm.saveOffline(track) },
        // A cover that is wrong, broken or blurry: thrown away and fetched again.
        Item(icon: .brush, label: "Fix artwork") { vm.fixArtwork(track) },
        Item(icon: .heart, label: liked ? "Unlike" : "Like", tint: liked ? Omp.soft : Omp.foreground) { vm.likeTrack(track) },
        Item(icon: .bell, label: "Set as alarm") { vm.setAsAlarm(track) },
        Item(icon: .link, label: "Share on Spotify") { vm.shareSpotifyLink(track) },
        Item(icon: .link, label: "Share on YouTube Music") { vm.shareYouTubeLink(track) },
    ]
    return .songMenu(track: track, items: items)
}

/**
 * The one song row of every list (the desktop's trackRow): 44 pt cover, heart,
 * bold title, "artist · service · length" under it (the saved check first),
 * the place in the list or the playing bars, and one action: remove in the
 * queue, add to the queue elsewhere.
 */
struct SongRow: View {
    @Environment(\.presentDialog) private var present
    let index: Int
    let track: Track
    let isCurrent: Bool
    let playing: Bool
    let liked: Bool
    @ObservedObject var vm: MaroViewModel
    var dimmed = false
    var available = true
    var when = ""
    var loading = false
    /** The queue's ×; nil means the + that adds the song to the queue. */
    var onRemove: (() -> Void)? = nil
    let onPlay: () -> Void
    let onMenu: () -> Void

    var body: some View {
        // Taken down by YouTube: greyed, the reason under the title, a tap only says why.
        let gone = vm.state.goneReason(track)
        let playable = available && gone.isEmpty
        let rest = [Omp.sourceLabel(track.source), track.duration > 0 ? Omp.fmtTime(track.duration) : "", when]
            .filter { !$0.isEmpty && $0 != "Queue" }
            .joined(separator: " · ")
        let sub: String = {
            if !gone.isEmpty { return gone }
            if !available { return "not on this phone" }
            return rest
        }()
        let artistLink = playable && !track.artist.isEmpty
        HStack(spacing: 6) {
            CoverArt(track: track, icon: Omp.sourceGlyph(track.source), size: Omp.rowArt)
            HeartButton(liked: liked, size: 15, box: 34) { vm.likeTrack(track) }
            VStack(alignment: .leading, spacing: 3) {
                OmpText(track.title.ifBlank(track.id), size: 13, color: Omp.foreground, bold: true)
                HStack(spacing: 5) {
                    if track.saved && playable { SavedCheck() }
                    if artistLink {
                        // The artist opens the artist page; the rest of the row plays.
                        HStack(spacing: 0) {
                            OmpText(track.artist, size: 11.5, color: Omp.t2)
                                .layoutPriority(1)
                                .contentShape(Rectangle())
                                .onTapGesture { openArtists(of: track, vm: vm, present: present) }
                            if !sub.isEmpty { OmpText(" · " + sub, size: 11.5, color: Omp.t2) }
                        }
                    } else {
                        OmpText(sub, size: 11.5, color: playable ? Omp.t2 : Omp.urgent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if isCurrent && loading {
                    OmpSpinner(size: 14, color: Omp.themeAccent)
                } else if isCurrent && playing {
                    EqBars()
                } else if isCurrent {
                    Icon(.playSmall, size: 13, color: Omp.foreground)
                } else {
                    OmpText("\(index + 1)", size: 11.5, color: Omp.t3)
                }
            }
            .frame(width: 30, alignment: .trailing)
            if let onRemove {
                TButton(.close, size: 14, box: 34, color: Omp.t2, action: onRemove)
            } else {
                TButton(.plus, size: 15, box: 34, color: Omp.t2) { vm.addToQueue(track) }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(isCurrent ? Omp.themeAccent.opacity(0.18) : Color.clear)
        .overlay { if isCurrent { Rectangle().strokeBorder(Omp.themeAccent.opacity(0.8), lineWidth: 1) } }
        .opacity(dimmed ? 0.3 : playable ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture {
            if gone.isEmpty { onPlay() } else { vm.showStatus("\(track.title) can't be played: \(gone)", "error") }
        }
        .onLongPressGesture(perform: onMenu)
    }
}

private struct QueueView: View {
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let jump: Int
    @StateObject private var visible = VisibleRows()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    OmpText("Queue", size: 12.5, color: Omp.foreground, bold: true)
                    if !state.queue.isEmpty {
                        OmpText("\(state.queue.count) tracks", size: 11.5, color: Omp.t3)
                    }
                }
                Spacer(minLength: 0)
                MButton("Clear all", icon: .trash, iconColor: Omp.like, kind: .ghost, enabled: !state.queue.isEmpty) {
                    vm.clearQueue()
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
            if state.queue.isEmpty {
                EmptyNote(message: "Queue is empty. Open a playlist or search to add tracks.", boxed: true)
                    .padding(.horizontal, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(state.queue.enumerated()), id: \.offset) { index, track in
                                let isCurrent = index == state.queueIndex
                                SongRow(
                                    index: index,
                                    track: track,
                                    isCurrent: isCurrent,
                                    playing: state.playing,
                                    liked: state.isLiked(track),
                                    vm: vm,
                                    dimmed: state.repeat == "one" ? !isCurrent : state.repeat == "off" ? index < state.queueIndex : false,
                                    available: state.canPlay(track),
                                    loading: !state.loadingKey.isEmpty,
                                    onRemove: { withAnimation(.easeIn(duration: 0.2)) { vm.removeQueueIndex(index) } },
                                    onPlay: { vm.playQueueIndex(index) },
                                    onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
                                )
                                .id(index)
                                .onAppear { visible.appear(index, state.queue, vm) }
                                .onDisappear { visible.disappear(index) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
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

/** The library's sort: as the account lists them, by name, or by size. Liked Songs stays first. */
private let librarySorts: [(String, String)] = [("recent", "Recent"), ("az", "A–Z"), ("size", "Size")]

private struct PlaylistsView: View {
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @AppStorage("jb.libSort") private var sort = "recent"

    private var rows: [LibraryRow] {
        let all = state.library.filter { !$0.isHeader }
        let pinned = all.filter { $0.source == "liked" }
        var rest = all.filter { $0.source != "liked" }
        if sort == "az" {
            rest.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else if sort == "size" {
            rest.sort { $0.count > $1.count }
        }
        return pinned + rest
    }

    var body: some View {
        if let row = state.selectedPlaylist {
            PlaylistDetail(row: row, state: state, vm: vm).id(row.source + ":" + row.id)
        } else {
            let list = rows
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    OmpText("\(list.count) \(list.count == 1 ? "playlist" : "playlists")", size: 12, color: Omp.t2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(librarySorts, id: \.0) { option in
                            MButton(option.1, kind: sort == option.0 ? .normal : .ghost, height: 30) { sort = option.0 }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 36)
                if list.isEmpty {
                    EmptyNote(message: "No playlists yet. Connect an account in Settings.", boxed: true)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list, id: \.self) { row in
                                LibraryRowView(row: row, state: state, vm: vm, job: state.downloadOf(row)) {
                                    present(playlistMenu(row))
                                }
                            }
                            CreatePlaylistRow {
                                present(.name(title: "Create playlist", placeholder: "Playlist name", confirm: "Create", initial: "") {
                                    vm.createPlaylist($0, from: nil)
                                })
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private func playlistMenu(_ row: LibraryRow) -> OmpDialog {
        .menu(title: row.name, items: [
            .init(icon: .playSmall, label: "Play") { vm.playPlaylist(row) },
            .init(icon: .download, label: "Save offline") { vm.savePlaylistOffline(row) },
            .init(icon: .download, label: "Download to this phone") { vm.downloadPlaylist(row) },
            .init(icon: .brush, label: "Download artwork") { vm.artFetch(row.art.ifBlank(row.id)) },
            // Rename and Delete open their own dialog instead of closing.
            .init(icon: .edit, label: "Rename", closes: false) {
                present(.name(title: "Rename playlist", placeholder: row.name, confirm: "Rename", initial: row.name) { vm.renamePlaylist(row.id, $0) })
            },
            .init(icon: .clear, label: "Delete", closes: false, tint: Omp.danger) {
                present(.confirm(message: "Delete \(row.name)?", confirm: "Delete") { vm.deletePlaylist(row.id) })
            },
        ])
    }
}

/** A playlist's sleeve; Liked Songs is the red square with the white heart. */
struct PlaylistCover: View {
    let row: LibraryRow
    let size: CGFloat
    /** Its songs, when open: without a sleeve of its own, the first four covers make one. */
    var tracks: [Track] = []

    var body: some View {
        if row.source == "liked" {
            ZStack {
                Omp.themeAccent
                Icon(.heart, size: size * 0.42, color: .white, filled: true)
            }
            .frame(width: size, height: size)
        } else if row.art.isEmpty && tracks.count >= 4 {
            let half = size / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    CoverArt(track: tracks[0], icon: .note, size: half)
                    CoverArt(track: tracks[1], icon: .note, size: half)
                }
                HStack(spacing: 0) {
                    CoverArt(track: tracks[2], icon: .note, size: half)
                    CoverArt(track: tracks[3], icon: .note, size: half)
                }
            }
            .frame(width: size, height: size)
        } else {
            // A playlist's "art" is either a CDN URL or the droplet's cover key.
            CoverArt(artKey: row.art, artUrl: row.art, icon: Omp.sourceGlyph(row.source), size: size)
        }
    }
}

func libraryServiceLabel(_ source: String) -> (String, Color) {
    if source == "liked" || source == "local" || source.isEmpty { return ("Jukebox", Omp.themeAccent) }
    return (Omp.sourceLabel(source), Omp.sourceColor(source))
}

private struct LibraryRowView: View {
    let row: LibraryRow
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let job: DownloadJob?
    let onMenu: () -> Void

    var body: some View {
        let downloading = job?.running == true || (job.map { $0.total > 0 && !$0.finished } ?? false)
        let shown = state.displayState()
        let active = !row.name.isEmpty && shown.queueName == row.name
        let label = libraryServiceLabel(row.source)
        HStack(spacing: 8) {
            PlaylistCover(row: row, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                OmpText(row.name.ifBlank("Playlist"), size: 13, color: Omp.foreground, bold: true)
                if let job {
                    OmpText(job.running && job.total > 0 ? "Downloading \(job.done + job.failed)/\(job.total)"
                            : job.finished ? "Saved \(job.done) · \(job.failed) skipped" : "Preparing download…",
                            size: 11.5, color: Omp.soft)
                } else {
                    HStack(spacing: 6) {
                        OmpText("\(row.count) \(row.count == 1 ? "track" : "tracks")", size: 11.5, color: Omp.t3)
                        OmpText("·", size: 11.5, color: Color(hex: 0x666666))
                        OmpText(label.0, size: 11.5, color: label.1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if active && shown.playing { EqBars() }
            if active {
                Button { vm.playPlaylist(row) } label: {
                    Icon(.playSmall, size: 14, color: Omp.soft)
                        .frame(width: 36, height: 36)
                        .background(Omp.raise)
                        .overlay(Rectangle().strokeBorder(Omp.edge, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .frame(height: 64)
        .overlay(alignment: .bottom) {
            if downloading {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Omp.foreground.opacity(0.10)
                        Omp.themeAccent.frame(width: geo.size.width * (job?.fraction ?? 0))
                    }
                }
                .frame(height: 2)
            }
        }
        .opacity(row.available ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture { vm.openPlaylist(row) }
        .onLongPressGesture(perform: onMenu)
        // Artwork lands in the background as soon as the row shows, and stays on disk.
        .task(id: row) { vm.prefetchArt(row.art.ifBlank(row.id)) }
    }
}

private struct CreatePlaylistRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(.plus, size: 18, color: Omp.t2)
                    .frame(width: 48, height: 48)
                    .overlay(Rectangle().strokeBorder(Omp.edge, lineWidth: 1))
                OmpText("Create playlist", size: 13, color: Omp.t2, bold: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/** A shuffled copy, played from its first song (the desktop's Shuffle). */
@MainActor
func playShuffled(_ tracks: [Track], name: String, vm: MaroViewModel) {
    let list = tracks.shuffled()
    guard let first = list.first else { return }
    vm.playTrack(first, context: list, name: name, index: 0)
}

private struct PlaylistDetail: View {
    @Environment(\.presentDialog) private var present
    let row: LibraryRow
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @StateObject private var visible = VisibleRows()

    var body: some View {
        let tracks = state.playlistTracks
        let shown = state.displayState()
        let count = state.playlistTotal > 0 ? state.playlistTotal : max(row.count, tracks.count)
        let service = libraryServiceLabel(row.source).0
        VStack(spacing: 0) {
            PageHeader(
                backLabel: "Library",
                kind: "Playlist",
                name: row.name.ifBlank("Playlist"),
                canPlay: !tracks.isEmpty,
                onBack: { vm.closePlaylist() },
                onPlay: { vm.playOpenPlaylist() },
                onShuffle: { playShuffled(tracks, name: row.name, vm: vm) },
                onQueue: { vm.addAllToQueue(tracks) },
                cover: { PlaylistCover(row: row, size: 64, tracks: tracks) },
                meta: { PageMeta("\(count) \(count == 1 ? "track" : "tracks") · \(service)") }
            )
            if state.playlistLoading {
                LoadingNote()
            } else if !state.playlistError.isEmpty && tracks.isEmpty {
                OmpText(state.playlistError, size: 12, color: Omp.urgent, maxLines: 3)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if tracks.isEmpty {
                EmptyNote(message: "This playlist is empty.", boxed: true).padding(.horizontal, 6)
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
                            OmpSpinner(size: 14, color: Omp.themeAccent).frame(height: 40)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

/** A list of songs with the shared row; `when` adds "2h" to Recent's. */
struct TrackList: View {
    @Environment(\.presentDialog) private var present
    let tracks: [Track]
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    var when: (Track) -> String = { _ in "" }
    let onPlay: (Int, Track) -> Void
    @StateObject private var visible = VisibleRows()

    var body: some View {
        let shown = state.displayState()
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
                        when: when(track),
                        loading: !shown.loadingKey.isEmpty,
                        onPlay: { onPlay(index, track) },
                        onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
                    )
                    .onAppear { visible.appear(index, tracks, vm) }
                    .onDisappear { visible.disappear(index) }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

/** The songs kept on this phone (the phone's own tab; the desktop has no such list). */
private struct SongsView: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabHead(text: "Saved on this phone · \(state.songs.count) \(state.songs.count == 1 ? "song" : "songs")") { EmptyView() }
            if state.songs.isEmpty {
                EmptyNote(message: "Nothing saved yet. Songs you play are kept here automatically.")
            } else {
                TrackList(tracks: state.songs, state: state, vm: vm) { i, _ in vm.playOfflineAt(i) }
            }
        }
        .padding(.top, 2)
    }
}

private struct RecentView: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !state.recent.isEmpty {
                TabHead(text: "Recently played · \(state.recent.count) \(state.recent.count == 1 ? "track" : "tracks")") {
                    MButton("Play all", icon: .playSmall, iconSize: 12, kind: .ghost) {
                        if let first = state.recent.first {
                            vm.playTrack(first, context: state.recent, name: "Recently played", index: 0)
                        }
                    }
                    MButton("Clear", icon: .trashSmall, kind: .ghost) { vm.clearHistory() }
                }
            }
            if state.recent.isEmpty {
                EmptyNote(message: "Nothing played yet.")
            } else {
                TrackList(tracks: state.recent, state: state, vm: vm, when: { Omp.agoText($0.playedAt) }) { _, t in vm.playSingle(t) }
            }
        }
        .padding(.top, 2)
    }
}

/** Rows that wrap: the search filters. */
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private let searchSources: [(String, String)] = [("", "All"), ("spotify", "Spotify"), ("ytm", "YouTube Music"), ("sc", "SoundCloud")]

private struct SearchView: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @FocusState private var focused: Bool

    var body: some View {
        let query = state.searchText.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Icon(.search, size: 16, color: Omp.t3)
                ZStack(alignment: .leading) {
                    if state.searchText.isEmpty { OmpText("Search or paste a link", size: 13, color: Omp.t3) }
                    TextField("", text: Binding(get: { vm.state.searchText }, set: { vm.setSearchText($0) }))
                        .font(Omp.font(13))
                        .foregroundColor(Omp.foreground)
                        .tint(Omp.themeAccent)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)
                        .focused($focused)
                        .onSubmit(submit)
                }
                MButton(state.searching ? "Searching…" : "Search", kind: .primary, action: submit)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 48)
            .background(Omp.page)
            .overlay(Rectangle().strokeBorder(focused ? Omp.t3 : Omp.edge, lineWidth: 1))
            if !state.searchLink.isEmpty && !state.searchResults.isEmpty {
                // A pasted list: the "link found" card with Play all instead of the service filters.
                HStack(spacing: 14) {
                    CoverArt(track: state.searchResults[0], icon: .link, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        OmpText("LINK FOUND", size: 10.5, color: Color(hex: 0x7FD083), bold: true)
                        OmpText(state.searchLink, size: 13.5, color: Omp.foreground, bold: true)
                        OmpText("\(state.searchResults.count) \(state.searchResults.count == 1 ? "song" : "songs")", size: 11.5, color: Omp.t2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MButton("Play all", kind: .primary) {
                        if let first = state.searchResults.first {
                            vm.playTrack(first, context: state.searchResults, name: state.searchLink, index: 0)
                        }
                    }
                }
                .padding(14)
                .background(Omp.row)
                .padding(.top, 12)
            } else {
                FlowRow(spacing: 4) {
                    ForEach(searchSources, id: \.0) { option in
                        MButton(option.1, kind: state.searchSource == option.0 ? .selected : .ghost) { vm.pickSearchSource(option.0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }
            if state.searching && state.searchResults.isEmpty {
                LoadingNote(text: query.hasPrefix("http") ? "Opening link…" : "Searching…")
            } else if state.searchResults.isEmpty {
                if query.isEmpty {
                    OmpText("Searches Spotify, YouTube Music and SoundCloud at once. Paste a link from any of them to play it.",
                            size: 12, color: Omp.t3, maxLines: 4)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    EmptyNote(message: query.count < 2 ? "Keep typing to search." : "Nothing matches \u{201C}\(query)\u{201D}.")
                }
            } else {
                TrackList(tracks: state.searchResults, state: state, vm: vm) { i, t in
                    if state.searchLink.isEmpty {
                        vm.playSingle(t)
                    } else {
                        vm.playTrack(t, context: state.searchResults, name: state.searchLink, index: i)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func submit() {
        focused = false
        vm.doSearch()
    }
}
