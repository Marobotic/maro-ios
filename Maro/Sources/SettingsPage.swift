import SwiftUI

struct SettingsPage: View {
    @Environment(\.omp) private var m
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: m.pt(4)) {
            HStack(spacing: m.pt(10)) {
                OmpButton(icon: Omp.Icons.back, vertical: 4, horizontal: 6) { vm.toggleSettings() }
                OmpText("Settings", size: Omp.TypeSize.bodySmall, bold: true)
                Spacer(minLength: 0)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SettingsHead(label: "Your account")
                    SettingsAccountCard(
                        label: "Jukebox",
                        icon: Omp.Icons.cloud,
                        value: state.email.ifBlank("Not signed in"),
                        note: "Your library and queue sync here.",
                        action: "Sign out",
                        tint: Omp.maro,
                        connected: state.signedIn
                    ) {
                        present(.confirm(message: "Sign out? Playback keeps running on the desktop.", confirm: "Sign out") { vm.signOutMaro() })
                    }
                    SettingsHead(label: "Connected services")
                    SettingsAccountCard(
                        label: "Spotify",
                        icon: Omp.Icons.spotify,
                        value: state.spotifyConnected ? state.spotifyAccountName.ifBlank("Connected") : "Not connected",
                        note: !state.spotifyConnected ? "Full quality with a subscription."
                            : !state.spotifyApiConnected ? "Playback only - reconnect for search." : "Playback, search and playlists.",
                        action: state.spotifyConnected ? "Sign out" : "Connect",
                        tint: Omp.spotify,
                        connected: state.spotifyConnected
                    ) { vm.connectService("spotify") }
                    SettingsAccountCard(
                        label: "YouTube Music",
                        icon: Omp.Icons.ytm,
                        value: state.ytmConnected ? state.ytmAccountName.ifBlank("Connected") : "Not connected",
                        note: state.ytmConnected ? "Your library and uploads." : "Your browser session.",
                        action: state.ytmConnected ? "Sign out" : "Connect",
                        tint: Omp.ytm,
                        connected: state.ytmConnected
                    ) { vm.connectService("ytm") }
                    SettingsHead(label: "On this phone")
                    if state.servicesLocked {
                        SettingsRow(icon: Omp.Icons.cloud, label: "Bring your music services over", meta: "Password", accent: true) {
                            present(.password(title: "Your Jukebox password, once: it opens the Spotify, YouTube and SoundCloud sign-ins your desktop keeps on the account.", confirm: "Unlock") { pass in
                                Task { _ = await vm.unlockServices(pass) }
                            })
                        }
                    }
                    PhoneServiceRow(label: "Spotify", icon: Omp.Icons.spotify, tint: Omp.spotify, slot: ServiceSessions.librespot, state: state)
                    PhoneServiceRow(label: "YouTube Music", icon: Omp.Icons.ytm, tint: Omp.ytm, slot: ServiceSessions.ytm, state: state)
                    PhoneServiceRow(label: "SoundCloud", icon: Omp.Icons.sc, tint: Omp.sc, slot: ServiceSessions.soundcloud, state: state)
                    SettingsHead(label: "Devices")
                    SettingsRow(icon: Omp.Icons.edit, label: "Device name", meta: state.deviceName, accent: true) {
                        present(.name(title: "Device name", placeholder: Omp.defaultPhoneName, confirm: "Save", initial: state.deviceName) { vm.setDeviceName($0) })
                    }
                    // Off: part of the account's one shared player. On: this
                    // phone plays on its own and leaves the device lists.
                    SettingsSwitchRow(label: "Play music on this device only", value: "", on: state.solo) { vm.setSolo($0) }
                    SettingsHead(label: "Playback")
                    SettingsChoiceRow(label: "Preferred source", value: state.playbackSource, options: Omp.sourceOptions) { vm.setPlaybackSource($0) }
                    SettingsSwitchRow(
                        label: "Keep songs on this phone",
                        value: state.songs.isEmpty ? "" : "\(state.songs.count) saved",
                        on: state.savingOffline
                    ) { vm.setSavingOffline($0) }
                    SettingsHead(label: "Quality")
                    SettingsChoiceRow(label: "Streaming", value: state.quality, options: Omp.streamQualityOptions) { vm.setQuality("stream", $0) }
                    SettingsChoiceRow(label: "Downloads", value: state.downloadQuality, options: Omp.qualityOptions) { vm.setQuality("download", $0) }
                    OmpText("Downloads only ever come from YouTube. Streaming at Spotify 320 kbps plays from Spotify, falling back to YouTube's best; offline, saved songs play.",
                            size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 3)
                        .padding(.horizontal, m.pt(4))
                        .padding(.vertical, m.pt(6))
                    SettingsHead(label: "Library")
                    SettingsRow(icon: Omp.Icons.list, label: "Queue", meta: "\(state.queue.count) tracks") {}
                    SettingsRow(icon: Omp.Icons.like, label: "Liked", meta: "\(state.likedKeys.count) tracks") {}
                    SettingsRow(icon: Omp.Icons.note, label: "Your playlists", meta: "\(state.playlists.count) playlists") {}
                    SettingsHead(label: "Phone storage")
                    SettingsRow(
                        icon: Omp.Icons.grid,
                        label: "Available",
                        meta: "\(Omp.fmtBytes(state.phoneAvailableBytes)) free · \(Omp.fmtBytes(state.phoneTotalBytes))"
                    ) {}
                    SettingsRow(icon: Omp.Icons.note, label: "Saved songs", meta: "\(Omp.fmtBytes(state.phoneMusicBytes)) · \(state.phoneMusicCount) tracks") {}
                    SettingsRow(icon: Omp.Icons.refresh, label: "Artwork cache", meta: Omp.fmtBytes(state.phoneCacheBytes)) {}
                    SettingsHead(label: "Stored data")
                    SettingsActionRow(label: "Playlist cache", action: "Clear") { purge("playlists") }
                    SettingsActionRow(label: "Artwork", action: "Clear") { purge("artwork") }
                    SettingsActionRow(label: "Offline songs on the desktop", action: "Clear") { purge("songs") }
                    SettingsActionRow(label: "Recently played", action: "Clear") { purge("history") }
                    SettingsActionRow(label: "Reset everything", action: "Reset", value: "accounts, playlists, downloads", danger: true) { purge("all") }
                    SettingsHead(label: "About")
                    SettingsRow(icon: Omp.Icons.note, label: "Version", meta: Self.version) {}
                }
                .padding(.bottom, m.pt(14))
            }
        }
        .padding(.horizontal, m.pt(4))
    }

    /** "0.1.6 (7)": the version and build this phone is running. */
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
        case "songs": label = "the desktop's offline songs"
        case "history": label = "recently played"
        default: label = "everything"
        }
        present(.confirm(message: "Clear \(label)? This cannot be undone.", confirm: "Clear") { vm.purge(scope) })
    }
}

/** One service as this phone holds it: its own sign-in, the account's copy
 *  from the desktop, or nothing yet. */
private struct PhoneServiceRow: View {
    let label: String
    let icon: String
    let tint: Color
    let slot: String
    let state: UiState

    var body: some View {
        let has = state.services.contains(slot)
        let origin = ServiceSessions.shared.origin(slot)
        SettingsAccountCard(
            label: label,
            icon: icon,
            value: !has ? "Not on this phone" : origin == "phone" ? "Signed in here" : "From your desktop",
            note: has ? "Plays on this phone directly." : state.servicesLocked ? "Unlock above to use your desktop's sign-in." : "Sign in on the desktop and it comes over.",
            action: "",
            tint: tint,
            connected: has
        ) {}
    }
}

private struct SettingsHead: View {
    @Environment(\.omp) private var m
    let label: String

    var body: some View {
        OmpText(label.uppercased(), size: Omp.TypeSize.caption, color: Omp.accent, bold: true)
            .padding(.leading, m.pt(4))
            .padding(.bottom, m.pt(4))
            .frame(maxWidth: .infinity, minHeight: m.pt(28), alignment: .bottomLeading)
    }
}

private struct SettingsAccountCard: View {
    @Environment(\.omp) private var m
    let label: String
    let icon: String
    let value: String
    let note: String
    let action: String
    let tint: Color
    let connected: Bool
    let onAction: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.pt(Omp.labelGap))
        HStack(spacing: m.pt(10)) {
            OmpIcon(icon, size: Omp.TypeSize.title, color: connected ? tint : tint.opacity(0.55))
            VStack(alignment: .leading, spacing: 0) {
                OmpText(label, size: Omp.TypeSize.bodySmall, bold: true)
                OmpText(value, size: Omp.TypeSize.caption, color: connected ? tint : Omp.muted)
                OmpText(note, size: Omp.TypeSize.caption, color: Omp.foreground.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !action.isEmpty {
                OmpButton(
                    text: action,
                    foreground: action == "Sign out" ? Omp.urgent : tint,
                    fontSize: Omp.TypeSize.caption,
                    vertical: 4,
                    horizontal: 8,
                    bordered: true,
                    action: onAction
                )
            }
        }
        .padding(.leading, m.pt(10))
        .padding(.trailing, m.pt(8))
        .frame(height: m.pt(60))
        .background(connected ? tint.opacity(0.10) : Omp.foreground.opacity(0.06), in: shape)
        .overlay(shape.stroke(connected ? tint.opacity(0.55) : Omp.foreground.opacity(0.16), lineWidth: 1))
        .padding(.vertical, m.pt(2))
    }
}

private struct SettingsChoiceRow: View {
    @Environment(\.omp) private var m
    let label: String
    let value: String
    let options: [(String, String)]
    let onSelected: (String) -> Void

    var body: some View {
        let selected = options.first { $0.0 == value } ?? options[0]
        HStack(spacing: m.pt(8)) {
            OmpText(label, size: Omp.TypeSize.caption).frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(options, id: \.0) { option in
                    Button(option.1) { onSelected(option.0) }
                }
            } label: {
                OmpText(selected.1, size: Omp.TypeSize.caption)
                    .padding(.horizontal, m.pt(8))
                    .padding(.vertical, m.pt(4))
                    .overlay(RoundedRectangle(cornerRadius: m.pt(Omp.labelGap)).stroke(Omp.foreground.opacity(0.40), lineWidth: 1))
            }
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(40))
    }
}

private struct SettingsSwitchRow: View {
    @Environment(\.omp) private var m
    let label: String
    let value: String
    let on: Bool
    let onSelected: (Bool) -> Void

    var body: some View {
        HStack(spacing: m.pt(8)) {
            OmpText(label, size: Omp.TypeSize.caption).frame(maxWidth: .infinity, alignment: .leading)
            if !value.isEmpty { OmpText(value, size: Omp.TypeSize.caption, color: Omp.muted) }
            Capsule()
                .fill(on ? Omp.maro : Omp.softDk)
                .frame(width: m.pt(34), height: m.pt(18))
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Omp.foreground).frame(width: m.pt(14), height: m.pt(14)).padding(m.pt(2))
                }
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(38))
        .contentShape(Rectangle())
        .onTapGesture { onSelected(!on) }
    }
}

private struct SettingsRow: View {
    @Environment(\.omp) private var m
    let icon: String
    let label: String
    let meta: String
    var accent = false
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: m.pt(8)) {
            OmpIcon(icon, color: accent ? Omp.accent : Omp.foreground)
            OmpText(label, size: Omp.TypeSize.bodySmall).frame(maxWidth: .infinity, alignment: .leading)
            OmpText(meta, size: Omp.TypeSize.caption, color: accent ? Omp.accent : Omp.muted)
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(34))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}

private struct SettingsActionRow: View {
    @Environment(\.omp) private var m
    let label: String
    let action: String
    var value = ""
    var danger = false
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: m.pt(8)) {
            OmpText(label, size: Omp.TypeSize.caption, color: danger ? Omp.urgent : Omp.muted).frame(maxWidth: .infinity, alignment: .leading)
            if !value.isEmpty { OmpText(value, size: Omp.TypeSize.caption, color: Omp.muted) }
            OmpText(action, size: Omp.TypeSize.caption, color: danger ? Omp.urgent : Omp.accent, bold: true)
        }
        .padding(.horizontal, m.pt(4))
        .frame(height: m.pt(34))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}
