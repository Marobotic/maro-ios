import AVKit
import Combine
import SwiftUI
import UIKit

/**
 * Settings in the desktop's redesign, in its order: Accounts (health and
 * sign-ins in one list), Playback, Quality, Library, Stored data, About. A Back
 * button and the title, sentence-case section heads, and every row a #161616
 * block with the #242424 hairline; accounts as taller cards with a square
 * service mark.
 */
struct SettingsPage: View {
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @ObservedObject private var console = ConsoleLog.shared
    // The plans as they arrive (Spotify's a moment after it connects).
    @ObservedObject private var plans = Plans.shared
    @State private var showingConsole = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                SettingsTop(title: "Settings") { vm.toggleSettings() }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            accounts
                            playback
                            TogetherPrivacy(together: vm.together)
                            quality
                            library
                            storedData
                            SettingsHead(label: "About")
                            SettingsStat(label: "Version", value: "Jukebox " + Self.version)
                        }
                        .padding(.bottom, 56)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        // The launch route's section (testing): settings:stored and the like.
                        if let target = Self.scrollTo {
                            Self.scrollTo = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .background(Omp.page.ignoresSafeArea())
            .navigationDestination(isPresented: $showingConsole) { ConsolePage(state: state, vm: vm) }
            // A failure toast's "Details": straight to its entry.
            .onAppear { if state.consoleFocus != 0 { showingConsole = true } }
            .onChange(of: state.consoleFocus) { _, id in if id != 0 { showingConsole = true } }
            .toolbar(.hidden, for: .navigationBar)
            .focusable()
            .onKeyPress(.escape) {
                vm.toggleSettings()
                return .handled
            }
        }
    }

    /**
     * Accounts first, as on the desktop: one row per service - its real logo,
     * the account and its plan, a status dot, one button. Services in the one
     * order: Jukebox, YouTube, Spotify, SoundCloud. "Check all" checks every row.
     */
    @ViewBuilder private var accounts: some View {
        HStack(spacing: 10) {
            Text("Accounts")
                .font(Omp.font(Omp.TypeSize.body, bold: true))
                .foregroundColor(Omp.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
            AccountButton(label: "Check all", width: nil) { vm.checkHealth(force: true) }
        }
        .padding(.bottom, 10)
        VStack(spacing: 4) {
            ServiceAccountRow(service: "maro", label: "Jukebox", who: state.email, plan: "",
                              on: state.signedIn, health: state.health["maro"], signInLabel: "Sign in",
                              onSignIn: nil,
                              onSignOut: {
                                  present(.confirm(message: "Sign out of Jukebox on this phone? Your other devices stay signed in.", confirm: "Sign out") { vm.signOutMaro() })
                              },
                              onPurge: { purgeAndSignIn("maro", "Jukebox") })
            service("ytm", "YouTube Music", slot: ServiceSessions.ytm, who: YtmDevice.shared.account)
            service("spotify", "Spotify", slot: ServiceSessions.librespot, who: Spotify.shared.user)
            service("sc", "SoundCloud", slot: ServiceSessions.soundcloud,
                    who: ServiceSessions.shared.session(ServiceSessions.soundcloud)?.obj("user")?.str("name") ?? "")
        }
        SettingsNote("Spotify and SoundCloud are shared between your devices and kept on your account. Sign in to YouTube Music on each device; its Google session stays on that device.")
    }

    private func service(_ key: String, _ label: String, slot: String, who: String) -> ServiceAccountRow {
        let on = state.services.contains(slot)
        return ServiceAccountRow(
            service: key, label: label, who: who, plan: plans.of(key, who),
            on: on, health: state.health[key], signInLabel: "Connect",
            onSignIn: { vm.connectService(key) },
            onSignOut: { vm.connectService(key) },
            onPurge: { purgeAndSignIn(key, label) }
        )
    }

    @ViewBuilder private var playback: some View {
        SettingsHead(label: "Playback").id("playback")
        SettingsChoice(label: "Preferred source", value: state.playbackSource, options: Omp.sourceOptions) { vm.setPlaybackSource($0) }
        PlaybackDeviceRow()
        SettingsAction(label: "This phone's name", value: state.deviceName, action: "Rename") {
            present(.name(title: "Device name", placeholder: Omp.defaultPhoneName, confirm: "Save", initial: state.deviceName) { vm.setDeviceName($0) })
        }
        SettingsAction(label: "Console", value: "\(console.entries.count) entries", action: "Open") { showingConsole = true }
        // Off: part of the account's one shared player. On: this phone
        // plays on its own and leaves the device lists. A whole-row tap
        // turned it on unnoticed (as on an Android phone), so on asks first;
        // off is one tap.
        SettingsSwitch(label: "Play music on this device only", on: state.solo) { on in
            if !on { return vm.setSolo(false) }
            present(.confirm(message: "Play music on this phone only? It leaves your devices: they can't see or control it, and it can't play on them or follow their queue.",
                             confirm: "Play here only") { vm.setSolo(true) })
        }
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

    /** The same count the Library row and the playlist header show (UiState.countFor). */
    private var likedCount: Int { state.likedCount }

    private var songsOnDisk: Int { state.phoneMusicCount + state.phoneKeptCount }

    private var bytesOnDisk: Int64 { state.phoneMusicBytes + state.phoneKeptBytes }

    @ViewBuilder private var library: some View {
        let lists = state.playlists.filter { $0.source != "liked" }
        let listTracks = lists.reduce(0) { $0 + state.countFor($1) }
        SettingsHead(label: "Library").id("library")
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
        SettingsHead(label: "Stored data").id("stored")
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

    /** A section to open at (the launch route's settings:<section>). */
    static var scrollTo: String?

    static let version = AppRelease.installed.displayVersion

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
struct SettingsTop<Trailing: View>: View {
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

/**
 * The Console (round 2 M.1): the playback log with its options - level
 * (Errors / Warnings / All), service, a search, "This song only", a time
 * range - newest first; an entry opens to its details. Copy and Share take
 * the filtered log as text; Clear empties it.
 */
private struct ConsolePage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.presentDialog) private var present
    let state: UiState
    @ObservedObject var vm: MaroViewModel
    @ObservedObject private var console = ConsoleLog.shared
    @State private var level = "all"          // errors | warnings | all
    @State private var source = ""            // "" | spotify | ytm | sc | jukebox
    @State private var query = ""
    @State private var songOnly = false
    @State private var range = 0
    @State private var open: Set<Int> = []

    private static let ranges: [(String, Double)] = [
        ("All time", 0), ("Last hour", 3600), ("Last 24 h", 86400), ("Last 7 days", 7 * 86400),
    ]
    static let levelE = Color(hex: 0xFF6B5E)
    static let levelW = Color(hex: 0xF0B400)

    private var songKey: String { state.displayState().track.map(ConsoleLog.keyOf) ?? "" }

    private var shown: [ConsoleEntry] {
        let now = Date().timeIntervalSince1970
        let q = query.trimmingCharacters(in: .whitespaces)
        let window = Self.ranges[range].1
        let key = songKey
        return console.entries.reversed().filter { e in
            (level == "all" || (level == "errors" && e.level == .error) || (level == "warnings" && e.level != .info))
                && (source.isEmpty || e.source == source
                    || (!e.songKey.isEmpty && ConsoleLog.serviceOf(source: String(e.songKey.split(separator: ":").first ?? "")) == source))
                && (!songOnly || (!key.isEmpty && e.songKey == key))
                && (window == 0 || now - e.at <= window)
                && (q.isEmpty || [e.message, e.song, e.songKey, e.details, e.area].contains { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    var body: some View {
        let list = shown
        VStack(alignment: .leading, spacing: 6) {
            SettingsTop(title: "Settings \u{203A} Console", onBack: { dismiss() }) {
                OmpText("\(list.count) of \(console.entries.count)", size: 11, color: Omp.t3)
            }
            HStack(spacing: 6) {
                ConsoleChip(label: "Errors", on: level == "errors", dot: Self.levelE) { level = level == "errors" ? "all" : "errors" }
                ConsoleChip(label: "Warnings", on: level == "warnings", dot: Self.levelW) { level = level == "warnings" ? "all" : "warnings" }
                ConsoleChip(label: "All", on: level == "all") { level = "all" }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ConsoleChip(label: "All services", on: source.isEmpty) { source = "" }
                    ForEach(["jukebox", "ytm", "spotify", "sc"], id: \.self) { s in
                        ConsoleChip(label: ConsoleLog.sourceLabel(s), on: source == s, dot: Omp.playingColor(s)) { source = source == s ? "" : s }
                    }
                }
            }
            .scrollIndicators(.hidden)
            OmpTextField(text: $query, placeholder: "Search the log", height: 36)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ConsoleChip(label: "This song only", on: songOnly, enabled: !songKey.isEmpty) { songOnly.toggle() }
                    ConsoleChip(label: Self.ranges[range].0, on: range != 0) { range = (range + 1) % Self.ranges.count }
                    MButton("Copy") {
                        UIPasteboard.general.string = ConsoleLog.text(list.reversed())
                        vm.showStatus("Copied \(list.count) entries", "ok")
                    }
                    MButton("Share") { shareLog(list) }
                    MButton("Clear", kind: .danger) {
                        present(.confirm(message: "Clear the whole playback log (\(console.entries.count) entries)?", confirm: "Clear") { ConsoleLog.shared.clear() })
                    }
                }
            }
            .scrollIndicators(.hidden)
            if list.isEmpty {
                OmpText(console.entries.isEmpty ? "Nothing logged yet" : "No entries match", size: 11, color: Omp.t3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { e in
                                ConsoleRow(entry: e, expanded: open.contains(e.id)) {
                                    if open.contains(e.id) { open.remove(e.id) } else { open.insert(e.id) }
                                }
                                .id(e.id)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .onAppear { focus(proxy) }
                    .onChange(of: state.consoleFocus) { focus(proxy) }
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

    /** Opened from a failure toast: that entry, open, with nothing filtering it out. */
    private func focus(_ proxy: ScrollViewProxy) {
        let id = state.consoleFocus
        guard id != 0 else { return }
        level = "all"; source = ""; query = ""; songOnly = false; range = 0
        open.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(id, anchor: .top) }
        vm.consoleFocusSeen()
    }

    /** The filtered log through the share sheet: newest last, up to ~200 KB of the newest entries. */
    private func shareLog(_ list: [ConsoleEntry]) {
        var picked: [ConsoleEntry] = []
        var size = 0
        for e in list {                         // newest first
            let n = e.line.utf8.count + 1
            if size + n > 200_000 { break }
            picked.append(e)
            size += n
        }
        presentShareSheet("Jukebox \(SettingsPage.version) playback log\n" + ConsoleLog.text(picked.reversed()), subject: "Jukebox playback log")
    }
}

private struct ConsoleChip: View {
    let label: String
    let on: Bool
    var dot: Color? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Rectangle().fill(dot).frame(width: 7, height: 7) }
                OmpText(label, size: 11, color: !enabled ? Omp.t3.opacity(0.5) : on ? .white : Omp.t2, bold: on)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? Omp.themeAccent.opacity(0.22) : Omp.raise)
            .overlay(Rectangle().strokeBorder(on ? Omp.themeAccent : Omp.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct ConsoleRow: View {
    let entry: ConsoleEntry
    let expanded: Bool
    let toggle: () -> Void

    private var levelColor: Color {
        switch entry.level {
        case .error: return ConsolePage.levelE
        case .warning: return ConsolePage.levelW
        case .info: return Color(hex: 0x5A5A5A)
        }
    }

    private var textColor: Color {
        switch entry.level {
        case .error: return Color(hex: 0xFFB0A8)
        case .warning: return Color(hex: 0xFFE08A)
        case .info: return Omp.foreground
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                Rectangle().fill(levelColor).frame(width: 3, height: entry.song.isEmpty ? 14 : 28).padding(.top, 1)
                OmpText(ConsoleLog.clockOf(entry), size: 10.5, color: Omp.t3)
                Rectangle().fill(Omp.playingColor(entry.source)).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    OmpText(entry.message, size: 11.5, color: textColor, maxLines: expanded ? 12 : 2)
                    if !entry.song.isEmpty { OmpText(entry.song, size: 10.5, color: Omp.t3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    detail("When", ConsoleLog.stampOf(entry))
                    detail("Level", entry.level.label)
                    detail("Service", ConsoleLog.sourceLabel(entry.source))
                    detail("From", entry.area)
                    if !entry.song.isEmpty { detail("Song", "\(entry.song)  \u{B7}  \(entry.songKey)") }
                    if !entry.details.isEmpty { detail("Details", entry.details) }
                }
                .padding(.leading, 10)
                .padding(.top, 6)
                .padding(.trailing, 4)
                .textSelection(.enabled)
            }
            Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1).padding(.top, 6)
        }
        .padding(.top, 6)
        .background(expanded ? Omp.tile : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            OmpText(label, size: 10.5, color: Omp.t3).frame(width: 56, alignment: .leading)
            Text(value).font(Omp.font(10.5)).foregroundColor(Omp.t2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/** The system share sheet for some text, over whatever is on screen. */
@MainActor
func presentShareSheet(_ text: String, subject: String = "") {
    let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    if !subject.isEmpty { sheet.setValue(subject, forKey: "subject") }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
    while let next = top.presentedViewController { top = next }
    if let pop = sheet.popoverPresentationController {
        pop.sourceView = top.view
        pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
    }
    top.present(sheet, animated: true)
}

/** A section head, as the desktop's approved mock: sentence case, 14 semibold, #A0A0A0. */
struct SettingsHead: View {
    let label: String
    var first = false

    var body: some View {
        Text(label)
            .font(Omp.font(Omp.TypeSize.body, bold: true))
            .foregroundColor(Omp.t2)
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

/** Listen together's two privacy switches (the account's /social/settings). */
private struct TogetherPrivacy: View {
    @ObservedObject var together: Together

    var body: some View {
        SettingsHead(label: "Listening together")
        SettingsSwitch(label: "Share what I'm listening to", value: together.shareListening ? "Friends see it" : "Hidden",
                       on: together.shareListening) { together.setShareListening($0) }
        SettingsSwitch(label: "Let friends join what I play", on: together.friendsCanJoin) { together.setFriendsCanJoin($0) }
            .task { await together.loadSettings() }
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

/**
 * One service in Accounts: its own mark (Jukebox: the app's pixel note), its
 * name and who is signed in, its health with why, and its actions - Check
 * now, Sign in / Sign out, and Purge and sign in when it stopped working.
 */
/**
 * One account in Settings, as the desktop's approved mock: 56 high on #151515
 * with the #232323 hairline; the service's real logo in a 32 pt box (Jukebox:
 * the app icon itself), the name, one line (the account and its plan as a tag
 * in the service's own colour, or what is wrong), a status dot and one button.
 * Every row's button is the same size.
 */
private struct ServiceAccountRow: View {
    let service: String
    let label: String
    let who: String
    let plan: String
    let on: Bool
    let health: HealthState?
    var signInLabel = "Connect"
    let onSignIn: (() -> Void)?
    let onSignOut: () -> Void
    let onPurge: (() -> Void)?

    var body: some View {
        let state = health?.state ?? (on ? "checking" : "off")
        let broken = state == "no" || state == "offline"
        let line: String = {
            if state == "no" { return "Not working" }
            if state == "offline" { return "Offline" }
            if on { return who.ifBlank("Signed in") }
            return service == "maro" ? "Not signed in" : "Not connected"
        }()
        let dot: Color = {
            switch state {
            case "yes": return Color(hex: 0x6FBF73)
            case "no": return Omp.themeAccent
            case "offline": return Omp.urgent
            case "checking": return Omp.t3
            default: return Color(hex: 0x555555)
            }
        }()
        let tint = service == "maro" ? Omp.themeAccent : Omp.sourceColor(service)
        HStack(spacing: 14) {
            BrandLogo(key: service, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                OmpText(label, size: Omp.TypeSize.body, color: Omp.foreground, bold: true)
                    .frame(height: 18)
                HStack(spacing: 8) {
                    OmpText(line, size: Omp.TypeSize.secondary, color: broken ? Omp.danger : Omp.t2)
                        .frame(height: 18)
                        .layoutPriority(-1)
                    if on && !broken && !plan.isEmpty { PlanTag(plan: plan, tint: tint, dark: service == "spotify") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(dot).frame(width: 8, height: 8)
            if state == "no", let onPurge {
                AccountButton(label: "Sign in again", primary: true, action: onPurge)
            } else if on {
                AccountButton(label: "Sign out", action: onSignOut)
            } else if let onSignIn {
                AccountButton(label: signInLabel, primary: true, action: onSignIn)
            } else {
                Color.clear.frame(width: 112, height: 30)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x151515))
        .overlay(Rectangle().strokeBorder(Color(hex: 0x232323), lineWidth: 1))
    }
}

/** The plan after the account: square, filled in the service's colour (Spotify's green takes dark text); Free is an outline. */
private struct PlanTag: View {
    let plan: String
    let tint: Color
    let dark: Bool

    var body: some View {
        let free = plan == "Free"
        OmpText(plan, size: Omp.TypeSize.meta, color: free ? Omp.t2 : dark ? Color(hex: 0x0D0D0D) : .white, bold: true)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(free ? Color.clear : tint)
            .overlay(Rectangle().strokeBorder(free ? Color(hex: 0x3A3A3A) : Color.clear, lineWidth: 1))
            .fixedSize()
    }
}

/**
 * The Accounts buttons: 30 high, #1C1C1C with the #333 hairline and 13 pt
 * medium text; Sign in / Connect / Sign in again in the accent. 112 wide, so
 * every row's button is one size (`width` nil: as wide as its label).
 */
private struct AccountButton: View {
    let label: String
    var primary = false
    var width: CGFloat? = 112
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.custom("RedditSans-Medium", fixedSize: Omp.TypeSize.secondary).monospacedDigit())
                .foregroundColor(primary ? .white : Omp.foreground)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: width, height: 30)
                .background(primary ? Omp.themeAccent : Color(hex: 0x1C1C1C))
                .overlay(Rectangle().strokeBorder(primary ? Omp.themeAccent : Color(hex: 0x333333), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
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
