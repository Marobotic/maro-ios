import SwiftUI

/** The tab row: the desktop's order, then the phone's own list of saved songs. */
private let tabs: [(key: String, label: String)] = [
    (Sync.viewQueue, "Queue"),
    (Sync.viewLyrics, "Lyrics"),
    (Sync.viewPlaylists, "Library"),
    (Sync.viewRecent, "Recent"),
    (Sync.viewDiscover, "Discover"),
    (Sync.viewSearch, "Search"),
    (Sync.viewSongs, "Songs"),
]

private func deviceLabel(_ device: Device) -> String {
    if !device.name.isBlank { return device.name }
    return device.kind == "phone" ? "Phone" : "Desktop"
}

/** Every connected device; the one playing now in accent-soft, the rest grey. */
@MainActor
func devicePicker(_ state: UiState, _ vm: MaroViewModel) -> OmpDialog {
    .menu(title: "Play on", items: state.pickerDevices().map { device in
        OmpDialog.Item(
            icon: .wifi,
            label: deviceLabel(device),
            tint: device.isPlayback ? Omp.soft : Omp.t2,
            detail: device.id == state.myDeviceId ? "This phone" : "",
            bold: device.isPlayback
        ) { if !device.isPlayback { vm.selectDevice(device) } }
    })
}

/** The app's popups (menus, name prompts, confirmations) share one host. */
enum OmpDialog: Identifiable {
    struct Item {
        let icon: Glyph?
        let label: String
        var closes = true
        var tint: Color = Omp.foreground
        var detail = ""
        var bold = false
        let action: () -> Void
    }

    case menu(title: String, items: [Item])
    /** A song's menu: its cover, title and artist on top. */
    case songMenu(track: Track, items: [Item])
    case name(title: String, placeholder: String, confirm: String, initial: String, onConfirm: (String) -> Void)
    case confirm(message: String, confirm: String, onConfirm: () -> Void)
    case password(title: String, confirm: String, onConfirm: (String) -> Void)

    var id: String {
        switch self {
        case .menu(let t, _): return "menu:" + t
        case .songMenu(let t, _): return "song:" + t.source + ":" + t.id
        case .name(let t, _, _, _, _): return "name:" + t
        case .confirm(let m, _, _): return "confirm:" + m
        case .password(let t, _, _): return "password:" + t
        }
    }
}

private struct PresentDialogKey: EnvironmentKey {
    static let defaultValue: (OmpDialog?) -> Void = { _ in }
}

private struct OpenJamKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var presentDialog: (OmpDialog?) -> Void {
        get { self[PresentDialogKey.self] }
        set { self[PresentDialogKey.self] = newValue }
    }

    /** Opens the full-screen view (lyrics and cover). */
    var openJam: () -> Void {
        get { self[OpenJamKey.self] }
        set { self[OpenJamKey.self] = newValue }
    }
}

/**
 * The redesign's frame. Phone: the top strip, the main tile (tab row and the
 * open tab), and the player tile at the bottom. Wide (landscape): the queue
 * tile above the full player on the left and the main tile on the right, as
 * the Windows app lays it out.
 */
struct HomeScreen: View {
    @ObservedObject var vm: MaroViewModel
    @State private var dialog: OmpDialog?
    @State private var queueJump = 0
    @State private var jamOpen = false
    @AppStorage("jb.playerMini") private var playerMini = true

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height && geo.size.width >= 560
            let state = vm.state
            let shown = state.displayState()
            Group {
                if state.settingsOpen {
                    SettingsPage(state: state, vm: vm).frame(maxWidth: 860).frame(maxWidth: .infinity)
                } else if wide {
                    VStack(spacing: 8) {
                        Strip(state: shown, vm: vm)
                        HStack(spacing: 8) {
                            VStack(spacing: 8) {
                                ViewArea(state: shown, vm: vm, queueJump: queueJump)
                                    .environment(\.queueOnly, true)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 2)
                                    .padding(.bottom, 8)
                                    .frame(maxHeight: .infinity)
                                    .tile()
                                PlayerTile(state: shown, vm: vm, mini: false)
                            }
                            .frame(width: min(max(geo.size.width * 0.38, 320), 460))
                            MainTile(state: shown, vm: vm, queueJump: $queueJump, wide: true)
                        }
                    }
                    .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Strip(state: shown, vm: vm)
                        MainTile(state: shown, vm: vm, queueJump: $queueJump, wide: false)
                        PlayerTile(state: shown, vm: vm, mini: playerMini) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { playerMini.toggle() }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    // Down to just above the home indicator, not a whole inset
                    // short of it (34 pt of empty page on an iPhone 13).
                    .padding(.bottom, max(6, geo.safeAreaInsets.bottom - 20))
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
            // The "i" panel: over everything, under the strip. Not modal - taps
            // outside go through - so only its button opens and closes it.
            .overlay(alignment: .topTrailing) {
                if state.statsOpen && !state.settingsOpen {
                    StatsPanel(state: shown, vm: vm)
                        .frame(maxWidth: min(geo.size.width - 24, 340))
                        .padding(.top, wide ? 66 : 62)
                        .padding(.horizontal, 12)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.statsOpen)
        }
        .environment(\.presentDialog, { dialog = $0 })
        .environment(\.openJam, { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5)) { jamOpen = true } })
        .background(Omp.page.ignoresSafeArea())
        .overlay {
            if jamOpen {
                JamView(state: vm.state.displayState(), vm: vm) {
                    withAnimation(.easeOut(duration: 0.25)) { jamOpen = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .overlay { if let dialog { DialogView(dialog: dialog) { self.dialog = nil }.id(dialog.id) } }
        .onChange(of: vm.jamRequest) { withAnimation(.easeOut(duration: 0.3)) { jamOpen = true } }
        .overlay { if let prompt = vm.state.loginPrompt { LoginPromptView(prompt: prompt, vm: vm) } }
    }
}

private struct QueueOnlyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /** The wide layout's queue tile: the view area shows the queue whatever tab is open. */
    var queueOnly: Bool {
        get { self[QueueOnlyKey.self] }
        set { self[QueueOnlyKey.self] = newValue }
    }
}

/** The main tile: the tab row, any notices, then the open tab; status messages float at its foot. */
private struct MainTile: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @Binding var queueJump: Int
    let wide: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabsRow(state: state, vm: vm, queueJump: $queueJump, wide: wide)
                .padding(.horizontal, wide ? 20 : 10)
                .padding(.top, wide ? 14 : 10)
            if !state.gateText.isEmpty { Notice(glyph: .warning, text: state.gateText, color: Omp.urgent) }
            if !state.online { Notice(glyph: .wifi, text: "Offline · showing what is saved on this phone", color: Omp.t3) }
            ViewArea(state: state, vm: vm, queueJump: queueJump, wide: wide)
                .padding(.horizontal, wide ? 20 : 10)
                .padding(.top, wide ? 12 : 10)
                .padding(.bottom, wide ? 16 : 12)
                .frame(maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tile()
        .overlay(alignment: .bottom) { Toast(state: state, vm: vm) }
    }
}

/** A line under the tabs: why a song could not play, or that the phone is offline. */
private struct Notice: View {
    let glyph: Glyph
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Icon(glyph, size: 12, color: color)
            OmpText(text, size: 11, color: color, maxLines: 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

/**
 * The top strip: the logo and whose library this is (a tap picks the account),
 * then playback stats, where the music plays, and settings.
 */
private struct Strip: View {
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
        HStack(spacing: 12) {
            Button {
                present(.menu(title: "Account", items: [
                    .init(icon: .pixelNote, label: state.email.ifBlank("Jukebox"), tint: state.selectedAccount == "maro" ? Omp.soft : Omp.foreground) { vm.selectAccount("maro") },
                    .init(icon: .spotify, label: state.spotifyConnected ? spotifyName : "Spotify not connected",
                          tint: state.selectedAccount == "spotify" ? Omp.soft : Omp.foreground) { vm.selectAccount("spotify") },
                    .init(icon: .ytm, label: state.ytmConnected ? ytmName : "YouTube Music not connected",
                          tint: state.selectedAccount == "ytm" ? Omp.soft : Omp.foreground) { vm.selectAccount("ytm") },
                ]))
            } label: {
                HStack(spacing: 12) {
                    Image("LaunchNote").resizable().scaledToFit().frame(width: 24, height: 24)
                    OmpText(accountText, size: 12, color: Omp.t2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                StripButton(glyph: .info, on: state.statsOpen) { vm.toggleStats() }
                // Where the music plays, one tap away. Not there while this
                // phone plays on its own. Accent-soft while this phone plays.
                if !state.solo {
                    StripButton(glyph: .wifi, color: state.playingDeviceId == state.myDeviceId ? Omp.soft : Omp.t2) {
                        present(devicePicker(state, vm))
                    }
                }
                StripButton(glyph: .gear, on: state.settingsOpen) { vm.toggleSettings() }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
        .tile()
    }
}

/** The strip's 36 pt icon button (.ibtn). */
private struct StripButton: View {
    let glyph: Glyph
    var on = false
    var color: Color = Omp.t2
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(glyph, size: 18, color: on ? Omp.foreground : color)
                .frame(width: 36, height: 36)
                .background(on ? Omp.hover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.9))
    }
}

/**
 * The tabs, bold: the open one white on the #262626 pill that slides to it,
 * the rest grey. The row scrolls sideways when it does not fit; tapping Queue
 * again goes back to the song playing.
 */
private struct TabsRow: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @Binding var queueJump: Int
    let wide: Bool
    @Namespace private var pill

    var body: some View {
        // Round 2 L: an empty queue hides Queue, no lyrics hides Lyrics; both come back by themselves.
        let emptyQueue = state.displayState().queue.isEmpty
        let shownTabs = tabs.filter { tab in
            if tab.key == Sync.viewQueue { return !wide && !emptyQueue }
            if tab.key == Sync.viewLyrics { return !state.noLyrics }
            return true
        }
        let selected = wide && state.view == Sync.viewQueue ? Sync.viewLyrics : state.view
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: wide ? 4 : 2) {
                    ForEach(shownTabs, id: \.key) { tab in
                        let on = selected == tab.key
                        Button {
                            if tab.key == Sync.viewQueue && state.view == Sync.viewQueue {
                                queueJump += 1
                            } else {
                                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)) { vm.selectTab(tab.key) }
                            }
                        } label: {
                            OmpText(tab.label, size: wide ? 12.5 : 11.5, color: on ? .white : Omp.t2, bold: true)
                                .padding(.horizontal, wide ? 14 : 4)
                                .frame(height: 32)
                                .background {
                                    if on { Omp.pill.matchedGeometryEffect(id: "pill", in: pill) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(tab.key)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: shownTabs.map { $0.key })
            }
            .onAppear { proxy.scrollTo(selected) }
            .onChange(of: selected) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(selected) } }
        }
        .frame(height: 32)
    }
}

/**
 * Status messages as the desktop's toast: a #1C1C1C box with the accent
 * border and a small accent square, at the foot of the main tile. A tap or a
 * few seconds put it away.
 */
private struct Toast: View {
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let msg = vm.state.statusMsg
        let error = vm.state.statusKind == "error"
        ZStack {
            if !msg.isEmpty {
                HStack(spacing: 11) {
                    Rectangle().fill(error ? Color(hex: 0xD66E36) : Omp.themeAccent).frame(width: 7, height: 7)
                    OmpText(msg, size: 11.5, color: error ? Color(hex: 0xFFB07A) : Color(hex: 0xE8E8E8), maxLines: 3)
                }
                .padding(.vertical, 11)
                .padding(.leading, 14)
                .padding(.trailing, 18)
                .background(Color(hex: 0x1C1C1C))
                .overlay(Rectangle().strokeBorder(error ? Color(hex: 0xD66E36) : Omp.themeAccent, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 15, y: 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .onTapGesture { vm.clearStatus() }
                .task(id: msg) {
                    await sleep(seconds: error ? 8 : 4)
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { vm.clearStatus() } }
                }
                .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3), value: msg)
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
 * The "i" panel: the service really playing, the hop when the song is from
 * another one, how the audio arrives, the copy's per-second bitrate as a graph
 * with the playhead, and the numbers behind it.
 */
private struct StatsPanel: View {
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
        let shape = RoundedRectangle(cornerRadius: 4)
        TimelineView(.periodic(from: .now, by: progress.playing ? 0.5 : 3600)) { _ in
            let second = Int(progress.at(uptime()))
            let duration = progress.duration > 0 ? progress.duration : (state.track?.duration ?? 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Rectangle().fill(tint).frame(width: 8, height: 8)
                    OmpText(service == "youtube" ? "YouTube Music" : service == "spotify" ? "Spotify"
                            : service == "soundcloud" ? "SoundCloud" : "Nothing playing",
                            size: 12, color: Omp.foreground, bold: true)
                }
                if !state.gateText.isEmpty {
                    OmpText("Couldn't play: " + state.gateText, size: 11, color: Omp.urgent, maxLines: 3)
                } else if service == "youtube" && state.track?.source == "spotify" {
                    OmpText("This is a Spotify song, playing YouTube Music's copy of it.", size: 11, color: Omp.t3, maxLines: 3)
                } else if service == "soundcloud", let src = state.track?.source, src != "sc" {
                    OmpText("This is a \(src == "spotify" ? "Spotify" : "YouTube Music") song, playing SoundCloud's copy of it.",
                            size: 11, color: Omp.t3, maxLines: 3)
                }
                BitrateGraph(line: state.audioTimeline, second: second, want: wantKbps, tint: tint)
                    .frame(height: 110)
                VStack(spacing: 0) {
                    ForEach(Array(rows(second: second, duration: duration).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 8) {
                            OmpText(row.0, size: 11, color: Omp.t3)
                                .frame(width: 108, alignment: .leading)
                            OmpText(row.1, size: 11,
                                    // A rate row leads with its number: that number's colour.
                                    color: row.0 == "Bitrate now" || row.0 == "Avg / low / peak"
                                        ? Omp.kbpsColor(Int(row.1.prefix(while: { $0.isNumber })) ?? 0) : Color(hex: 0xDDDDDD),
                                    maxLines: 2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) { Rectangle().fill(Omp.line).frame(height: 1) }
                    }
                }
            }
            .padding(16)
            .background(Omp.popup)
            .clipShape(shape)
            .overlay(shape.stroke(Omp.themeAccent, lineWidth: 1))
            .shadow(color: .black.opacity(0.85), radius: 22, y: 18)
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
                OmpText("No bitrate data yet", size: 11, color: Omp.t3)
            }
        }
    }
}

/**
 * The popups as the desktop draws them: menus in a #161616 box with the
 * accent border and 4 pt corners, prompts and confirmations as #141414 cards
 * with the accent border, over a dark backdrop. A tap outside closes them.
 */
private struct DialogView: View {
    let dialog: OmpDialog
    let dismiss: () -> Void
    @State private var text = ""
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture(perform: dismiss)
            content
                .scaleEffect(shown ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
                .padding(16)
        }
        .onAppear {
            if case .name(_, _, _, let initial, _) = dialog { text = initial }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { shown = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dialog {
        case .menu(let title, let items):
            menuBox {
                OmpText(title, size: 12, color: Omp.foreground, bold: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .frame(minHeight: 36, alignment: .leading)
            } items: { items }
        case .songMenu(let track, let items):
            menuBox {
                HStack(spacing: 10) {
                    CoverArt(track: track, icon: Omp.sourceGlyph(track.source), size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        OmpText(track.title.ifBlank(track.id), size: 12, color: Omp.foreground, bold: true)
                        if !track.artist.isEmpty { OmpText(track.artist, size: 10.5, color: Omp.t3) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(minHeight: 48)
            } items: { items }
        case .name(let title, let placeholder, let confirm, _, let onConfirm):
            let submit = { if !text.isBlank { onConfirm(text.trimmingCharacters(in: .whitespaces)); dismiss() } }
            card {
                OmpText(title, size: 16, color: Omp.foreground, bold: true)
                OmpTextField(text: $text, placeholder: placeholder, onSubmit: submit)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    MButton("Cancel", action: dismiss)
                    MButton(confirm, kind: .primary, enabled: !text.isBlank, action: submit)
                }
                .padding(.top, 8)
            }
        case .password(let title, let confirm, let onConfirm):
            // Not trimmed: a password's spaces are part of it.
            let submit = { if !text.isEmpty { onConfirm(text); dismiss() } }
            card {
                OmpText(title, size: 12, color: Omp.t2, maxLines: 4)
                OmpTextField(text: $text, placeholder: "Password", password: true, onSubmit: submit)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    MButton("Cancel", action: dismiss)
                    MButton(confirm, kind: .primary, enabled: !text.isEmpty, action: submit)
                }
                .padding(.top, 8)
            }
        case .confirm(let message, let confirm, let onConfirm):
            card(gap: 22) {
                OmpText(message, size: 14, color: Omp.foreground, maxLines: 6)
                    .lineSpacing(5)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    MButton("Cancel", action: dismiss)
                    MButton(confirm, kind: .danger) { onConfirm(); dismiss() }
                }
            }
        }
    }

    private func menuBox<Head: View>(@ViewBuilder head: () -> Head, items: () -> [OmpDialog.Item]) -> some View {
        let list = items()
        let shape = RoundedRectangle(cornerRadius: 4)
        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach(list.indices, id: \.self) { i in
                menuRow(list[i])
            }
        }
        return VStack(alignment: .leading, spacing: 2) {
            head()
            // Unscrolled when it fits (a phone held upright), scrolling when not.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
        }
        .padding(6)
        .frame(maxWidth: 300)
        .background(Omp.row)
        .clipShape(shape)
        .overlay(shape.stroke(Omp.themeAccent, lineWidth: 1))
        .shadow(color: .black.opacity(0.85), radius: 22, y: 18)
    }

    private func menuRow(_ item: OmpDialog.Item) -> some View {
        Button {
            item.action()
            if item.closes { dismiss() }
        } label: {
            HStack(spacing: 12) {
                if let icon = item.icon {
                    Icon(icon, size: 14, color: item.tint == Omp.foreground ? Omp.t3 : item.tint)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    OmpText(item.label, size: 12, color: item.tint, bold: item.bold)
                    if !item.detail.isEmpty { OmpText(item.detail, size: 10.5, color: Omp.t3) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuItemStyle())
    }

    private func card<Content: View>(gap: CGFloat = 14, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: gap) { content() }
            .padding(24)
            .frame(maxWidth: 420)
            .background(Omp.popup)
            .overlay(Rectangle().strokeBorder(Omp.themeAccent, lineWidth: 1))
            .shadow(color: .black.opacity(0.72), radius: 25, y: 18)
    }
}

/** A menu row lights up in the accent while pressed. */
private struct MenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Omp.themeAccent.opacity(0.28) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
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
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { vm.dismissLogin() }
            VStack(alignment: .leading, spacing: 14) {
                OmpText("Connect \(label)", size: 16, color: Omp.foreground, bold: true)
                OmpText(body, size: 12, color: prompt.error.isEmpty ? Omp.t2 : Omp.urgent, maxLines: 6)
                    .lineSpacing(5)
                if !prompt.code.isEmpty {
                    Text(prompt.code).font(Omp.font(26, bold: true)).foregroundColor(Omp.foreground)
                        .frame(maxWidth: .infinity).textSelection(.enabled)
                        .padding(.vertical, 6)
                }
                HStack(spacing: 8) {
                    if !prompt.code.isEmpty {
                        MButton("Copy code", small: false, expand: true) {
                            UIPasteboard.general.string = prompt.code
                            vm.showStatus("Code copied", "ok")
                        }
                    }
                    if !prompt.url.isEmpty && prompt.error.isEmpty {
                        MButton(prompt.code.isEmpty ? "Open again" : "Open Google", kind: .primary, small: false, expand: true) {
                            vm.openUrl(prompt.url)
                        }
                    }
                }
                MButton(prompt.error.isEmpty ? "Done" : "Close", small: false, expand: true) { vm.dismissLogin() }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(Omp.popup)
            .overlay(Rectangle().strokeBorder(Omp.themeAccent, lineWidth: 1))
            .padding(16)
        }
    }
}
