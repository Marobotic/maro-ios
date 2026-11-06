import SwiftUI

/**
 * The phone header of every list page (playlist, artist, album): the slim
 * back bar, the 64 pt cover beside the kind ("PLAYLIST", red, letter-spaced),
 * the name and one meta line, then one full-width row of actions - Play
 * (filled red), Shuffle (outlined) and a square Add to queue.
 */
struct PageHeader<Cover: View, Meta: View>: View {
    let backLabel: String
    let kind: String
    let name: String
    let canPlay: Bool
    let onBack: () -> Void
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onQueue: () -> Void
    var onRefresh: (() -> Void)? = nil
    @ViewBuilder let cover: () -> Cover
    @ViewBuilder let meta: () -> Meta

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MButton(backLabel, icon: .back, kind: .ghost, height: 26, action: onBack)
                    .padding(.leading, -8)
                Spacer(minLength: 0)
                if let onRefresh { TButton(.refreshAlt, size: 14, box: 28, color: Omp.t2, action: onRefresh) }
            }
            .frame(minHeight: 26)
            HStack(alignment: .center, spacing: 12) {
                cover().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.uppercased())
                        .font(Omp.font(10, bold: true))
                        .tracking(1.2)
                        .foregroundColor(Omp.markRed)
                        .lineLimit(1)
                    OmpText(name, size: 20, color: Omp.foreground, bold: true)
                    meta()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
            PageActions(enabled: canPlay, onPlay: onPlay, onShuffle: onShuffle, onQueue: onQueue)
                .padding(.top, 12)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

/** The header's meta line: 11.5 pt grey. */
struct PageMeta: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { OmpText(text, size: 11.5, color: Omp.t3) }
}

/** Play, Shuffle and Add to queue: 36 pt tall, 8 pt apart, square corners. */
private struct PageActions: View {
    let enabled: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onQueue: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Icon(.playSmall, size: 12, color: .white)
                    OmpText("Play", size: 12.5, color: .white, bold: true)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Omp.themeAccent)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.97))
            Button(action: onShuffle) {
                HStack(spacing: 8) {
                    Icon(.shuffleAlt, size: 14, color: Omp.foreground)
                    OmpText("Shuffle", size: 12.5, color: Omp.foreground, bold: true)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Omp.row)
                .overlay(Rectangle().strokeBorder(Omp.outline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.97))
            Button(action: onQueue) {
                Icon(.addQueue, size: 16, color: Omp.foreground)
                    .frame(width: 36, height: 36)
                    .background(Omp.row)
                    .overlay(Rectangle().strokeBorder(Omp.outline, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel("Add to queue")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/** Plays a page's songs from the first. */
@MainActor
func playPage(_ tracks: [Track], name: String, vm: MaroViewModel) {
    guard let first = tracks.first else { return }
    vm.playTrack(first, context: tracks, name: name, index: 0)
}

/** A song's artist: its page, or a choice when the song has several. */
@MainActor
func openArtists(of t: Track, vm: MaroViewModel, present: (OmpDialog?) -> Void) {
    let names = t.artistNames
    guard names.count > 1 else { return vm.openArtist(names.first ?? t.artist, id: t.artistId) }
    present(.menu(title: "Go to artist", items: names.enumerated().map { pair in
        OmpDialog.Item(icon: .user, label: pair.element) { vm.openArtist(pair.element, id: pair.offset == 0 ? t.artistId : "") }
    }))
}

/** An artist or album page over the tabs. */
struct DetailPageView: View {
    let page: DetailPage
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        switch page {
        case .artist(let name, let id, let art):
            ArtistPageView(page: page, name: name, id: id, art: art, state: state, vm: vm)
        case .album(let name, _, let art, let artist):
            AlbumPageView(page: page, name: name, art: art, artist: artist, state: state, vm: vm)
        case .releases(let title, let artist, _):
            ReleasesPageView(page: page, title: title, artist: artist, vm: vm)
        }
    }
}

/** A section's head inside a page: grey, with "See all" when there is more. */
private struct SectionTitle: View {
    let text: String
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack {
            OmpText(text, size: 12, color: Omp.t2, bold: true)
            Spacer(minLength: 0)
            if let onMore { MButton("See all", kind: .ghost, height: 26, action: onMore) }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/** Couldn't reach YouTube Music: a quiet line and a retry; the page shows what the phone knows. */
private struct FailNote: View {
    let page: DetailPage

    var body: some View {
        HStack(spacing: 8) {
            Icon(.warning, size: 12, color: Omp.t3)
            OmpText("Couldn't load from YouTube Music", size: 11.5, color: Omp.t3)
                .frame(maxWidth: .infinity, alignment: .leading)
            MButton("Try again", kind: .ghost, height: 26) { PageStore.shared.load(page) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

/** The page's songs as the usual song rows. */
private struct PageSongRows: View {
    @Environment(\.presentDialog) private var present
    let tracks: [Track]
    let listName: String
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let shown = state.displayState()
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
                onPlay: { vm.playTrack(track, context: tracks, name: listName, index: index) },
                onMenu: { present(trackMenu(track, liked: state.isLiked(track), vm: vm)) }
            )
        }
    }
}

/** An artist's round photo, or the first letter of the name on red. */
private struct ArtistPhoto: View {
    let url: String
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if url.isEmpty {
                ZStack {
                    Omp.themeAccent
                    OmpText(String(name.prefix(1)).uppercased(), size: size * 0.42, color: .white, bold: true)
                }
                .frame(width: size, height: size)
            } else {
                CoverArt(artUrl: url, icon: .user, size: size)
            }
        }
        .clipShape(Circle())
    }
}

/** An album, single or EP: its art, title and "2024 · Single". */
private struct ReleaseTile: View {
    let item: ReleaseItem
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArt(artUrl: item.art, icon: .disc, size: size)
            OmpText(item.title, size: 12, color: Omp.foreground, bold: true, maxLines: 2)
                .frame(height: 32, alignment: .topLeading)
            OmpText([item.year, item.kind].filter { !$0.isEmpty }.joined(separator: " · "), size: 11, color: Omp.t3)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ReleaseCarousel: View {
    let items: [ReleaseItem]
    let artist: String
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(items, id: \.id) { item in
                    ReleaseTile(item: item, size: 128)
                        .onTapGesture { vm.openAlbum(item.title, id: item.id, art: item.art, artist: artist) }
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

private struct ArtistPageView: View {
    @ObservedObject private var store = PageStore.shared
    let page: DetailPage
    let name: String
    let id: String
    let art: String
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let key = page.key
        let info = store.artists[key]
        let failed = store.status[key] == .failed
        let title = (info?.name ?? "").ifBlank(name)
        let known = failed ? vm.knownTracks(artist: title) : []
        let songs = failed ? known : (store.allSongs[key] ?? info?.songs ?? [])
        VStack(spacing: 0) {
            PageHeader(
                backLabel: "Back",
                kind: "Artist",
                name: title,
                canPlay: !songs.isEmpty,
                onBack: { vm.pageBack() },
                onPlay: { playPage(songs, name: title, vm: vm) },
                onShuffle: { playShuffled(songs, name: title, vm: vm) },
                onQueue: { vm.addAllToQueue(songs) },
                cover: { ArtistPhoto(url: (info?.photo ?? "").ifBlank(art), name: title, size: 64) },
                meta: { PageMeta(meta(info, failed: failed, known: known.count)) }
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if failed {
                        FailNote(page: page)
                        if known.isEmpty {
                            EmptyNote(message: "Nothing by \(title) on this phone yet.")
                        } else {
                            SectionTitle(text: "Songs")
                            PageSongRows(tracks: known, listName: title, state: state, vm: vm)
                        }
                    } else if let info {
                        sections(info, key: key, songs: songs, title: title)
                    } else {
                        LoadingNote()
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func sections(_ info: ArtistInfo, key: String, songs: [Track], title: String) -> some View {
        if !songs.isEmpty {
            SectionTitle(text: "Songs")
            PageSongRows(tracks: songs, listName: title, state: state, vm: vm)
            if !info.songsList.isEmpty && store.allSongs[key] == nil {
                MButton(store.songsLoading.contains(key) ? "Loading…" : "Show all songs", kind: .ghost, height: 30) { store.loadAllSongs(key) }
                    .padding(.leading, 2)
            }
        }
        if !info.albums.isEmpty {
            SectionTitle(text: "Albums", onMore: info.albumsMore.map { ref -> () -> Void in { vm.openReleases("Albums", artist: title, ref: ref) } })
            ReleaseCarousel(items: info.albums, artist: title, vm: vm)
        }
        if !info.singles.isEmpty {
            SectionTitle(text: "Singles & EPs", onMore: info.singlesMore.map { ref -> () -> Void in { vm.openReleases("Singles & EPs", artist: title, ref: ref) } })
            ReleaseCarousel(items: info.singles, artist: title, vm: vm)
        }
    }

    private func meta(_ info: ArtistInfo?, failed: Bool, known: Int) -> String {
        if failed { return "\(known) \(known == 1 ? "track" : "tracks") on this phone" }
        guard let info else { return "YouTube Music" }
        let releases = info.albums.count + info.singles.count
        let parts = [info.subtitle, releases > 0 ? "\(releases) releases" : ""].filter { !$0.isEmpty }
        return parts.isEmpty ? "YouTube Music" : parts.joined(separator: " · ")
    }
}

/** The album page's meta: its artists (each opens its page), the year, the count and the length. */
private struct AlbumMeta: View {
    let artists: [ArtistLink]
    let rest: String
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { i, artist in
                if i > 0 { OmpText(", ", size: 11.5, color: Omp.t3) }
                OmpText(artist.name, size: 11.5, color: Omp.link)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.openArtist(artist.name, id: artist.id) }
            }
            if !rest.isEmpty { OmpText((artists.isEmpty ? "" : " · ") + rest, size: 11.5, color: Omp.t3) }
        }
        .lineLimit(1)
    }
}

private struct AlbumPageView: View {
    @ObservedObject private var store = PageStore.shared
    let page: DetailPage
    let name: String
    let art: String
    let artist: String
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let key = page.key
        let info = store.albums[key]
        let failed = store.status[key] == .failed
        let title = (info?.title ?? "").ifBlank(name)
        let tracks = failed ? vm.knownTracks(album: name) : (info?.tracks ?? [])
        let artists = info?.artists ?? (artist.isEmpty ? [] : [ArtistLink(name: artist)])
        VStack(spacing: 0) {
            PageHeader(
                backLabel: "Back",
                kind: info?.kind ?? "Album",
                name: title,
                canPlay: !tracks.isEmpty,
                onBack: { vm.pageBack() },
                onPlay: { playPage(tracks, name: title, vm: vm) },
                onShuffle: { playShuffled(tracks, name: title, vm: vm) },
                onQueue: { vm.addAllToQueue(tracks) },
                cover: { CoverArt(artUrl: (info?.art ?? "").ifBlank(art), icon: .disc, size: 64) },
                meta: { AlbumMeta(artists: artists, rest: rest(info, tracks: tracks.count), vm: vm) }
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if failed {
                        FailNote(page: page)
                        if tracks.isEmpty { EmptyNote(message: "Nothing from \(title) on this phone yet.") }
                    } else if info == nil {
                        LoadingNote()
                    }
                    PageSongRows(tracks: tracks, listName: title, state: state, vm: vm)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func rest(_ info: AlbumInfo?, tracks: Int) -> String {
        let count = max(info?.trackCount ?? 0, tracks)
        let length = (info?.length ?? "")
            .replacingOccurrences(of: " minutes", with: " min").replacingOccurrences(of: " minute", with: " min")
            .replacingOccurrences(of: " hours", with: " hr").replacingOccurrences(of: " hour", with: " hr")
        let parts = [info?.year ?? "", count > 0 ? "\(count) \(count == 1 ? "track" : "tracks")" : "", length]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/** "See all": every album or single of an artist, two to a row. */
private struct ReleasesPageView: View {
    @ObservedObject private var store = PageStore.shared
    let page: DetailPage
    let title: String
    let artist: String
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let key = page.key
        let items = store.releases[key] ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MButton("Back", icon: .back, kind: .ghost, height: 26) { vm.pageBack() }
                    .padding(.leading, -8)
                OmpText(artist.isEmpty ? title : "\(title) · \(artist)", size: 12, color: Omp.t2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 26)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            if store.status[key] == .failed {
                FailNote(page: page).padding(.horizontal, 4)
            } else if items.isEmpty {
                LoadingNote()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(items, id: \.id) { item in
                            ReleaseTile(item: item, size: 150)
                                .onTapGesture { vm.openAlbum(item.title, id: item.id, art: item.art, artist: artist) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
