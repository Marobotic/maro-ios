import SwiftUI
import UIKit

/**
 * Friends, kept quiet: one field to add a friend or paste a jam link; the jam
 * card while in one (everyone in it: picture, name, device, Guest or Host); a
 * Waiting section only when someone asked or invited; then the friends, one a
 * line with their picture, what they play and one button - Join when they can
 * be joined, else Invite. Every person leads with the same round picture:
 * their account's, a link guest's drawing, or their initials. Swipe a friend
 * (or hold it) to remove them. Pull down to reload. A full page like
 * Settings: Back or Esc returns.
 */
struct FriendsPage: View {
    @Environment(\.presentDialog) private var present
    @ObservedObject var vm: MaroViewModel
    @ObservedObject var together: Together
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTop(title: "Friends", onBack: { vm.closeFriends() }) {
                if together.jam == nil {
                    MButton("Start a jam", kind: .ghost) { Task { await together.startJam() } }
                }
            }
            OmpTextField(text: $text, placeholder: "Add a friend or paste a jam link") { submit() }
                .padding(.bottom, 10)
            List {
                found
                if let jam = together.jam {
                    FriendsHead(label: "Jam").row(top: 14)
                    JamCard(jam: jam, together: together)
                        .row()
                }
                waiting
                friends
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await together.refresh() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .background(Omp.page.ignoresSafeArea())
        .onChange(of: text) { _, q in together.type(q) }
        .focusable()
        .onKeyPress(.escape) {
            vm.closeFriends()
            return .handled
        }
    }

    private func submit() {
        if let code = together.preview?.code {
            Task { await together.join(code) }
            text = ""
        }
    }

    // -- what the field found ----------------------------------------------------------

    @ViewBuilder private var found: some View {
        if let p = together.preview {
            let title = p.host.isEmpty ? "Jam \(p.code)" : "Jam with \(p.host)"
            let sub = !p.problem.isEmpty ? p.problem : p.members > 0 ? "\(p.members) listening" : "Join jam"
            PersonLine(name: title, sub: sub) {
                MButton("Join", kind: .primary, enabled: p.problem != "This jam has ended" && !together.isBusy("j:" + p.code)) {
                    Task { await together.join(p.code) }
                    text = ""
                }
            }
            .row()
        } else if together.searching {
            OmpText("Searching\u{2026}", size: Omp.TypeSize.secondary, color: Omp.t3).padding(.vertical, 8).row()
        } else if text.trimmingCharacters(in: .whitespaces).count >= 2 && together.results.isEmpty {
            OmpText(text.contains("@") ? "No account with that email." : "Nobody by that name.", size: Omp.TypeSize.secondary, color: Omp.t3)
                .padding(.vertical, 8).row()
        }
        ForEach(together.results) { p in
            PersonLine(name: p.person.name, sub: p.person.username.isEmpty ? "" : "@" + p.person.username, person: p.person) {
                switch p.relation {
                case "friend": OmpText("Friends", size: Omp.TypeSize.secondary, color: Omp.t3)
                case "requested": MButton("Requested", kind: .ghost, enabled: false) {}
                case "incoming":
                    MButton("Accept", kind: .primary, enabled: !together.isBusy("a:" + p.id)) { Task { await together.accept(p.person) } }
                default:
                    MButton("Add", enabled: !together.isBusy("r:" + p.id)) { Task { await together.request(p) } }
                }
            }
            .row()
        }
    }

    // -- friend requests and jam invites ----------------------------------------------

    @ViewBuilder private var waiting: some View {
        if !together.incoming.isEmpty || !together.invites.isEmpty {
            FriendsHead(label: "Waiting").row(top: 14)
            ForEach(together.invites) { inv in
                let whose = inv.host.id.isEmpty || inv.host.id == inv.from.id ? "their jam" : "\(inv.host.name)'s jam"
                PersonLine(name: inv.from.name, sub: "Invited you to \(whose)", song: inv.track, person: inv.from) {
                    MButton("Join", kind: .primary, enabled: !together.isBusy("j:" + inv.code)) { Task { await together.join(inv.code) } }
                    MButton("Decline", kind: .ghost) { Task { await together.declineInvite(inv) } }
                }
                .row()
            }
            ForEach(together.incoming) { p in
                PersonLine(name: p.name, sub: "Wants to be friends", person: p) {
                    MButton("Accept", kind: .primary, enabled: !together.isBusy("a:" + p.id)) { Task { await together.accept(p) } }
                    MButton("Decline", kind: .ghost) { Task { await together.decline(p) } }
                }
                .row()
            }
        }
    }

    // -- the friends ---------------------------------------------------------------

    @ViewBuilder private var friends: some View {
        if !together.friends.isEmpty {
            FriendsHead(label: "Friends").row(top: 14)
            ForEach(together.friends) { f in
                let inJam = together.jam?.members.contains(where: { $0.id == f.id }) ?? false
                PersonLine(name: f.person.name, sub: "", song: f.track, live: f.playing, person: f.person) {
                    if inJam {
                        OmpText("In your jam", size: Omp.TypeSize.secondary, color: Omp.t3)
                    } else if f.joinable && f.jamCode != together.jam?.id {
                        MButton("Join", kind: .primary, enabled: !together.isBusy("fj:" + f.id)) { Task { await together.joinFriend(f) } }
                    } else {
                        let sent = together.invited.contains(f.id)
                        MButton(sent ? "Invited" : "Invite", kind: sent ? .ghost : .normal,
                                enabled: !sent && !together.isBusy("inv:" + f.id)) { Task { await together.invite(f) } }
                    }
                }
                .onLongPressGesture { present(removeMenu(f.person)) }
                .row()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { present(confirmRemove(f.person)) } label: { Text("Remove") }
                        .tint(Omp.themeAccent)
                }
            }
        }
    }

    private func removeMenu(_ p: Person) -> OmpDialog {
        .menu(title: p.name, items: [
            OmpDialog.Item(icon: .trash, label: "Remove friend", closes: false, tint: Omp.danger) { present(confirmRemove(p)) },
        ])
    }

    private func confirmRemove(_ p: Person) -> OmpDialog {
        .confirm(message: "Remove \(p.name) from your friends?", confirm: "Remove") { Task { await together.remove(p) } }
    }
}

/**
 * The jam you are in, its own card: whose it is and how many listen, Copy
 * link, Leave (the host: End), and ⋯ for inviting friends, sharing the link,
 * guest control and removing someone; under it everyone in the jam, the host
 * first, one row each. The host removes someone with a long press too.
 */
private struct JamCard: View {
    @Environment(\.presentDialog) private var present
    let jam: Jam
    @ObservedObject var together: Together

    /** Who the host can remove: not the host, not a link guest. */
    private var removable: [Jam.Member] { jam.others.filter { !$0.host && !$0.guest } }

    /** The host first, then everyone else. */
    private var ordered: [Jam.Member] {
        let hosts: [Jam.Member] = jam.members.filter { $0.host }
        let rest: [Jam.Member] = jam.members.filter { !$0.host }
        return hosts + rest
    }

    private var title: String { jam.youHost ? "Your jam" : "Jam with \(jam.host.name)" }

    private var countLine: String {
        let n = jam.members.count
        let locked = !jam.youHost && !jam.guestsControl
        let head: String = n <= 1 ? "Just you" : "\(n) listening"
        return locked ? head + "  \u{B7}  you can add songs" : head
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Omp.themeAccent.opacity(0.30)).frame(height: 1)
            people
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Omp.themeAccent.opacity(0.10))
        .overlay(Rectangle().strokeBorder(Omp.themeAccent.opacity(0.55), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                OmpText(title, size: Omp.TypeSize.body, color: Omp.foreground, bold: true)
                OmpText(countLine, size: Omp.TypeSize.meta, color: Omp.t2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MButton("Copy link") {
                UIPasteboard.general.string = jam.link
                together.vm?.showStatus("Jam link copied", "ok")
            }
            endButton
            MButton("", icon: .more, iconSize: 16) { present(menu) }
                .accessibilityLabel("More")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var endButton: some View {
        if jam.youHost {
            MButton("End", kind: .danger, enabled: !together.isBusy("end")) { Task { await together.end() } }
        } else {
            MButton("Leave", kind: .danger, enabled: !together.isBusy("leave")) { Task { await together.leave() } }
        }
    }

    private var people: some View {
        VStack(spacing: 0) {
            ForEach(ordered) { (m: Jam.Member) in
                MemberRow(member: m, me: m.id == jam.me)
                    .onLongPressGesture { longPress(m) }
            }
        }
        .padding(.vertical, 4)
    }

    private func longPress(_ m: Jam.Member) {
        let me = m.id == jam.me
        if jam.youHost && !m.host && !m.guest && !me { present(confirmKick(m)) }
    }

    private func confirmKick(_ m: Jam.Member) -> OmpDialog {
        .confirm(message: "Remove \(m.person.name) from the jam?", confirm: "Remove") { Task { await together.kick(m) } }
    }

    private var menu: OmpDialog {
        typealias Item = OmpDialog.Item
        var items: [Item] = [
            Item(icon: .plus, label: "Invite friends", closes: false) { present(inviteMenu) },
            Item(icon: .link, label: "Share link\u{2026}") { presentShareSheet(jam.link, subject: "Listen together on Jukebox") },
        ]
        if jam.youHost {
            items.append(Item(icon: jam.guestsControl ? Glyph.check : nil, label: "Guests can control",
                              tint: jam.guestsControl ? Omp.soft : Omp.foreground,
                              detail: jam.guestsControl ? "They can play, pause and skip" : "They can add songs only") {
                Task { await together.setGuestsControl(!jam.guestsControl) }
            })
            if !removable.isEmpty {
                items.append(Item(icon: .close, label: "Remove someone", closes: false) { present(kickMenu) })
            }
        }
        return .menu(title: jam.youHost ? "Your jam" : "Jam with \(jam.host.name)", items: items)
    }

    private var inviteMenu: OmpDialog {
        let open = together.friends.filter { f in !jam.members.contains { $0.id == f.id } }
        if open.isEmpty {
            return .menu(title: "Invite friends", items: [
                OmpDialog.Item(icon: .link, label: "Share the link instead", detail: "Every friend is here already, or add one first") {
                    presentShareSheet(jam.link, subject: "Listen together on Jukebox")
                },
            ])
        }
        return .menu(title: "Invite friends", items: open.map { f in
            let sent = together.invited.contains(f.id)
            return OmpDialog.Item(icon: sent ? Glyph.check : Glyph.plus, label: f.person.name, tint: sent ? Omp.t2 : Omp.foreground,
                                  detail: sent ? "Invited" : "") { if !sent { Task { await together.invite(f) } } }
        })
    }

    private var kickMenu: OmpDialog {
        .menu(title: "Remove someone", items: removable.map { m in
            OmpDialog.Item(icon: .close, label: m.person.name, tint: Omp.danger) { Task { await together.kick(m) } }
        })
    }
}

/** One person a line: their picture, the name, a dim line under it (or the song they play), and the buttons. */
private struct PersonLine<Buttons: View>: View {
    let name: String
    var sub = ""
    var song: Track? = nil
    var live = false
    var person: Person? = nil
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            if let person { Pfp(person: person).padding(.trailing, 2) }
            VStack(alignment: .leading, spacing: 3) {
                OmpText(name, size: Omp.TypeSize.rowTitle, color: Omp.foreground, bold: true)
                if !sub.isEmpty { OmpText(sub, size: Omp.TypeSize.secondary, color: Omp.t2) }
                if let song, !song.title.isEmpty {
                    OmpText("\u{266A} " + song.title + (song.artist.isEmpty ? "" : " \u{2014} " + song.artist), size: Omp.TypeSize.secondary,
                            color: live ? Omp.t2 : Omp.t3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Omp.row)
        .overlay(Rectangle().strokeBorder(Omp.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/** A section's head in the library's red, in sentence case ("Jam", "Waiting", "Friends"). */
private struct FriendsHead: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Omp.font(Omp.TypeSize.secondary, bold: true))
            .foregroundColor(Omp.headRed)
            .padding(.leading, 6)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/** One person in the jam: picture, name, the device they listen on, Guest or Host. */
private struct MemberRow: View {
    let member: Jam.Member
    let me: Bool

    var body: some View {
        let p = member.person
        HStack(spacing: 8) {
            Pfp(person: p).padding(.trailing, 2)
            OmpText(p.name.ifBlank(member.guest ? "Guest" : p.username.ifBlank("Someone")), size: Omp.TypeSize.rowTitle,
                    color: Omp.foreground, bold: true)
                .layoutPriority(-1)
            if me { OmpText("(you)", size: Omp.TypeSize.body, color: Omp.t2).fixedSize() }
            if !member.device.isEmpty { OmpText(member.device, size: Omp.TypeSize.body, color: Omp.t2).fixedSize() }
            if member.guest { SquareTag(label: "Guest", text: Color(hex: 0xE0E0E0), fill: Color(hex: 0x222222), edge: Color(hex: 0x3A3A3A)) }
            if member.host {
                SquareTag(label: "Host", text: Color(hex: 0xE87878), fill: Omp.themeAccent.opacity(0.14), edge: Omp.themeAccent.opacity(0.60))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/** A square tag: Guest in grey, Host in the jam's red. */
private struct SquareTag: View {
    let label: String
    let text: Color
    let fill: Color
    let edge: Color

    var body: some View {
        OmpText(label, size: Omp.TypeSize.meta, color: text)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(fill)
            .overlay(Rectangle().strokeBorder(edge, lineWidth: 1))
            .fixedSize()
    }
}

/**
 * A round picture, `size` across: the account's (or a link guest's drawing),
 * the server's copy made at that size and drawn 1:1, or the name's letters on
 * a tint picked by their id.
 */
struct Pfp: View {
    let person: Person
    var size: CGFloat = 32
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private static let tints: [Color] = [Color(hex: 0x7D3B3B), Color(hex: 0x3B5A7D), Color(hex: 0x3B7D5E),
                                         Color(hex: 0x6C4A80), Color(hex: 0x7D653B), Color(hex: 0x4A4A7D)]

    var body: some View {
        let px = Int((size * displayScale).rounded())
        let url = PfpURL.sized(person.avatar, px: px)
        ZStack {
            Self.tint(person)
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                OmpText(PfpURL.initials(person.name.ifBlank(person.username)), size: Omp.TypeSize.body, color: Omp.foreground, bold: true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            guard !url.isEmpty else { image = nil; return }
            let key = ArtLoader.shared.key(artKey: "", artUrl: url, px: px)
            if let hit = ArtLoader.shared.cached(key) { image = hit; return }
            for attempt in 0..<2 {
                if let got = await ArtLoader.shared.load(artKey: "", artUrl: url, px: px) { image = got; return }
                if attempt == 0 { await sleep(seconds: 1.5) }
                if Task.isCancelled { return }
            }
        }
    }

    private static func tint(_ p: Person) -> Color {
        var h: UInt32 = 0
        for u in p.id.ifEmpty(p.name).unicodeScalars { h = h &* 31 &+ u.value }
        return tints[Int(h % UInt32(tints.count))]
    }
}

private extension View {
    /** A List row in the page's look: no system background, separator or insets; 2 pt between blocks. */
    func row(top: CGFloat = 1) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 0, bottom: 1, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/**
 * A jam invite as it arrives: who, the song they play, Join and Decline, in
 * the toast's box at the top of the app. It stays until answered or closed
 * (the invite also waits on the Friends page).
 */
struct InviteBanner: View {
    @ObservedObject var together: Together

    var body: some View {
        ZStack {
            if let inv = together.banner {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 11) {
                        Rectangle().fill(Omp.themeAccent).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            OmpText("\(inv.from.name.ifEmpty("A friend")) invited you to listen together", size: 12.5,
                                    color: Omp.foreground, bold: true, maxLines: 2)
                            if let t = inv.track, !t.title.isEmpty {
                                OmpText("\u{266A} " + t.title + (t.artist.isEmpty ? "" : " \u{2014} " + t.artist), size: 11.5, color: Omp.t2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        TButton(.close, size: 11, box: 26, color: Omp.t3) { together.banner = nil }
                            .accessibilityLabel("Close")
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        MButton("Decline", kind: .ghost) { Task { await together.declineInvite(inv) } }
                        MButton("Join", kind: .primary, enabled: !together.isBusy("j:" + inv.code)) { Task { await together.join(inv.code) } }
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .background(Color(hex: 0x1C1C1C))
                .overlay(Rectangle().strokeBorder(Omp.themeAccent, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 15, y: 12)
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .task(id: inv.id) {
                    await sleep(seconds: 45)
                    if !Task.isCancelled && together.banner?.id == inv.id { together.banner = nil }
                }
                .transition(.opacity.combined(with: .offset(y: -16)))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3), value: together.banner?.id)
    }
}

/** The player's one line while in a jam: "Listening together with Name +2"; a tap opens Friends. */
struct TogetherLine: View {
    @ObservedObject var vm: MaroViewModel
    @ObservedObject var together: Together

    var body: some View {
        if let jam = together.jam {
            let others = jam.others
            let text = others.first.map { "Listening together with \($0.person.name)" + (others.count > 1 ? " +\(others.count - 1)" : "") }
                ?? "Your jam is open \u{B7} invite friends"
            Button { vm.openFriends() } label: {
                HStack(spacing: 8) {
                    Icon(.people, size: 12, color: Omp.soft)
                    OmpText(text, size: 11, color: Omp.soft)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }
}

/** The player's people button: starts a jam (and opens Friends), or opens the one you are in. */
struct JamButton: View {
    @ObservedObject var vm: MaroViewModel
    @ObservedObject var together: Together

    var body: some View {
        TButton(.people, size: 15, box: 32, color: together.jam != nil ? Omp.soft : Omp.t3) {
            if together.jam != nil {
                vm.openFriends()
            } else {
                Task {
                    await together.startJam()
                    if together.jam != nil { vm.openFriends() }
                }
            }
        }
        .accessibilityLabel(together.jam != nil ? "Open the jam" : "Start a jam")
    }
}
