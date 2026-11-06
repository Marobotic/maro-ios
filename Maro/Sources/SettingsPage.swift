import AVKit
import Combine
import SwiftUI
import UIKit

/**
 * Settings in the desktop's redesign, in its order: Health, Your account,
 * Connected services, Playback, Quality, Library, Stored data, About. A Back
 * button and the title, red uppercase section heads, and every row a #161616
 * block with the #242424 hairline; accounts as taller cards with a square
 * service mark.
 */
struct SettingsPage: View {
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @ObservedObject private var console = ConsoleLog.shared
    @State private var showingConsole = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                SettingsTop(title: "Settings") { vm.toggleSettings() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        health
                        account
                        playback
                        quality
                        library
                        storedData
                        SettingsHead(label: "About")
                        SettingsStat(label: "Version", value: "Jukebox " + Self.version)
                    }
                    .padding(.bottom, 56)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .background(Omp.page.ignoresSafeArea())
            .navigationDestination(isPresented: $showingConsole) { ConsolePage() }
            .toolbar(.hidden, for: .navigationBar)
            .focusable()
            .onKeyPress(.escape) {
                vm.toggleSettings()
                return .handled
            }
        }
    }

    /**
     * Health: whether each account answers right now, with the sessions this
     * phone holds; a service that stopped working offers a fresh sign-in.
     */
    @ViewBuilder private var health: some View {
        SettingsHead(label: "Health", first: true)
        VStack(spacing: 0) {
            HealthRow(glyph: .cloud, tint: Omp.themeAccent, label: "Jukebox", health: state.health["maro"]) { purgeAndSignIn("maro", "Jukebox") }
            HealthRow(glyph: .spotify, tint: Omp.spotify, label: "Spotify", health: state.health["spotify"]) { purgeAndSignIn("spotify", "Spotify") }
            HealthRow(glyph: .ytm, tint: Omp.ytm, label: "YouTube Music", health: state.health["ytm"]) { purgeAndSignIn("ytm", "YouTube Music") }
            HealthRow(glyph: .sc, tint: Omp.sc, label: "SoundCloud", health: state.health["sc"]) { purgeAndSignIn("sc", "SoundCloud") }
            HStack(spacing: 10) {
                OmpText("Checked with the sessions on this phone", size: 11, color: Omp.t3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MButton("Check now") { vm.checkHealth(force: true) }
            }
            .frame(minHeight: 46)
        }
    }

    @ViewBuilder private var account: some View {
        SettingsHead(label: "Your account")
        AccountCard(
            label: "Jukebox",
            tint: Omp.themeAccent,
            on: state.signedIn,
            value: state.signedIn ? state.email.ifBlank("Signed in") : "Not signed in",
            note: "Your library and queue sync here.",
            action: "Sign out"
        ) {
            present(.confirm(message: "Sign out of Jukebox on this phone? Your other devices stay signed in.", confirm: "Sign out") { vm.signOutMaro() })
        }
        // The account's sessions: whichever device signs in puts
        // it here, and every device uses it.
        SettingsHead(label: "Connected services")
        ServiceCard(label: "Spotify", tint: Omp.spotify, slot: ServiceSessions.librespot, name: Spotify.shared.user,
                    onNote: "Playback, search and playlists.", offNote: "Full quality with a subscription.", state: state) {
            vm.connectService("spotify")
        }
        ServiceCard(label: "YouTube Music", tint: Omp.ytm, slot: ServiceSessions.ytm, name: "",
                    onNote: "Your library and uploads.", offNote: "Sign in with Google in a window.", state: state) {
            vm.connectService("ytm")
        }
        ServiceCard(label: "SoundCloud", tint: Omp.sc, slot: ServiceSessions.soundcloud,
                    name: ServiceSessions.shared.session(ServiceSessions.soundcloud)?.obj("user")?.str("name") ?? "",
                    onNote: "Your playlists and likes.", offNote: "Search and play work without it. Sign in for your playlists.",
                    state: state) {
            vm.connectService("sc")
        }
        SettingsNote("Signed in here or on any other device, a service is on your account and every device uses it. Signing out of one signs every device out of it.")
    }

    @ViewBuilder private var playback: some View {
        SettingsHead(label: "Playback")
        SettingsChoice(label: "Preferred source", value: state.playbackSource, options: Omp.sourceOptions) { vm.setPlaybackSource($0) }
        PlaybackDeviceRow()
        SettingsAction(label: "This phone's name", value: state.deviceName, action: "Rename") {
            present(.name(title: "Device name", placeholder: Omp.defaultPhoneName, confirm: "Save", initial: state.deviceName) { vm.setDeviceName($0) })
        }
        SettingsAction(label: "Console", value: "\(console.entries.count) lines", action: "Open") { showingConsole = true }
        // Off: part of the account's one shared player. On: this
        // phone plays on its own and leaves the device lists.
        SettingsSwitch(label: "Play music on this device only", on: state.solo) { vm.setSolo($0) }
        SettingsSwitch(label: "Keep songs on this phone",
                       value: state.songs.isEmpty ? "" : "\(state.songs.count) saved",
                       on: state.savingOffline) { vm.setSavingOffline($0) }
    }

    @ViewBuilder private var quality: some View {
        SettingsHead(label: "Quality")
        SettingsChoice(label: "Streaming", value: state.quality, options: Omp.streamQualityOptions) { vm.setQuality("stream", $0) }
        SettingsChoice(label: "Downloads", value: state.downloadQuality, options: Omp.qualityOptions) { vm.setQuality("download", $0) }
        SettingsNote("Streaming at Spotify 320 kbps plays from Spotify, falling back to YouTube's best. Downloads only ever come from YouTube; offline, saved songs play.")
    }

    private var likedCount: Int {
        state.playlists.first { $0.source == "liked" }?.count ?? state.likedKeys.count
    }

    private var songsOnDisk: Int { state.phoneMusicCount + state.phoneKeptCount }

    private var bytesOnDisk: Int64 { state.phoneMusicBytes + state.phoneKeptBytes }

    @ViewBuilder private var library: some View {
        let lists = state.playlists.filter { $0.source != "liked" }
        let listTracks = lists.reduce(0) { $0 + $1.count }
        SettingsHead(label: "Library")
        SettingsStat(label: "Queue", value: "\(state.displayState().queue.count) tracks")
        SettingsStat(label: "Liked", value: "\(likedCount) tracks")
        SettingsStat(label: "Your playlists", value: "\(lists.count) · \(listTracks) tracks")
        SettingsStat(label: "On disk", value: Omp.fmtBytes(bytesOnDisk) + (songsOnDisk > 0 ? "  ·  \(songsOnDisk) songs" : ""))
        SettingsStat(label: "Free on this phone", value: "\(Omp.fmtBytes(state.phoneAvailableBytes)) of \(Omp.fmtBytes(state.phoneTotalBytes))")
    }

    private var songsNote: String {
        let limit = state.songsLimitGb > 0
        let kept = state.phoneMusicCount > 0 ? "\(state.phoneMusicCount) saved offline by you stay when cleared\(limit ? " or over the limit" : ""). " : ""
        return kept + (limit ? "Over the limit, the songs played longest ago go first." : "Unlimited: songs stay on disk until you clear them.")
    }

    @ViewBuilder private var storedData: some View {
        SettingsHead(label: "Stored data")
        SettingsAction(label: "Songs on disk", value: "\(songsOnDisk) songs  ·  \(Omp.fmtBytes(bytesOnDisk))", action: "Clear") { purge("songs") }
        SettingsNote(songsNote)
        SettingsChoice(label: "Limit for songs on disk", value: String(state.songsLimitGb), options: Self.limitOptions) { vm.setSongsLimit(Int($0) ?? 0) }
        SettingsAction(label: "Playlist cache", value: "\(state.playlistCacheCount) lists", action: "Clear") { purge("playlists") }
        SettingsAction(label: "Artwork", value: Omp.fmtBytes(state.phoneCacheBytes), action: "Clear") { purge("artwork") }
        SettingsAction(label: "Recently played", value: "\(state.recent.count) tracks", action: "Clear") { purge("history") }
        SettingsAction(label: "Reset everything", value: "accounts, playlists, liked", action: "Reset", danger: true) { purge("all") }
    }

    private static let limitOptions: [(String, String)] = [("0", "Unlimited"), ("2", "2 GB"), ("5", "5 GB"), ("10", "10 GB"), ("20", "20 GB")]

    private func purgeAndSignIn(_ key: String, _ name: String) {
        let what = key == "maro"
            ? "Sign out of Jukebox and sign in again? Your library, playlists and queue stay on your account."
            : "Sign in to \(name) again? The new sign-in replaces the session that stopped working, on every device."
        present(.confirm(message: what, confirm: key == "maro" ? "Sign out" : "Sign in") { vm.purgeAndSignIn(key) })
    }

    /** "0.2.0 (33)": the version and build this phone is running. */
    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }()

    private func purge(_ scope: String) {
        let label: String
        switch scope {
        case "playlists": label = "the playlist cache"
        case "artwork": label = "all artwork"
        case "songs": label = "the songs this phone kept as they played (songs you saved stay)"
        case "history": label = "recently played"
        default: label = "everything"
        }
        present(.confirm(message: "Clear \(label)? This cannot be undone.", confirm: scope == "all" ? "Reset" : "Clear") { vm.purge(scope) })
    }
}

/** The page head: the Back button and the title. */
private struct SettingsTop<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 16) {
            MButton("Back", icon: .back, kind: .normal, action: onBack)
            OmpText(title, size: 16, color: Omp.foreground, bold: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 40)
        .padding(.bottom, 16)
    }
}

extension SettingsTop where Trailing == EmptyView {
    init(title: String, onBack: @escaping () -> Void) {
        self.title = title
        self.onBack = onBack
        self.trailing = { EmptyView() }
    }
}

private struct ConsolePage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var console = ConsoleLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTop(title: "Settings › Console", onBack: { dismiss() }) {
                EmptyView()
            }
            HStack(spacing: 6) {
                MButton("Copy all") {
                    UIPasteboard.general.string = console.entries.map(\.line).joined(separator: "\n")
                }
                MButton("Clear", kind: .danger) { console.clear() }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            if console.entries.isEmpty {
                OmpText("No console entries", size: 11, color: Omp.t3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(console.entries) { entry in
                                Text(entry.line)
                                    .font(Omp.font(11))
                                    .foregroundColor(Omp.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1) }
                                    .id(entry.id)
                            }
                        }
                        .padding(.bottom, 16)
                        .textSelection(.enabled)
                    }
                    .onChange(of: console.entries.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = console.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .background(Omp.page.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .focusable()
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }
}

/** A section head: red, uppercase, letter-spaced. */
private struct SettingsHead: View {
    let label: String
    var first = false

    var body: some View {
        Text(label.uppercased())
            .font(Omp.font(11, bold: true))
            .tracking(0.6)
            .foregroundColor(Omp.headRed)
            .padding(.top, first ? 0 : 26)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        OmpText(text, size: 12, color: Omp.t3, maxLines: 6)
            .lineSpacing(4)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/** The block every row sits in. */
private struct RowBlock<Content: View>: View {
    var minHeight: CGFloat = 56
    var fill: Color = Omp.row
    var border: Color = Omp.line
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
    }
}

private struct SettingsStat: View {
    let label: String
    let value: String

    var body: some View {
        RowBlock {
            OmpText(label, size: 12, color: Color(hex: 0xD7D7D7))
                .frame(maxWidth: .infinity, alignment: .leading)
            OmpText(value, size: 11.5, color: Omp.t2)
        }
    }
}

/** A row that does something when tapped: the action word on the right in accent-soft. */
private struct SettingsAction: View {
    let label: String
    var value = ""
    let action: String
    var danger = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            RowBlock {
                OmpText(label, size: 12, color: danger ? Omp.danger : Omp.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !value.isEmpty { OmpText(value, size: 11.5, color: Omp.t2) }
                OmpText(action, size: 11, color: danger ? Omp.danger : Omp.soft, bold: true)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}

private struct SettingsSwitch: View {
    let label: String
    var value = ""
    let on: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!on) } label: {
            RowBlock {
                OmpText(label, size: 12, color: Omp.foreground, maxLines: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !value.isEmpty { OmpText(value, size: 11.5, color: Omp.t2) }
                SquareSwitch(on: on)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/** A choice: the desktop's dropdown box, opening the app's own square menu. */
private struct SettingsChoice: View {
    @Environment(\.presentDialog) private var present
    let label: String
    let value: String
    let options: [(String, String)]
    let onSelected: (String) -> Void

    var body: some View {
        let selected = options.first { $0.0 == value } ?? options[0]
        RowBlock {
            OmpText(label, size: 12, color: Omp.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                present(.menu(title: label, items: options.map { option in
                    OmpDialog.Item(icon: option.0 == value ? Glyph.check : nil, label: option.1,
                                   tint: option.0 == value ? Omp.soft : Omp.foreground,
                                   bold: option.0 == value) { onSelected(option.0) }
                }))
            } label: {
                HStack(spacing: 10) {
                    OmpText(selected.1, size: 12, color: Omp.foreground)
                    Icon(.chevronDown, size: 14, color: Omp.t3)
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(height: 36)
                .frame(maxWidth: 220, alignment: .leading)
                .background(Omp.page)
                .overlay(Rectangle().strokeBorder(Omp.edge, lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.97))
        }
    }
}

/** An account as a card: the square service mark, its name, who is signed in, a note, and the button. */
private struct AccountCard: View {
    let label: String
    let tint: Color
    let on: Bool
    let value: String
    let note: String
    let action: String
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Rectangle().fill(tint).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                OmpText(label, size: 12, color: Omp.foreground, bold: true)
                OmpText(value, size: 11, color: on ? tint : Omp.t2)
                OmpText(note, size: 11, color: Omp.t2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MButton(action, kind: action == "Sign out" ? .danger : .normal, action: onAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(on ? Color.mix(tint, Omp.row, 0.05) : Omp.row)
        .overlay(Rectangle().strokeBorder(on ? Color.mix(tint, Omp.line, 0.44) : Omp.line, lineWidth: 1))
    }
}

/** One music service as the account holds it, with Connect / Sign out. */
private struct ServiceCard: View {
    let label: String
    let tint: Color
    let slot: String
    let name: String
    let onNote: String
    let offNote: String
    let state: UiState
    let onTap: () -> Void

    var body: some View {
        let on = state.services.contains(slot)
        AccountCard(
            label: label,
            tint: tint,
            on: on,
            value: on ? (name.isEmpty ? "Signed in" : name) : "Not connected",
            note: on ? onNote : offNote,
            action: on ? "Sign out" : "Connect",
            onAction: onTap
        )
    }
}

/** One account's health: its mark, name, why it fails, a 7 pt status square and word. */
private struct HealthRow: View {
    let glyph: Glyph
    let tint: Color
    let label: String
    let health: HealthState?
    let onPurge: () -> Void

    private static let words: [String: String] = [
        "yes": "Working", "no": "Not working", "checking": "Checking…", "offline": "Offline", "off": "Not signed in",
    ]

    private static func dot(_ state: String) -> Color {
        switch state {
        case "yes": return Omp.ok
        case "no": return Omp.themeAccent
        case "offline": return Omp.urgent
        default: return Color(hex: 0x3D3D3D)
        }
    }

    var body: some View {
        let h = health ?? HealthState()
        HStack(spacing: 10) {
            Icon(glyph, size: 15, color: tint)
            VStack(alignment: .leading, spacing: 2) {
                OmpText(label, size: 12, color: Omp.foreground)
                if !h.why.isEmpty && h.state != "yes" { OmpText(h.why, size: 10.5, color: Omp.t3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Rectangle().fill(Self.dot(h.state)).frame(width: 7, height: 7)
                OmpText(Self.words[h.state] ?? "Not signed in", size: 11.5, color: Omp.t2)
            }
            if h.state == "no" { MButton("Purge and sign in", kind: .danger, action: onPurge) }
        }
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Omp.line).frame(height: 1) }
    }
}

/** The system's own route picker (AirPlay, Bluetooth, this phone), invisible over the box. */
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/** Playback device: where the sound goes, picked from the system's list. */
private struct PlaybackDeviceRow: View {
    @State private var route = PlaybackDeviceRow.current()

    var body: some View {
        RowBlock {
            OmpText("Playback device", size: 12, color: Omp.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                OmpText(route, size: 12, color: Omp.foreground)
                Icon(.chevronDown, size: 14, color: Omp.t3)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 36)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Omp.page)
            .overlay(Rectangle().strokeBorder(Omp.edge, lineWidth: 1))
            .overlay { RoutePicker() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            route = Self.current()
        }
    }

    static func current() -> String {
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "This phone" }
        if out.portType == .builtInSpeaker || out.portType == .builtInReceiver { return "This phone" }
        return out.portName
    }
}
