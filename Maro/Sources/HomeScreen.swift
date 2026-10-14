import SwiftUI

private let tabs: [(key: String, label: String)] = [
    (Sync.viewQueue, "Queue"),
    (Sync.viewLyrics, "Lyrics"),
    (Sync.viewPlaylists, "Playlists"),
    (Sync.viewSongs, "Songs"),
    (Sync.viewRecent, "Recent"),
    (Sync.viewSearch, "Search"),
]

private func deviceLabel(_ device: Device) -> String {
    if !device.name.isBlank { return device.name }
    return device.kind == "phone" ? "Phone" : "Desktop"
}

/** Every connected device; the one playing now in the accent colour, the rest white. */
@MainActor
func devicePicker(_ state: UiState, _ vm: MaroViewModel) -> OmpDialog {
    .menu(title: "Play on", items: state.pickerDevices().map { device in
        OmpDialog.Item(
            icon: Omp.Icons.broadcast,
            label: deviceLabel(device),
            tint: device.isPlayback ? Omp.themeAccent : Omp.foreground,
            detail: device.id == state.myDeviceId ? "This phone" : "",
            bold: device.isPlayback
        ) { if !device.isPlayback { vm.selectDevice(device) } }
    })
}

/** The Omp-styled popups (menus, name prompts, confirmations) share one host. */
enum OmpDialog: Identifiable {
    struct Item {
        let icon: String
        let label: String
        var closes = true
        var tint: Color = Omp.foreground
        var detail = ""
        var bold = false
        let action: () -> Void
    }

    case menu(title: String, items: [Item])
    case name(title: String, placeholder: String, confirm: String, initial: String, onConfirm: (String) -> Void)
    case confirm(message: String, confirm: String, onConfirm: () -> Void)
    case password(title: String, confirm: String, onConfirm: (String) -> Void)

    var id: String {
        switch self {
        case .menu(let t, _): return "menu:" + t
        case .name(let t, _, _, _, _): return "name:" + t
        case .confirm(let m, _, _): return "confirm:" + m
        case .password(let t, _, _): return "password:" + t
        }
    }
}

private struct PresentDialogKey: EnvironmentKey {
    static let defaultValue: (OmpDialog?) -> Void = { _ in }
}

extension EnvironmentValues {
    var presentDialog: (OmpDialog?) -> Void {
        get { self[PresentDialogKey.self] }
        set { self[PresentDialogKey.self] = newValue }
    }
}

struct HomeScreen: View {
    @ObservedObject var vm: MaroViewModel
    @State private var dialog: OmpDialog?
    @State private var queueJump = 0

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height && geo.size.width >= 560
            // Sized for the column the player sits in, not the whole screen.
            let pane = landscape ? min(max(geo.size.width * 0.42, 300), 440) : geo.size.width
            let metrics = OmpMetrics(scale: min(max(pane / Omp.panelWidth + 0.25, 0.95), 1.18))
            let state = vm.state
            let shown = state.displayState()
            Group {
                if state.settingsOpen {
                    SettingsPage(state: state, vm: vm).frame(maxWidth: 640).frame(maxWidth: .infinity)
                } else if landscape {
                    HStack(alignment: .top, spacing: metrics.pt(14)) {
                        ScrollView {
                            VStack(spacing: metrics.pt(8)) {
                                playerColumn(shown)
                                StatusFooter(state: state, vm: vm)
                            }
                        }
                        .frame(width: pane)
                        VStack(spacing: metrics.pt(8)) {
                            TabsRow(state: shown, vm: vm, queueJump: $queueJump)
                            ViewArea(state: shown, vm: vm, queueJump: queueJump).frame(maxHeight: .infinity)
                        }
                    }
                    .padding(.horizontal, metrics.pt(6))
                } else {
                    VStack(spacing: metrics.pt(8)) {
                        playerColumn(shown)
                        TabsRow(state: shown, vm: vm, queueJump: $queueJump)
                        ViewArea(state: shown, vm: vm, queueJump: queueJump).frame(maxHeight: .infinity)
                        StatusFooter(state: state, vm: vm)
                    }
                    .padding(.horizontal, metrics.pt(4))
                }
            }
            // "?": over everything, under the top bar. Not modal - taps
            // outside go through - so only its button opens and closes it.
            .overlay(alignment: .topTrailing) {
                if state.statsOpen && !state.settingsOpen {
                    StatsPanel(state: shown, vm: vm)
                        .frame(maxWidth: min(pane, metrics.pt(340)))
                        .padding(.top, metrics.pt(44))
                        .padding(.horizontal, metrics.pt(8))
                        .frame(width: landscape ? pane : nil, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: landscape ? .leading : .trailing)
                }
            }
            .environment(\.omp, metrics)
        }
        .environment(\.presentDialog, { dialog = $0 })
        .background(Omp.background.ignoresSafeArea())
        .overlay { if let dialog { DialogView(dialog: dialog) { self.dialog = nil }.id(dialog.id) } }
        .overlay { if let prompt = vm.state.loginPrompt { LoginPromptView(prompt: prompt, vm: vm) } }
    }

    @ViewBuilder
    private func playerColumn(_ shown: UiState) -> some View {
        AccountStrip(state: shown, vm: vm)
        if !shown.gateText.isEmpty { GateBanner(message: shown.gateText) }
        if !shown.online { OfflineLine() }
        NowPlayingRow(state: shown, vm: vm)
        SeekRow(state: shown, vm: vm)
        TransportRow(state: shown, vm: vm)
    }
}

/**
 * The top bar: whose library this is, and settings. Where the music plays
 * is the wifi icon beside the gear, as in Spotify.
 */
private struct AccountStrip: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let spotifyName = state.spotifyAccountName.ifBlank(state.email.ifBlank("Spotify"))
        let ytmName = (state.ytmAccountName == "YouTube Music" ? "" : state.ytmAccountName).ifBlank(state.email.ifBlank("YouTube Music"))
        let accountText: String = {
            switch state.selectedAccount {
            case "spotify": return spotifyName
            case "ytm": return ytmName
            default: return state.email.ifBlank("Jukebox")
            }
        }()
        HStack(spacing: m.pt(6)) {
            // The app's own popup, not the system Menu: a Menu label is drawn
            // by UIKit, which clipped the Nerd Font cloud in half.
            OmpButton(
                icon: state.selectedAccount == "spotify" ? Omp.Icons.spotify : state.selectedAccount == "ytm" ? Omp.Icons.ytm : Omp.Icons.cloud,
                text: accountText,
                vertical: 6
            ) {
                present(.menu(title: "Account", items: [
                    .init(icon: Omp.Icons.cloud, label: state.email.ifBlank("Jukebox")) { vm.selectAccount("maro") },
                    .init(icon: Omp.Icons.spotify, label: state.spotifyConnected ? spotifyName : "Spotify not connected") { vm.selectAccount("spotify") },
                    .init(icon: Omp.Icons.ytm, label: state.ytmConnected ? ytmName : "YouTube Music not connected") { vm.selectAccount("ytm") },
                ]))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // "?": which service is really playing, how it got here, how well.
            OmpButton(
                icon: Omp.Icons.question,
                selected: vm.state.statsOpen,
                foreground: vm.state.statsOpen ? serviceColor(state.playingService) : Omp.foreground,
                vertical: 6,
                horizontal: 8
            ) { vm.toggleStats() }
            // Where the music plays, one tap away. Not there while this phone
            // plays on its own.
            if !state.solo {
            OmpButton(
                icon: Omp.Icons.broadcast,
                // Accent while this phone is the one playing.
                foreground: state.playingDeviceId == state.myDeviceId ? Omp.themeAccent : Omp.foreground,
                vertical: 6,
                horizontal: 8
            ) { present(devicePicker(state, vm)) }
            }
            OmpButton(icon: Omp.Icons.gear, selected: state.settingsOpen, vertical: 6, horizontal: 8) { vm.toggleSettings() }
        }
    }
}

private struct GateBanner: View {
    @Environment(\.omp) private var m
    let message: String

    var body: some View {
        HStack(spacing: m.pt(6)) {
            OmpIcon(Omp.Icons.warning, size: Omp.TypeSize.caption, color: Omp.urgent)
            OmpText(message, size: Omp.TypeSize.caption, color: Omp.urgent, maxLines: 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.pt(4))
    }
}

private struct OfflineLine: View {
    @Environment(\.omp) private var m

    var body: some View {
        HStack(spacing: m.pt(6)) {
            OmpIcon(Omp.Icons.wifi, size: Omp.TypeSize.caption, color: Omp.muted)
            OmpText("Offline  ·  showing what is saved on this phone", size: Omp.TypeSize.caption, color: Omp.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.pt(4))
    }
}

func serviceColor(_ service: String) -> Color {
    switch service {
    case "youtube": return Omp.ytm
    case "spotify": return Omp.spotify
    case "soundcloud": return Omp.sc
    default: return Omp.themeAccent
    }
}

/**
 * The "?" panel: the service really playing, the hop when the song is from
 * another one, how the audio arrives, the copy's per-second bitrate as a graph
 * with the playhead, and the numbers behind it.
 */
private struct StatsPanel: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    private var wantKbps: Int {
        switch state.quality {
        case "max": return 256
        case "high": return 160
        case "normal": return 128
        case "low": return 64
        default: return 0
        }
    }

    private func rows(second: Int, duration: Double) -> [(String, String)] {
        let track = state.track
        let line = state.audioTimeline.filter { $0 > 0 }
        let live: Int = {
            if second >= 0 && second < state.audioTimeline.count, state.audioTimeline[second] > 0 {
                return state.audioTimeline[second]
            }
            return state.audioKbps
        }()
        var out: [(String, String)] = []
        if let track {
            out.append(("Song", track.title + (track.artist.isEmpty ? "" : " — " + track.artist)))
            out.append(("From", track.source == "spotify" ? "Spotify library"
                                : track.source == "ytm" ? "YouTube Music library"
                                : track.source == "sc" ? "SoundCloud" : track.source))
        } else {
            out.append(("Song", "—"))
        }
        let delivery: String
        switch state.audioRoute {
        case "file": delivery = "Saved on this phone"
        case "warm asset": delivery = "Start cached on this phone, rest streaming"
        case "stream": delivery = "Streaming from your server"
        case "engine": delivery = "Streaming, resolved by your server"
        case "download": delivery = "Downloading to this phone"
        case "remote": delivery = "Playing on " + state.playingDeviceName
        case "soundcloud": delivery = "Streaming from SoundCloud"
        case "spotify": delivery = "Streaming from Spotify, on this phone"
        case "youtube": delivery = "Streaming from YouTube (guest, until the server has its copy)"
        default: delivery = "—"
        }
        out.append(("Delivery", delivery))
        if !state.audioCopy.hasPrefix("sc:") && !state.audioCopy.hasPrefix("yt:") {
            out.append(("Copy", state.audioCopy.isEmpty ? (state.audioVideoId.isEmpty ? "—" : "original") : state.audioCopy))
        }
        out.append(("Bitrate now", live > 0 ? "\(live) kbps" : "—"))
        if !line.isEmpty {
            let avg = Int((Double(line.reduce(0, +)) / Double(line.count)).rounded())
            out.append(("Avg / low / peak", "\(avg) / \(line.min() ?? 0) / \(line.max() ?? 0) kbps"))
        }
        let tier = state.audioInTier == true ? " · at it" : state.audioInTier == false ? " · below it" : ""
        out.append(("Quality", "asked for " + state.quality + tier))
        out.append(("Position", Omp.fmtTime(Double(second)) + " / " + Omp.fmtTime(duration)))
        out.append(("This device", state.deviceName.isEmpty ? "—" : state.deviceName))
        out.append(("Playing on", state.playingDeviceName))
        out.append(("Mode", state.solo ? "This phone only" : "Shared player"))
        if !state.audioVideoId.isEmpty { out.append(("YouTube id", state.audioVideoId)) }
        if state.audioCopy.hasPrefix("sc:") { out.append(("SoundCloud id", String(state.audioCopy.dropFirst(3)))) }
        if let sid = track?.sourceId, !sid.isEmpty, sid != state.audioVideoId { out.append(("Spotify id", sid)) }
        return out
    }

    var body: some View {
        let progress = vm.progress
        let service = state.playingService
        let tint = serviceColor(service)
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        TimelineView(.periodic(from: .now, by: progress.playing ? 0.5 : 3600)) { _ in
            let second = Int(progress.at(uptime()))
            let duration = progress.duration > 0 ? progress.duration : (state.track?.duration ?? 0)
            VStack(alignment: .leading, spacing: m.pt(6)) {
                HStack(spacing: m.pt(8)) {
                    Circle().fill(tint).frame(width: m.pt(10), height: m.pt(10))
                    OmpText(service == "youtube" ? "YouTube Music" : service == "spotify" ? "Spotify"
                            : service == "soundcloud" ? "SoundCloud" : "Nothing playing",
                            size: Omp.TypeSize.body, color: tint, bold: true)
                }
                if !state.gateText.isEmpty {
                    OmpText("Couldn't play: " + state.gateText, size: Omp.TypeSize.caption, color: Omp.urgent, maxLines: 3)
                } else if service == "youtube" && state.track?.source == "spotify" {
                    OmpText("This is a Spotify song, playing YouTube Music's copy of it.",
                            size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 3)
                } else if service == "soundcloud", let src = state.track?.source, src != "sc" {
                    OmpText("This is a \(src == "spotify" ? "Spotify" : "YouTube Music") song, playing SoundCloud's copy of it.",
                            size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 3)
                }
                BitrateGraph(line: state.audioTimeline, second: second, want: wantKbps, tint: tint)
                    .frame(height: m.pt(110))
                ForEach(Array(rows(second: second, duration: duration).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: m.pt(8)) {
                        OmpText(row.0, size: Omp.TypeSize.caption, color: Omp.muted)
                            .frame(width: m.pt(100), alignment: .leading)
                        OmpText(row.1, size: Omp.TypeSize.caption,
                                // A rate row leads with its number: that number's colour.
                                color: row.0 == "Bitrate now" || row.0 == "Avg / low / peak"
                                    ? Omp.kbpsColor(Int(row.1.prefix(while: { $0.isNumber })) ?? 0) : Omp.foreground,
                                maxLines: 2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(m.pt(10))
            .background(Omp.card)
            .clipShape(shape)
            .overlay(shape.stroke(tint, lineWidth: 1))
        }
    }
}

/**
 * Per-second kbps of the copy sounding: each bar that second's rate in its
 * colour (Omp.kbpsColor), bright up to the playhead. Numbers on both axes, the
 * tier chosen dashed and labelled, and the playhead says where it is and how
 * fast the audio is there.
 */
private struct BitrateGraph: View {
    let line: [Int]
    let second: Int
    let want: Int
    let tint: Color

    var body: some View {
        ZStack {
            Canvas { context, size in
                // A copy draws to the same canvas; the helpers below use it.
                var ctx = context
                let font = Omp.font(9)
                func label(_ s: String, _ color: Color) -> GraphicsContext.ResolvedText {
                    ctx.resolve(Text(s).font(font).foregroundColor(color))
                }
                let axis = label("320", Omp.foreground).measure(in: size)
                let left = axis.width + 6
                let y0 = axis.height / 2
                let w = size.width - left
                let h = size.height - (axis.height + 6) - y0
                ctx.fill(Path(CGRect(x: left, y: y0, width: w, height: h)), with: .color(Omp.foreground.opacity(0.05)))
                guard !line.isEmpty else { return }
                let peak = max(line.max() ?? 1, want, 1)
                let step = peak > 128 ? 64 : 32
                let top = Int((Double(peak) * 1.05 / Double(step)).rounded(.up)) * step
                func yOf(_ k: Int) -> CGFloat { y0 + h - CGFloat(k) / CGFloat(top) * h }
                func put(_ s: String, x: CGFloat, y: CGFloat, color: Color, align: CGFloat, backing: Bool = false) {
                    let t = label(s, color)
                    let ts = t.measure(in: size)
                    let tx = min(max(0, x - ts.width * align), size.width - ts.width)
                    if backing {
                        ctx.fill(Path(CGRect(x: tx - 4, y: y - 2, width: ts.width + 8, height: ts.height + 4)),
                                 with: .color(Color(white: 0.07).opacity(0.95)))
                    }
                    ctx.draw(t, in: CGRect(x: tx, y: y, width: ts.width, height: ts.height))
                }
                var g = 0
                while g <= top {
                    let gy = yOf(g)
                    var p = Path(); p.move(to: CGPoint(x: left, y: gy)); p.addLine(to: CGPoint(x: left + w, y: gy))
                    ctx.stroke(p, with: .color(Omp.foreground.opacity(g == 0 ? 0.35 : 0.12)), lineWidth: 1)
                    put("\(g)", x: left - 4, y: gy - axis.height / 2, color: Omp.foreground.opacity(0.55), align: 1)
                    g += step
                }
                let bw = w / CGFloat(line.count)
                for (i, k) in line.enumerated() where k > 0 {
                    let by = yOf(k)
                    let rect = CGRect(x: left + CGFloat(i) * bw, y: by, width: max(1, bw - 0.5), height: y0 + h - by)
                    ctx.fill(Path(rect), with: .color(Omp.kbpsColor(k).opacity(i <= second ? 0.9 : 0.3)))
                }
                if want > 0 {
                    let wy = yOf(want)
                    var p = Path(); p.move(to: CGPoint(x: left, y: wy)); p.addLine(to: CGPoint(x: left + w, y: wy))
                    ctx.stroke(p, with: .color(Omp.foreground.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    put("asked \(want)", x: left + w - 4, y: wy - axis.height - 3, color: Omp.foreground, align: 1, backing: true)
                }
                let ty = y0 + h + 3
                put(Omp.fmtTime(0), x: left, y: ty, color: Omp.foreground.opacity(0.55), align: 0)
                put(Omp.fmtTime(Double(line.count) / 2), x: left + w / 2, y: ty, color: Omp.foreground.opacity(0.55), align: 0.5)
                put(Omp.fmtTime(Double(line.count)), x: left + w, y: ty, color: Omp.foreground.opacity(0.55), align: 1)
                let x = left + min(w - 1, CGFloat(second) / CGFloat(line.count) * w)
                var ph = Path(); ph.move(to: CGPoint(x: x, y: y0)); ph.addLine(to: CGPoint(x: x, y: y0 + h))
                ctx.stroke(ph, with: .color(Omp.foreground), lineWidth: 1)
                let here = line[min(line.count - 1, max(0, second))]
                put(Omp.fmtTime(Double(second)) + (here > 0 ? "  \(here) kbps" : ""), x: x, y: y0,
                    color: here > 0 ? Omp.kbpsColor(here) : Omp.foreground, align: 0.5, backing: true)
            }
            if line.isEmpty {
                OmpText("No bitrate data yet", size: Omp.TypeSize.caption, color: Omp.muted)
            }
        }
    }
}

/**
 * The bitrate of what is sounding, at this second of the song, on whichever
 * device is playing it: the droplet's per-second kbps of that exact copy, read
 * at the playhead. Before the timeline arrives it is the copy's average.
 * Coloured by how high it is (Omp.kbpsColor), the same scale everywhere.
 */
private struct LiveBitrate: View {
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
                OmpText((separator ? "  ·  " : "") + "\(kbps) kbps", size: Omp.TypeSize.caption,
                        color: Omp.kbpsColor(kbps))
            }
        }
    }
}

private struct NowPlayingRow: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let track = state.track
        HStack(spacing: m.pt(10)) {
            // The border is the service the sound is really from: red YouTube,
            // green Spotify - the same colour as the playing row.
            CoverArt(
                track: track,
                icon: Omp.sourceIcon(track?.source ?? ""),
                size: Omp.nowArt,
                busy: track.map { state.artworkProgress[$0.artKey] != nil } ?? false
            )
            .overlay(
                RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
                    .stroke(track != nil && !state.playingService.isEmpty
                            ? serviceColor(state.playingService) : Color.clear,
                            lineWidth: m.pt(2))
            )
            VStack(alignment: .leading, spacing: m.pt(2)) {
                HStack(spacing: m.pt(6)) {
                    OmpText(track?.title.ifBlank("Nothing playing") ?? "Nothing playing", size: Omp.TypeSize.subtitle, bold: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HeartButton(liked: state.isLiked(track), enabled: track != nil) { if let track { vm.likeTrack(track) } }
                }
                if let track, !track.artist.isEmpty {
                    OmpText(track.artist, size: Omp.TypeSize.bodySmall, color: Omp.muted)
                }
                if !state.loadingKey.isEmpty {
                    HStack(spacing: m.pt(5)) {
                        OmpSpinner(size: Omp.TypeSize.caption, color: Omp.accent)
                        OmpText(state.loadingStage.ifBlank("Loading…"), size: Omp.TypeSize.caption, color: Omp.accent)
                    }
                } else if let track {
                    // No platform word: it named where the song is from, not
                    // where the sound is. The cover border and "?" say that.
                    let meta = track.album
                    HStack(spacing: 0) {
                        if !meta.isEmpty { OmpText(meta, size: Omp.TypeSize.caption, color: Omp.muted) }
                        LiveBitrate(state: state, vm: vm, separator: !meta.isEmpty)
                    }
                }
            }
        }
        .frame(height: m.pt(68))
    }
}

/**
 * The playhead. It runs off the view model's progress on its own clock via
 * TimelineView, so nothing else on screen redraws while a song plays.
 */
private struct SeekRow: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let progress = vm.progress
        TimelineView(.periodic(from: .now, by: progress.playing ? 0.25 : 3600)) { _ in
            let now = uptime()
            let duration = progress.duration > 0 ? progress.duration : state.track?.duration ?? 0
            let enabled = state.isCurrent && duration > 0
            let at = progress.at(now)
            HStack(spacing: m.pt(8)) {
                OmpText(Omp.fmtTime(at), size: Omp.TypeSize.caption).frame(width: m.pt(38), alignment: .leading)
                OmpSlider(fraction: duration > 0 ? at / duration : 0, enabled: enabled, glow: progress.playing ? 1 : 0.5) { f in
                    if enabled { vm.seek(duration * f) }
                }
                OmpText(Omp.fmtTime(duration), size: Omp.TypeSize.caption).frame(width: m.pt(38), alignment: .leading)
            }
        }
    }
}

private struct TransportRow: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(spacing: m.pt(3)) {
            HStack {
                Spacer()
                OmpButton(icon: Omp.Icons.restart, enabled: state.isCurrent, vertical: 6) { vm.restart() }
                Spacer()
                OmpButton(icon: Omp.Icons.prev, enabled: state.isCurrent, vertical: 6) { vm.previous() }
                Spacer()
                OmpButton(
                    icon: state.playing ? Omp.Icons.pause : Omp.Icons.play,
                    enabled: state.isCurrent || !state.queue.isEmpty,
                    fontSize: Omp.TypeSize.subtitle,
                    vertical: 6,
                    horizontal: 10
                ) { vm.playPause() }
                Spacer()
                OmpButton(icon: Omp.Icons.next, enabled: state.isCurrent, vertical: 6) { vm.next() }
                Spacer()
                OmpButton(
                    icon: Omp.Icons.shuffle,
                    selected: state.shuffle,
                    enabled: state.queue.count > 1,
                    foreground: state.shuffle ? Omp.accent : Omp.muted,
                    vertical: 6
                ) { vm.toggleShuffle() }
                Spacer()
                OmpButton(
                    icon: state.repeat == "one" ? Omp.Icons.repeat1 : Omp.Icons.repeat,
                    text: state.repeat == "one" ? "1" : "",
                    selected: state.repeat != "off",
                    foreground: state.repeat == "off" ? Omp.muted : Omp.accent,
                    vertical: 6
                ) {
                    vm.setRepeat(state.repeat == "off" ? "all" : state.repeat == "all" ? "one" : "off")
                }
                Spacer()
            }
            HStack(spacing: m.pt(8)) {
                Button { vm.setVolume(state.volume > 0 ? 0 : 100) } label: {
                    OmpIcon(state.volume <= 0 ? Omp.Icons.volMute : state.volume < 50 ? Omp.Icons.volLow : Omp.Icons.volHigh)
                        .frame(width: m.pt(26), height: m.pt(26))
                }
                .buttonStyle(.plain)
                OmpSlider(fraction: Double(state.volume) / 100) { f in vm.setVolume(Int((f * 100).rounded())) }
                OmpText("\(state.volume)%", size: Omp.TypeSize.caption, color: Omp.muted).frame(width: m.pt(38), alignment: .leading)
            }
            .padding(.horizontal, m.pt(4))
        }
    }
}

private struct TabsRow: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @Binding var queueJump: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: m.pt(4)) {
                ForEach(tabs, id: \.key) { tab in
                    OmpButton(text: tab.label, selected: state.view == tab.key, vertical: 5, horizontal: 6) {
                        // Queue tapped while showing: back to the current song.
                        if tab.key == Sync.viewQueue && state.view == Sync.viewQueue { queueJump += 1 }
                        vm.selectTab(tab.key)
                    }
                }
            }
        }
    }
}

private struct StatusFooter: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        if !state.statusMsg.isEmpty {
            let error = state.statusKind == "error"
            HStack(spacing: m.pt(8)) {
                OmpIcon(error ? Omp.Icons.warning : Omp.Icons.gear, size: Omp.TypeSize.caption, color: error ? Omp.urgent : Omp.accent)
                OmpText(state.statusMsg, size: Omp.TypeSize.caption, color: error ? Omp.urgent : Omp.foreground, maxLines: 2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, m.pt(4))
            .contentShape(Rectangle())
            .onTapGesture { vm.clearStatus() }
            .task(id: state.statusMsg) {
                await sleep(seconds: error ? 8 : 4)
                if !Task.isCancelled { vm.clearStatus() }
            }
        }
    }
}

/** The Omp card popups: a dimmed backdrop, a bordered card, tap outside to close. */
private struct DialogView: View {
    @Environment(\.omp) private var m
    let dialog: OmpDialog
    let dismiss: () -> Void
    @State private var text = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: 360)
                .background(Omp.card, in: RoundedRectangle(cornerRadius: Omp.labelGap))
                .overlay(RoundedRectangle(cornerRadius: Omp.labelGap).stroke(Omp.borderColor, lineWidth: 1))
                .padding(24)
        }
        .onAppear { if case .name(_, _, _, let initial, _) = dialog { text = initial } }
    }

    @ViewBuilder
    private var content: some View {
        switch dialog {
        case .menu(let title, let items):
            OmpText(title, size: Omp.TypeSize.caption, color: Omp.muted)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                Button {
                    item.action()
                    if item.closes { dismiss() }
                } label: {
                    HStack(spacing: 12) {
                        OmpIcon(item.icon, color: item.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            OmpText(item.label, color: item.tint, bold: item.bold)
                            if !item.detail.isEmpty { OmpText(item.detail, size: Omp.TypeSize.caption, color: Omp.muted) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer().frame(height: 8)
        case .name(let title, let placeholder, let confirm, _, let onConfirm):
            let submit = { if !text.isBlank { onConfirm(text.trimmingCharacters(in: .whitespaces)); dismiss() } }
            VStack(alignment: .leading, spacing: 8) {
                OmpText(title, size: Omp.TypeSize.caption, color: Omp.muted)
                OmpTextField(text: $text, placeholder: placeholder, onSubmit: submit)
                HStack(spacing: 4) {
                    OmpButton(text: confirm, enabled: !text.isBlank, foreground: Omp.accent, bordered: true, action: submit)
                    OmpButton(text: "Cancel", action: dismiss)
                }
            }
            .padding(10)
        case .password(let title, let confirm, let onConfirm):
            // Not trimmed: a password's spaces are part of it.
            let submit = { if !text.isEmpty { onConfirm(text); dismiss() } }
            VStack(alignment: .leading, spacing: 8) {
                OmpText(title, size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 3)
                OmpTextField(text: $text, placeholder: "Password", password: true, onSubmit: submit)
                HStack(spacing: 4) {
                    OmpButton(text: confirm, enabled: !text.isEmpty, foreground: Omp.accent, bordered: true, action: submit)
                    OmpButton(text: "Cancel", action: dismiss)
                }
            }
            .padding(10)
        case .confirm(let message, let confirm, let onConfirm):
            VStack(alignment: .leading, spacing: 10) {
                OmpText(message, maxLines: 4)
                HStack(spacing: 4) {
                    OmpButton(text: confirm, foreground: Omp.urgent, bordered: true) { onConfirm(); dismiss() }
                    OmpButton(text: "Cancel", action: dismiss)
                }
            }
            .padding(10)
        }
    }
}

/**
 * A sign-in the cloud engine started for this phone. YouTube Music signs in
 * with a code approved on Google's page; Spotify's page (opened already) does
 * it all, so this only says what is going on.
 */
private struct LoginPromptView: View {
    let prompt: LoginPrompt
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let label = prompt.service == "spotify" ? "Spotify" : "YouTube Music"
        let body = !prompt.error.isEmpty ? prompt.error
            : !prompt.code.isEmpty ? "Open Google's page, sign in with the Google account you use for YouTube Music, and enter this code:"
            : "Finish signing in on the Spotify page that just opened, then come back here."
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { vm.dismissLogin() }
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect \(label)").font(Omp.font(17, bold: true)).foregroundColor(Omp.foreground)
                Text(body).font(Omp.font(14)).foregroundColor(prompt.error.isEmpty ? Omp.muted : Omp.urgent)
                if !prompt.code.isEmpty {
                    Text(prompt.code).font(Omp.font(26, bold: true)).foregroundColor(Omp.foreground)
                        .frame(maxWidth: .infinity).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if !prompt.code.isEmpty {
                        button("Copy code", filled: false) {
                            UIPasteboard.general.string = prompt.code
                            vm.showStatus("Code copied", "ok")
                        }
                    }
                    if !prompt.url.isEmpty && prompt.error.isEmpty {
                        button(prompt.code.isEmpty ? "Open again" : "Open Google", filled: true) { vm.openUrl(prompt.url) }
                    }
                }
                button(prompt.error.isEmpty ? "Done" : "Close", filled: false) { vm.dismissLogin() }
            }
            .padding(20)
            .background(Omp.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Omp.softDk, lineWidth: 1))
            .padding(24)
        }
    }

    private func button(_ text: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Omp.font(14)).foregroundColor(filled ? .white : Omp.foreground)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(filled ? Omp.themeAccent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(filled ? Omp.themeAccent : Omp.borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
