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
            .overlay(Rectangle().strokeBorder(track.map { Omp.playingColor($0.source) } ?? Omp.foreground.opacity(0.4), lineWidth: 1))
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
                        // Round 2 K: the artist and the album.
                        OmpText(track.artist + (track.album.isEmpty ? "" : " \u{B7} " + track.album), size: 11, color: Omp.sourceColor(track.source))
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
                        HStack(spacing: 0) {
                            OmpText(track.artist, size: 11, color: Omp.sourceColor(track.source))
                                .layoutPriority(1)
                                .contentShape(Rectangle())
                                .onTapGesture { openArtists(of: track, vm: vm, present: present) }
                            if !track.album.isEmpty {
                                OmpText(" \u{B7} " + track.album, size: 11, color: Omp.t3)
                                    .contentShape(Rectangle())
                                    .onTapGesture { vm.openAlbum(of: track) }
                            }
                        }
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
 * below, following the song. "Hide lyrics" leaves the big cover alone; a song
 * with no lyrics at all gets that layout only, with no button, and the choice
 * made comes back with the next song that has lyrics.
 */
struct JamView: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let close: () -> Void
    @AppStorage("jb.jamLyrics") private var showLyrics = true

    var body: some View {
        let lyrics = vm.lyrics
        // Known to have none: the lookup finished empty. While it runs, the chosen layout stays.
        let noLyrics = state.track == nil || (!lyrics.loading && lyrics.lines.isEmpty)
        let lyricsMode = !noLyrics && showLyrics
        GeometryReader { geo in
            ZStack {
                JamAmbient().ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image("LaunchNote").resizable().scaledToFit().frame(width: 26, height: 26)
                        Spacer(minLength: 0)
                        if !noLyrics {
                            MButton(showLyrics ? "Hide lyrics" : "Show lyrics", kind: .dark) {
                                withAnimation(.easeOut(duration: 0.22)) { showLyrics.toggle() }
                            }
                            .transition(.opacity)
                        }
                        MButton("Exit", icon: .close, iconSize: 13, kind: .dark, action: close)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 52)
                    if lyricsMode {
                        let side = max(120, min(geo.size.width * 0.5, geo.size.height * 0.26))
                        VStack(spacing: 20) {
                            artColumn(side: side, titleSize: 16, big: false)
                            JamLyrics(lyrics: lyrics, vm: vm)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                    } else {
                        let side = min(360, geo.size.height * 0.42, geo.size.width - 48)
                        VStack(spacing: 12) {
                            artColumn(side: side, titleSize: 22, big: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.opacity.combined(with: .offset(y: -12)))
                    }
                }
                .animation(.easeOut(duration: 0.22), value: lyricsMode)
                .animation(.easeOut(duration: 0.22), value: noLyrics)
            }
        }
        .background(Omp.page.ignoresSafeArea())
    }

    @ViewBuilder
    private func artColumn(side: CGFloat, titleSize: CGFloat, big: Bool) -> some View {
        let track = state.track
        VStack(spacing: big ? 14 : 10) {
            CoverArt(track: track, icon: Omp.sourceGlyph(track?.source ?? ""), size: side - 2)
                .padding(1)
                .overlay(Rectangle().strokeBorder(Omp.themeAccent, lineWidth: 1))
                .shadow(color: .black.opacity(0.7), radius: 22, y: 16)
                .id(track?.id ?? "")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    OmpText(track?.title.ifBlank("Nothing playing") ?? "Nothing playing", size: titleSize, color: Omp.foreground, bold: true)
                    if let track, !track.artist.isEmpty {
                        HStack(spacing: 0) {
                            OmpText(track.artist, size: 13, color: Color.mix(Omp.sourceColor(track.source), Omp.t2, 0.55))
                                .layoutPriority(1)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    close()
                                    vm.openArtist(track.artistNames.first ?? track.artist, id: track.artistId)
                                }
                            // Round 2 K: the album, which opens its page.
                            if !track.album.isEmpty {
                                OmpText(" \u{B7} " + track.album, size: 13, color: Omp.t3)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        close()
                                        vm.openAlbum(of: track)
                                    }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HeartButton(liked: state.isLiked(track), size: 20, box: 40, color: Omp.iconTint, enabled: track != nil) {
                    if let track { vm.likeTrack(track) }
                }
            }
            JamControls(state: state, vm: vm, big: big)
        }
        .frame(width: side)
    }
}

/** The lyrics column: synced lines following the song, plain ones to scroll, nothing while they load. */
private struct JamLyrics: View {
    let lyrics: SongLyrics
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        Group {
            if lyrics.lines.isEmpty {
                Color.clear
            } else if lyrics.synced {
                LyricLines(lyrics: lyrics, vm: vm, size: 26, minLine: 58, inset: 0, anchor: 0.38, fadeTop: 0.2, fadeBottom: 0.74)
            } else {
                PlainLyrics(lyrics: lyrics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/**
 * The full screen's controls, open and exactly the cover's width: the thin
 * seek line with its times, then shuffle, previous, the white round play,
 * next and repeat, evenly spread. No box.
 */
private struct JamControls: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    let big: Bool

    var body: some View {
        let rep = state.repeat
        VStack(spacing: big ? 16 : 10) {
            JamSeek(state: state, vm: vm)
            HStack(spacing: 0) {
                JamToggle(glyph: .shuffle, on: state.shuffle, enabled: state.queue.count > 1, label: "Shuffle") { vm.toggleShuffle() }
                Spacer(minLength: 0)
                JamSkip(glyph: .prev, enabled: state.isCurrent, label: "Previous") { vm.previous() }
                Spacer(minLength: 0)
                Button { vm.playPause() } label: {
                    Icon(state.playing ? .pause : .play, size: 22, color: .black)
                        .offset(x: state.playing ? 0 : 1.5)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color.white))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .disabled(!(state.isCurrent || !state.queue.isEmpty))
                .accessibilityLabel(state.playing ? "Pause" : "Play")
                Spacer(minLength: 0)
                JamSkip(glyph: .next, enabled: state.isCurrent, label: "Next") { vm.next() }
                Spacer(minLength: 0)
                JamToggle(glyph: .repeatAll, on: rep != "off", enabled: true, label: rep == "one" ? "Repeat one" : rep == "all" ? "Repeat all" : "Repeat off",
                          badge: rep == "one" ? "1" : "") {
                    vm.setRepeat(rep == "off" ? "all" : rep == "all" ? "one" : "off")
                }
            }
        }
    }
}

/** Previous / next: 26 pt white icons on 44 pt tap targets. */
private struct JamSkip: View {
    let glyph: Glyph
    let enabled: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(glyph, size: 26, color: .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/** Shuffle / repeat: 20 pt, grey off, red on with a 4 pt dot under; repeat-one adds a small "1". */
private struct JamToggle: View {
    let glyph: Glyph
    let on: Bool
    let enabled: Bool
    let label: String
    var badge = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Icon(glyph, size: 20, color: on ? Omp.markRed : Omp.iconTint)
                    if !badge.isEmpty {
                        OmpText(badge, size: 8, color: Omp.markRed, bold: true)
                            .offset(x: 5, y: -4)
                    }
                }
                Circle().fill(on ? Omp.markRed : Color.clear).frame(width: 4, height: 4)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/**
 * The full screen's seek line: 3 pt, the played part red; dragging shows a
 * 12 pt knob and the time under the finger. Times in tabular figures.
 */
private struct JamSeek: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @State private var drag: Double? = nil

    var body: some View {
        let progress = vm.progress
        TimelineView(.periodic(from: .now, by: progress.playing && drag == nil ? 0.25 : 3600)) { _ in
            let duration = progress.duration > 0 ? progress.duration : state.track?.duration ?? 0
            let enabled = state.isCurrent && duration > 0
            let at = progress.at(uptime())
            let f = min(max(drag ?? (duration > 0 ? at / duration : 0), 0), 1)
            VStack(spacing: 4) {
                GeometryReader { geo in
                    seekLine(width: geo.size.width, fraction: f, duration: duration, enabled: enabled)
                }
                .frame(height: 22)
                HStack {
                    OmpText(Omp.fmtTime(drag.map { duration * $0 } ?? at), size: 11, color: Omp.t3).monospacedDigit()
                    Spacer(minLength: 0)
                    OmpText(Omp.fmtTime(duration), size: 11, color: Omp.t3).monospacedDigit()
                }
            }
        }
    }

    private func seekLine(width w: CGFloat, fraction f: Double, duration: Double, enabled: Bool) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 3)
            Rectangle().fill(Omp.markRed).frame(width: w * f, height: 3)
            if drag != nil {
                Circle().fill(Color.white).frame(width: 12, height: 12).offset(x: w * f - 6)
                OmpText(Omp.fmtTime(duration * f), size: 11, color: .white).monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.75))
                    .offset(x: min(max(w * f - 20, 0), max(w - 40, 0)), y: -22)
            }
        }
        .frame(width: w, height: 22, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in if enabled && w > 0 { drag = min(max(v.location.x / w, 0), 1) } }
                .onEnded { v in
                    if enabled && w > 0 { vm.seek(duration * min(max(v.location.x / w, 0), 1)) }
                    drag = nil
                }
        )
        .accessibilityLabel("Seek")
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
