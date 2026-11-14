import SwiftUI
import UIKit

/**
 * Friends, the simple way (no avatars, names only): one field to add a
 * friend or paste a jam link; while in a jam a compact strip with its link,
 * Leave (End for the host) and a ⋯ menu; a Waiting section only when someone
 * asked or invited; then the friends, one a line with what they play and one
 * button - Join when they can be joined, else Invite. Swipe a friend (or
 * hold it) to remove them. A full page like Settings: Back or Esc returns.
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
                    JamStrip(jam: jam, together: together)
                        .row(top: 6)
                }
                waiting
                friends
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
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
            OmpText("Searching\u{2026}", size: 11.5, color: Omp.t3).padding(.vertical, 8).row()
        } else if text.trimmingCharacters(in: .whitespaces).count >= 2 && together.results.isEmpty {
            OmpText(text.contains("@") ? "No account with that email." : "Nobody by that name.", size: 11.5, color: Omp.t3)
                .padding(.vertical, 8).row()
        }
        ForEach(together.results) { p in
            PersonLine(name: p.person.name, sub: p.person.username.isEmpty ? "" : "@" + p.person.username) {
                switch p.relation {
                case "friend": OmpText("Friends", size: 11.5, color: Omp.t3)
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
            SettingsHead(label: "Waiting").row(top: 14)
            ForEach(together.invites) { inv in
                let whose = inv.host.id.isEmpty || inv.host.id == inv.from.id ? "their jam" : "\(inv.host.name)'s jam"
                PersonLine(name: inv.from.name, sub: "Invited you to \(whose)", song: inv.track) {
                    MButton("Join", kind: .primary, enabled: !together.isBusy("j:" + inv.code)) { Task { await together.join(inv.code) } }
                    MButton("Decline", kind: .ghost) { Task { await together.declineInvite(inv) } }
                }
                .row()
            }
            ForEach(together.incoming) { p in
                PersonLine(name: p.name, sub: "Wants to be friends") {
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
            SettingsHead(label: "Friends").row(top: 14)
            ForEach(together.friends) { f in
                let inJam = together.jam?.members.contains(where: { $0.id == f.id }) ?? false
                PersonLine(name: f.person.name, sub: "", song: f.track, live: f.playing) {
                    if inJam {
                        OmpText("In your jam", size: 11.5, color: Omp.t3)
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
 * The jam you are in, one compact block: whose it is and how many listen,
 * Copy link, Leave (the host: End), and ⋯ for inviting friends, sharing the
 * link, guest control and removing someone.
 */
private struct JamStrip: View {
    @Environment(\.presentDialog) private var present
    let jam: Jam
    @ObservedObject var together: Together

    var body: some View {
        let n = jam.members.count
        let locked = !jam.youHost && !jam.guestsControl
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    EqBars(color: Omp.soft)
                    OmpText(jam.youHost ? "Your jam" : "Jam with \(jam.host.name)", size: 13, color: Omp.foreground, bold: true)
                }
                OmpText((n <= 1 ? "Only you so far" : "\(n) listening") + (locked ? " \u{B7} add songs only" : ""), size: 11.5, color: Omp.t2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MButton("Copy link") {
                UIPasteboard.general.string = jam.link
                together.vm?.showStatus("Jam link copied", "ok")
            }
            if jam.youHost {
                MButton("End", kind: .danger, enabled: !together.isBusy("end")) { Task { await together.end() } }
            } else {
                MButton("Leave", kind: .danger, enabled: !together.isBusy("leave")) { Task { await together.leave() } }
            }
            MButton("", icon: .more, iconSize: 16) { present(menu) }
                .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Omp.themeAccent.opacity(0.12))
        .overlay(Rectangle().strokeBorder(Omp.themeAccent.opacity(0.7), lineWidth: 1))
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
            if !jam.others.isEmpty {
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
        .menu(title: "Remove someone", items: jam.others.filter { !$0.host }.map { m in
            OmpDialog.Item(icon: .close, label: m.person.name, tint: Omp.danger) { Task { await together.kick(m) } }
        })
    }
}

/** One person a line: the name, a dim line under it (or the song they play), and the buttons. */
private struct PersonLine<Buttons: View>: View {
    let name: String
    var sub = ""
    var song: Track? = nil
    var live = false
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                OmpText(name, size: 13, color: Omp.foreground, bold: true)
                if !sub.isEmpty { OmpText(sub, size: 11.5, color: Omp.t2) }
                if let song, !song.title.isEmpty {
                    OmpText("\u{266A} " + song.title + (song.artist.isEmpty ? "" : " \u{2014} " + song.artist), size: 11.5,
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
