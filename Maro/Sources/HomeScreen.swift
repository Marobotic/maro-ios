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

/** The Omp-styled popups (menus, name prompts, confirmations) share one host. */
enum OmpDialog: Identifiable {
    struct Item {
        let icon: String
        let label: String
        var closes = true
        let action: () -> Void
    }

    case menu(title: String, items: [Item])
    case name(title: String, placeholder: String, confirm: String, initial: String, onConfirm: (String) -> Void)
    case confirm(message: String, confirm: String, onConfirm: () -> Void)

    var id: String {
        switch self {
        case .menu(let t, _): return "menu:" + t
        case .name(let t, _, _, _, _): return "name:" + t
        case .confirm(let m, _, _): return "confirm:" + m
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
            .environment(\.omp, metrics)
        }
        .environment(\.presentDialog, { dialog = $0 })
        .background(Omp.background.ignoresSafeArea())
        .overlay { if let dialog { DialogView(dialog: dialog) { self.dialog = nil }.id(dialog.id) } }
    }

    @ViewBuilder
    private func playerColumn(_ shown: UiState) -> some View {
        AccountStrip(state: shown, vm: vm)
        if !shown.gateText.isEmpty { GateBanner(message: shown.gateText) }
        if !shown.online { OfflineLine() }
        NowPlayingRow(state: shown, vm: vm)
        SeekRow(state: shown, vm: vm)
        TransportRow(state: shown, vm: vm)
        DeviceRow(state: shown, vm: vm)
    }
}

/**
 * The top bar: whose library this is, and settings. Where the music plays
 * lives under the controls instead (DeviceRow), as in Spotify.
 */
private struct AccountStrip: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let spotifyName = state.spotifyAccountName.ifBlank(state.email.ifBlank("Spotify"))
        let ytmName = (state.ytmAccountName == "YouTube Music" ? "" : state.ytmAccountName).ifBlank(state.email.ifBlank("YouTube Music"))
        let accountText: String = {
            switch state.selectedAccount {
            case "spotify": return spotifyName
            case "ytm": return ytmName
            default: return state.email.ifBlank("Omarchy Music Plugin")
            }
        }()
        HStack(spacing: m.pt(6)) {
            Menu {
                Button(state.email.ifBlank("Omarchy Music Plugin")) { vm.selectAccount("maro") }
                Button(state.spotifyConnected ? spotifyName : "Spotify not connected") { vm.selectAccount("spotify") }
                Button(state.ytmConnected ? ytmName : "YouTube Music not connected") { vm.selectAccount("ytm") }
            } label: {
                HStack(spacing: m.pt(7)) {
                    OmpIcon(state.selectedAccount == "spotify" ? Omp.Icons.spotify : state.selectedAccount == "ytm" ? Omp.Icons.ytm : Omp.Icons.cloud)
                    OmpText(accountText)
                }
                .padding(.horizontal, m.pt(8))
                .padding(.vertical, m.pt(6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OmpButton(icon: Omp.Icons.gear, selected: state.settingsOpen, vertical: 6, horizontal: 8) { vm.toggleSettings() }
        }
    }
}

/**
 * Where the music is coming out: this phone, or another device it is
 * remote-controlling. Tapping it lists every device connected right now.
 */
private struct DeviceRow: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let here = state.playingDeviceId == state.myDeviceId
        let tint = here ? Omp.foreground : Omp.maro
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        Menu {
            ForEach(state.pickerDevices(), id: \.self) { device in
                let me = device.id == state.myDeviceId
                Button {
                    if !device.isPlayback { vm.selectDevice(device) }
                } label: {
                    if device.isPlayback {
                        Label(deviceLabel(device), systemImage: "checkmark")
                    } else {
                        Text(deviceLabel(device))
                    }
                    if me { Text("This phone") }
                }
            }
        } label: {
            // A real button, like Spotify's device picker: bordered, always here.
            HStack(spacing: m.pt(8)) {
                OmpIcon(Omp.Icons.broadcast, color: tint)
                OmpText(here ? "Playing on this phone" : "Playing on \(state.playingDeviceName)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                OmpText("Devices \u{25BE}", size: Omp.TypeSize.bodySmall, color: tint)
            }
            .padding(.horizontal, m.pt(10))
            .padding(.vertical, m.pt(8))
            .background(here ? Omp.normalFill : Omp.maro.opacity(0.14), in: shape)
            .overlay(shape.stroke(tint.opacity(0.45), lineWidth: 1))
            .contentShape(shape)
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

private struct NowPlayingRow: View {
    @Environment(\.omp) private var m
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        let track = state.track
        HStack(spacing: m.pt(10)) {
            CoverArt(
                artKey: track?.artKey ?? "",
                artUrl: track?.artUrl ?? "",
                icon: Omp.sourceIcon(track?.source ?? ""),
                size: Omp.nowArt,
                busy: track.map { state.artworkProgress[$0.artKey] != nil } ?? false
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
                    let meta = [track.album, Omp.originLabel(state.origin), state.queueName.isEmpty ? "" : "in \(state.queueName)"]
                        .filter { !$0.isEmpty }.joined(separator: "  ·  ")
                    if !meta.isEmpty { OmpText(meta, size: Omp.TypeSize.caption, color: Omp.muted) }
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
                        OmpIcon(item.icon)
                        OmpText(item.label)
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
