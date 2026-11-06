import SwiftUI

/**
 * The player tile. On a phone it starts as one slim bar (cover, title, the
 * white play square, next, and an arrow) that opens into the full player;
 * the choice is remembered. Wide, it is always the full player.
 */
struct PlayerTile: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let mini: Bool
    /** nil: no arrow (the wide layout keeps the full player). */
    var toggle: (() -> Void)? = nil

    var body: some View {
        let tint = state.track.map { Omp.sourceColor($0.source) } ?? Omp.themeAccent
        Group {
            if mini {
                MiniPlayer(state: state, vm: vm, expand: { toggle?() })
            } else {
                FullPlayer(state: state, vm: vm, collapse: toggle)
            }
        }
        .frame(maxWidth: .infinity)
        // The desktop's ambient: the song's colour glowing in from the top left.
        .background(
            GeometryReader { geo in
                RadialGradient(colors: [tint.opacity(0.27 * 0.72), tint.opacity(0)],
                               center: UnitPoint(x: 0.28, y: 0), startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) * 0.75)
            }
        )
        .tile()
        .clipped()
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: mini)
    }
}

/** The cover in the player: square, a 1 pt red border. */
private struct PlayerCover: View {
    let state: UiState
    let size: CGFloat

    var body: some View {
        let track = state.track
        CoverArt(track: track, icon: Omp.sourceGlyph(track?.source ?? ""), size: size - 2,
                 busy: track.map { state.artworkProgress[$0.artKey] != nil } ?? false)
            .padding(1)
            .overlay(Rectangle().strokeBorder(track == nil ? Omp.foreground.opacity(0.4) : Omp.themeAccent, lineWidth: 1))
            .id(track?.id ?? "")
            .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/** The white play square: #F5F5F5 with a #121212 glyph. */
struct PlaySquare: View {
    let playing: Bool
    var box: CGFloat = 40
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(playing ? .pause : .play, size: 17, color: Color(hex: 0x121212))
                .frame(width: box, height: box)
                .background(Omp.foreground)
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct MiniPlayer: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let expand: () -> Void

    var body: some View {
        let track = state.track
        HStack(spacing: 6) {
            HStack(spacing: 10) {
                PlayerCover(state: state, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    OmpText(track?.title.ifBlank("Nothing playing") ?? "Nothing playing", size: 13, color: Omp.foreground, bold: true)
                    if let track, !track.artist.isEmpty {
                        OmpText(track.artist, size: 11, color: Omp.sourceColor(track.source))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: expand)
            PlaySquare(playing: state.playing, box: 36, enabled: state.isCurrent || !state.queue.isEmpty) { vm.playPause() }
            TButton(.next, size: 17, box: 34, enabled: state.isCurrent) { vm.next() }
            TButton(.chevronUp, size: 18, box: 32, color: Omp.iconTint, action: expand)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }
}

/**
 * The bitrate of what is sounding, at this second of the song, on whichever
 * device is playing it: the droplet's per-second kbps of that exact copy, read
 * at the playhead. Before the timeline arrives it is the copy's average.
 * Coloured by how high it is (Omp.kbpsColor), the same scale everywhere.
 */
struct LiveBitrate: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let separator: Bool

    var body: some View {
        let progress = vm.progress
        TimelineView(.periodic(from: .now, by: progress.playing ? 0.5 : 3600)) { _ in
            let second = Int(progress.at(uptime()))
            let live = second >= 0 && second < state.audioTimeline.count ? state.audioTimeline[second] : 0
            let kbps = live > 0 ? live : state.audioKbps
            if kbps > 0 {
                OmpText((separator ? "  ·  " : "") + "\(kbps) kbps", size: 10, color: Omp.kbpsColor(kbps))
            }
        }
    }
}

private struct FullPlayer: View {
    @Environment(\.openJam) private var openJam
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let collapse: (() -> Void)?

    var body: some View {
        let track = state.track
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                PlayerCover(state: state, size: 56)
                    .onTapGesture { if track != nil { openJam() } }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        OmpText(track?.title.ifBlank("Nothing playing") ?? "Nothing playing", size: 15, color: Omp.foreground, bold: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HeartButton(liked: state.isLiked(track), size: 18, box: 24, color: Omp.iconTint, enabled: track != nil) {
                            if let track { vm.likeTrack(track) }
                        }
                    }
                    if let track, !track.artist.isEmpty {
                        // The artist and the album open their pages.
                        OmpText(track.artist, size: 11, color: Omp.sourceColor(track.source))
                            .contentShape(Rectangle())
                            .onTapGesture { openArtists(of: track, vm: vm, present: present) }
                    }
                    if !state.loadingKey.isEmpty {
                        HStack(spacing: 5) {
                            OmpSpinner(size: 10, color: Omp.themeAccent)
                            OmpText(state.loadingStage.ifBlank("Loading…"), size: 10, color: Omp.themeAccent)
                        }
                    } else if let track {
                        HStack(spacing: 0) {
                            if !track.album.isEmpty {
                                OmpText(track.album, size: 10, color: Omp.t3)
                                    .contentShape(Rectangle())
                                    .onTapGesture { vm.openAlbum(of: track) }
                            }
                            LiveBitrate(state: state, vm: vm, separator: !track.album.isEmpty)
                        }
                    }
                }
                .padding(.trailing, collapse == nil ? 0 : 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SeekRow(state: state, vm: vm)
            TransportBar(state: state, vm: vm)
            HStack(spacing: 10) {
                Button { vm.setVolume(state.volume > 0 ? 0 : 100) } label: {
                    Icon(state.volume <= 0 ? .volumeMute : state.volume < 50 ? .volumeLow : .volume, size: 16, color: Omp.iconTint)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                VolumeSlider(fraction: Double(state.volume) / 100) { f in vm.setVolume(Int((f * 100).rounded())) }
                OmpText("\(state.volume)%", size: 11, color: Omp.t3)
                    .frame(width: 34, alignment: .trailing)
                TButton(.expand, size: 15, box: 32, color: Omp.t3, enabled: track != nil) { openJam() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .topTrailing) {
            if let collapse {
                TButton(.chevronDown, size: 18, box: 32, color: Omp.iconTint, action: collapse)
                    .padding(8)
            }
        }
    }
}

/**
 * The playhead on the waveform. It runs off the view model's progress on its
 * own clock via TimelineView, so nothing else on screen redraws while a song plays.
 */
private struct SeekRow: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let progress = vm.progress
        TimelineView(.periodic(from: .now, by: progress.playing ? 0.25 : 3600)) { _ in
            let duration = progress.duration > 0 ? progress.duration : state.track?.duration ?? 0
            let enabled = state.isCurrent && duration > 0
            let at = progress.at(uptime())
            HStack(spacing: 10) {
                OmpText(Omp.fmtTime(at), size: 11, color: Color(hex: 0xC8C8C8))
                    .frame(width: 34, alignment: .leading)
                WaveSeek(key: state.track?.trackIds.joined(separator: ":") ?? "",
                         fraction: duration > 0 ? at / duration : 0,
                         enabled: enabled,
                         loading: !state.loadingKey.isEmpty) { f in
                    if enabled { vm.seek(duration * f) }
                }
                OmpText(Omp.fmtTime(duration), size: 11, color: Color(hex: 0xC8C8C8))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

/**
 * Restart, previous, play, next, shuffle, repeat: spread across the tile in
 * the player, packed into a bordered tile in the full-screen view.
 */
struct TransportBar: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    var compact = false

    var body: some View {
        let box: CGFloat = compact ? 30 : 34
        let shuffleOn = state.shuffle
        let rep = state.repeat
        HStack(spacing: 0) {
            TButton(.restart, size: 15, box: box, enabled: state.isCurrent) { vm.restart() }
            Spacer(minLength: 0)
            TButton(.prev, size: 17, box: box, enabled: state.isCurrent) { vm.previous() }
            Spacer(minLength: 0)
            PlaySquare(playing: state.playing, box: compact ? 36 : 40, enabled: state.isCurrent || !state.queue.isEmpty) { vm.playPause() }
                .padding(.horizontal, compact ? 0 : 6)
            Spacer(minLength: 0)
            TButton(.next, size: 17, box: box, enabled: state.isCurrent) { vm.next() }
            Spacer(minLength: 0)
            TButton(.shuffle, size: 16, box: box, color: shuffleOn ? Omp.soft : Omp.t3,
                    on: compact && shuffleOn, enabled: state.queue.count > 1) { vm.toggleShuffle() }
            Spacer(minLength: 0)
            ZStack {
                TButton(.repeatAll, size: 16, box: box, color: rep == "off" ? Omp.t3 : Omp.soft, on: compact && rep != "off") {
                    vm.setRepeat(rep == "off" ? "all" : rep == "all" ? "one" : "off")
                }
                if rep == "one" {
                    OmpText("1", size: 8, color: Omp.soft, bold: true)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(compact ? 2 : 0)
        .background(compact ? Omp.tile : Color.clear)
        .overlay { if compact { Rectangle().strokeBorder(Omp.line, lineWidth: 1) } }
    }
}

/**
 * The full-screen view (the desktop's Jamming mode): the red glow from the
 * left, the cover with its title, heart and controls, and the lyrics large
 * below, following the song. "Hide lyrics" leaves the big cover alone.
 */
struct JamView: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let close: () -> Void
    @State private var showLyrics = true

    var body: some View {
        let lyrics = vm.lyrics
        let hasLyrics = lyrics.synced && !lyrics.lines.isEmpty
        GeometryReader { geo in
            ZStack {
                JamAmbient().ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image("LaunchNote").resizable().scaledToFit().frame(width: 26, height: 26)
                        Spacer(minLength: 0)
                        if hasLyrics {
                            MButton(showLyrics ? "Hide lyrics" : "Show lyrics", kind: .dark) {
                                withAnimation(.easeOut(duration: 0.3)) { showLyrics.toggle() }
                            }
                        }
                        MButton("Exit", icon: .close, iconSize: 13, kind: .dark, action: close)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 52)
                    if hasLyrics && showLyrics {
                        let side = max(120, min(geo.size.width * 0.5, geo.size.height * 0.26))
                        VStack(spacing: 20) {
                            artColumn(side: side, titleSize: 16)
                            LyricLines(lyrics: lyrics, vm: vm, size: 26, minLine: 58, inset: 0, anchor: 0.38,
                                       fadeTop: 0.2, fadeBottom: 0.74)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                    } else {
                        let side = min(340, geo.size.height * 0.42, geo.size.width * 0.72)
                        VStack(spacing: 12) {
                            artColumn(side: side, titleSize: 22, centred: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                    }
                }
            }
        }
        .background(Omp.page.ignoresSafeArea())
    }

    @ViewBuilder
    private func artColumn(side: CGFloat, titleSize: CGFloat, centred: Bool = false) -> some View {
        let track = state.track
        VStack(spacing: centred ? 12 : 8) {
            CoverArt(track: track, icon: Omp.sourceGlyph(track?.source ?? ""), size: side - 2)
                .padding(1)
                .overlay(Rectangle().strokeBorder(Omp.themeAccent, lineWidth: 1))
                .shadow(color: .black.opacity(0.7), radius: 22, y: 16)
                .id(track?.id ?? "")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    OmpText(track?.title.ifBlank("Nothing playing") ?? "Nothing playing", size: titleSize, color: Omp.foreground, bold: true)
                    if let track, !track.artist.isEmpty {
                        OmpText(track.artist, size: 13, color: Color.mix(Omp.sourceColor(track.source), Omp.t2, 0.55))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                close()
                                vm.openArtist(track.artistNames.first ?? track.artist, id: track.artistId)
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HeartButton(liked: state.isLiked(track), size: 20, box: 40, color: Omp.iconTint, enabled: track != nil) {
                    if let track { vm.likeTrack(track) }
                }
            }
            TransportBar(state: state, vm: vm, compact: true)
        }
        .frame(width: side)
    }
}

/** The jam view's glow: the accent from the left edge, fading to the page on the right. */
private struct JamAmbient: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let c = Omp.themeAccent
            ZStack {
                Omp.page
                RadialGradient(stops: [
                    .init(color: c.opacity(0.42), location: 0),
                    .init(color: c.opacity(0.16), location: 0.42),
                    .init(color: c.opacity(0), location: 0.74),
                ], center: UnitPoint(x: 0.04, y: 0.48), startRadius: 0, endRadius: max(w, h) * 1.0)
                RadialGradient(stops: [
                    .init(color: c.opacity(0.22), location: 0),
                    .init(color: c.opacity(0), location: 0.68),
                ], center: UnitPoint(x: 0.18, y: 0.95), startRadius: 0, endRadius: max(w, h) * 0.7)
                LinearGradient(stops: [
                    .init(color: Omp.page.opacity(0.18), location: 0),
                    .init(color: Omp.page.opacity(0.78), location: 0.58),
                    .init(color: Omp.page, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}
