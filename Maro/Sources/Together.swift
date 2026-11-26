import CryptoKit
import Foundation

/**
 * Listen together: friends, what they are playing, and jams (the account's
 * /friends, /social, /jam and /invites calls, plans/listen-together-api.md),
 * mirrored from the desktop's app/src/social.rs.
 *
 * A jam is the host's own shared player. The host plays as always. A guest's
 * phone follows it (MaroViewModel's "listening together" part): the host's
 * queue plays here at the host's second, every press goes to the host as a
 * jam command, and nothing is published to this account's own player. This
 * store holds what the Friends page draws and makes the calls; the friends
 * list is read every 15 s only while that page is open, and right after any
 * social message.
 */
/**
 * A person on the wire: never an email, their id is the sha256 of it.
 * `avatar` is their picture's address ("" when they have none): an account's
 * is https://marobotic.dev/cache/avatar/<id>?v=<n>, a link guest's a drawing.
 */
struct Person: Identifiable, Equatable, Hashable {
    var id = ""
    var name = ""
    var username = ""
    var avatar = ""

    static func from(_ o: JSON?) -> Person {
        guard let o else { return Person() }
        let username = o.str("username")
        return Person(id: o.str("id"), name: o.str("name").ifEmpty(username), username: username, avatar: o.str("avatar"))
    }
}

struct Friend: Identifiable, Equatable {
    var person: Person
    var online = false
    var playing = false
    /** What they play, nil when they share nothing. */
    var track: Track?
    /** The jam they are in, if any. */
    var jamCode = ""
    var joinable = false
    var id: String { person.id }

    static func from(_ o: JSON) -> Friend {
        let l = o.obj("listening") ?? [:]
        let t = l.obj("track")
        return Friend(person: .from(o), online: l.bool("online"), playing: l.bool("playing"),
                      track: t.map { Track.from($0) }, jamCode: l.obj("jam")?.str("code") ?? "", joinable: l.bool("joinable"))
    }
}

/** A search answer: someone and how they relate to this account. */
struct FoundPerson: Identifiable, Equatable {
    var person: Person
    /** none, requested, incoming or friend. */
    var relation: String
    var id: String { person.id }
}

struct JamInvite: Identifiable, Equatable {
    var id: Int
    var code: String
    var from: Person
    var host: Person
    var track: Track?

    static func from(_ o: JSON) -> JamInvite {
        JamInvite(id: o.int("id"), code: o.str("jam"), from: .from(o.obj("from")), host: .from(o.obj("host")),
                  track: o.obj("track").map { Track.from($0) })
    }
}

struct Jam: Equatable {
    /**
     * One member: `device` is what they listen on ("iPhone", "Windows",
     * "Web"..., "" when the server does not know); `guest` is someone who came
     * in by the link without an account (they only listen, and can't be removed).
     */
    struct Member: Identifiable, Equatable {
        var person: Person
        var host: Bool
        var device = ""
        var guest = false
        var id: String { person.id }
    }

    var id = ""
    var link = ""
    var host = Person()
    var youHost = false
    var linkOpen = true
    var guestsControl = true
    var members: [Member] = []
    /** This account's person id (the sha256 of its email). */
    var me = ""

    /** Everyone but this account, the host first. */
    var others: [Member] { members.filter { $0.id != me } }

    static func from(_ v: JSON?, me: String) -> Jam? {
        guard let v, !v.str("id").isEmpty else { return nil }
        let members = (v.arr("members") ?? []).compactMap { $0 as? JSON }.map {
            Member(person: .from($0), host: $0.bool("host"), device: $0.str("device"), guest: $0.bool("guest"))
        }
        return Jam(id: v.str("id"), link: v.str("link").ifEmpty(JamLink.link(v.str("id"))), host: .from(v.obj("host")),
                   youHost: v.bool("you_host"), linkOpen: v.bool("link_open", true), guestsControl: v.bool("guests_control", true),
                   members: members.sorted { $0.host && !$1.host }, me: me)
    }
}

/** Who a pasted jam link belongs to, before joining (GET /jampreview). */
struct JamPreview: Equatable {
    var code: String
    var host = ""
    var members = 0
    /** Not joinable: ended, or friends-only and not a friend. */
    var problem = ""
}

@MainActor
final class Together: ObservableObject {
    @Published private(set) var jam: Jam?
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var incoming: [Person] = []
    @Published private(set) var outgoing: [Person] = []
    @Published private(set) var invites: [JamInvite] = []
    @Published private(set) var shareListening = true
    @Published private(set) var friendsCanJoin = true
    @Published private(set) var results: [FoundPerson] = []
    @Published private(set) var searching = false
    @Published private(set) var preview: JamPreview?
    /** Presses waiting for their answer, by key: their buttons show it. */
    @Published private(set) var busy: Set<String> = []
    /** Friends invited to the jam open now. */
    @Published private(set) var invited: Set<String> = []
    /** An invite that just arrived: the banner over the app. */
    @Published var banner: JamInvite?

    weak var vm: MaroViewModel?
    private let client: MaroClient
    /** A jam link opened before the account was signed in. */
    private var pendingCode = ""
    private var pageTimer: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var query = ""

    init(client: MaroClient) {
        self.client = client
    }

    /** Friend requests and invites waiting: the people button's dot. */
    var waiting: Int { incoming.count + invites.count }

    /** Following a host as a guest. */
    var guest: Bool { jam.map { !$0.youHost } ?? false }

    /** A person's id is the sha256 of their lowercased email. */
    private var me: String {
        let email = (client.email ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func esc(_ s: String) -> String { MaroClient.escape(s) }

    private func say(_ msg: String, _ kind: String = "ok") { vm?.showStatus(msg, kind) }

    /** A press: its button shows it is working, the answer's error is said, the lists read again. */
    @discardableResult
    private func act(_ key: String, _ method: String, _ path: String, body: JSON? = nil) async -> JSON? {
        if busy.contains(key) { return nil }
        busy.insert(key)
        let out = await client.social(method, path, body: body)
        busy.remove(key)
        if !out.bool("ok") { say(out.str("error"), "error") }
        Task { await refresh() }
        return out.bool("ok") ? out : nil
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    // -- the lists ---------------------------------------------------------------

    func refresh() async {
        guard client.session != nil else { return }
        async let f = client.social("GET", "/friends")
        async let i = client.social("GET", "/invites")
        let (friendsDoc, invitesDoc) = await (f, i)
        if friendsDoc.bool("ok") {
            let list = (friendsDoc.arr("friends") ?? []).compactMap { $0 as? JSON }.map(Friend.from)
            if list != friends { friends = list }
            let inc = (friendsDoc.arr("incoming") ?? []).compactMap { $0 as? JSON }.map { Person.from($0) }
            if inc != incoming { incoming = inc }
            let out = (friendsDoc.arr("outgoing") ?? []).compactMap { $0 as? JSON }.map { Person.from($0) }
            if out != outgoing { outgoing = out }
        }
        if invitesDoc.bool("ok") {
            let list = (invitesDoc.arr("invites") ?? []).compactMap { $0 as? JSON }.map(JamInvite.from)
            if list != invites { invites = list }
        }
    }

    /** The Friends page opened or closed: its list is kept fresh only while it shows. */
    func pageShown(_ on: Bool) {
        pageTimer?.cancel()
        pageTimer = nil
        guard on else { return }
        pageTimer = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                await sleep(seconds: 15)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func loadSettings() async {
        let out = await client.social("GET", "/social/settings")
        guard out.bool("ok") else { return }
        shareListening = out.bool("share_listening", true)
        friendsCanJoin = out.bool("friends_can_join", true)
    }

    func setShareListening(_ on: Bool) { setSetting("share_listening", on) }
    func setFriendsCanJoin(_ on: Bool) { setSetting("friends_can_join", on) }

    private func setSetting(_ key: String, _ on: Bool) {
        func put(_ v: Bool) { if key == "share_listening" { shareListening = v } else { friendsCanJoin = v } }
        put(on)
        Task {
            let out = await client.social("PUT", "/social/settings", body: [key: on])
            if !out.bool("ok") {
                put(!on)
                say(out.str("error").ifEmpty("Could not save that"), "error")
            }
        }
    }

    // -- the one field: a name, an email or a jam link ----------------------------------

    func type(_ text: String) {
        query = text
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = JamLink.code(q) {
            results = []
            searching = false
            if preview?.code != code { preview = JamPreview(code: code) }
            searchTask = Task { await lookUp(code) }
            return
        }
        preview = nil
        guard q.count >= 2 else {
            results = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            await sleep(seconds: 0.35)
            if Task.isCancelled { return }
            let out = await client.social("GET", "/social/search?q=" + esc(q))
            if Task.isCancelled || query.trimmingCharacters(in: .whitespacesAndNewlines) != q { return }
            searching = false
            results = (out.arr("people") ?? []).compactMap { $0 as? JSON }.map { FoundPerson(person: .from($0), relation: $0.str("relation", "none")) }
        }
    }

    /** Whose jam a pasted link is (no session needed). */
    private func lookUp(_ code: String) async {
        let out = await client.social("GET", "/jampreview/" + esc(code))
        guard !Task.isCancelled, preview?.code == code else { return }
        var p = JamPreview(code: code)
        if out.bool("ok") {
            p.host = out.obj("host").map { Person.from($0).name } ?? ""
            p.members = out.int("members")
        } else if out.bool("private") {
            p.host = out.obj("host").map { Person.from($0).name } ?? ""
            p.problem = "Friends only"
        } else if out.int("status") == 404 {
            p.problem = "This jam has ended"
        }
        preview = p
    }

    func request(_ p: FoundPerson) async {
        guard let out = await act("r:" + p.id, "POST", "/friends/request", body: ["id": p.id]) else { return }
        let relation = out.str("relation", "requested")
        setRelation(p.id, relation)
        say(relation == "friend" ? "You and \(p.person.name) are friends now" : "Friend request sent to \(p.person.name)")
    }

    func accept(_ p: Person) async {
        guard await act("a:" + p.id, "POST", "/friends/accept", body: ["id": p.id]) != nil else { return }
        setRelation(p.id, "friend")
        say("You and \(p.name) are friends now")
    }

    func decline(_ p: Person) async {
        guard await act("d:" + p.id, "POST", "/friends/decline", body: ["id": p.id]) != nil else { return }
        setRelation(p.id, "none")
    }

    /** Unfriend, or take back a request. */
    func remove(_ p: Person) async {
        guard await act("x:" + p.id, "DELETE", "/friends/" + esc(p.id)) != nil else { return }
        friends.removeAll { $0.id == p.id }
        setRelation(p.id, "none")
    }

    private func setRelation(_ id: String, _ relation: String) {
        if let i = results.firstIndex(where: { $0.id == id }) { results[i].relation = relation }
    }

    // -- jams ------------------------------------------------------------------------------

    func startJam() async {
        guard let vm else { return }
        // A jam is this account's shared player: a phone playing on its own isn't on it.
        if vm.playsSolo { vm.setSolo(false) }
        guard let out = await act("start", "POST", "/jam", body: [:]), let view = out.obj("jam") else { return }
        await apply(view, full: true)
        say("Jam started. Invite friends or share the link.")
    }

    /** Join by code (a link, an invite); waits for the sign-in when signed out. */
    func join(_ code: String) async {
        guard !code.isEmpty else { return }
        guard client.session != nil else {
            pendingCode = code
            say("Sign in to your Jukebox account to join the jam", "info")
            return
        }
        let look = await client.social("GET", "/jam/" + esc(code))
        guard look.bool("ok") else { return say(look.str("error"), "error") }
        guard let out = await act("j:" + code, "POST", "/jam/\(esc(code))/join"), let view = out.obj("jam") else { return }
        banner = nil
        await apply(view, full: true)
        say("Joined \(Person.from(view.obj("host")).name.ifEmpty("the"))'s jam")
        vm?.openFriends()
    }

    func joinFriend(_ f: Friend) async {
        guard let out = await act("fj:" + f.id, "POST", "/friends/\(esc(f.id))/join"), let view = out.obj("jam") else { return }
        await apply(view, full: true)
        say("Listening along with \(f.person.name)")
    }

    func invite(_ f: Friend) async {
        if jam == nil { await startJam() }
        guard let code = jam?.id else { return }
        guard await act("inv:" + f.id, "POST", "/jam/\(esc(code))/invite", body: ["id": f.id]) != nil else { return }
        invited.insert(f.id)
        say("Invited \(f.person.name) to listen")
    }

    func leave() async {
        guard let code = jam?.id else { return }
        busy.insert("leave")
        let out = await client.social("POST", "/jam/\(esc(code))/leave")
        busy.remove("leave")
        // Gone from the jam either way when the server no longer has it.
        if out.bool("ok") || out.int("status") == 404 {
            ended("")
            say("Left the jam. Your own queue is back.")
        } else {
            say(out.str("error"), "error")
        }
    }

    func end() async {
        guard let code = jam?.id else { return }
        guard await act("end", "DELETE", "/jam/" + esc(code)) != nil else { return }
        ended("")
        say("Jam ended")
    }

    func kick(_ m: Jam.Member) async {
        guard let code = jam?.id,
              let out = await act("kick:" + m.id, "POST", "/jam/\(esc(code))/kick", body: ["id": m.id]) else { return }
        if let view = out.obj("jam") { await apply(view, full: false) }
        say("\(m.person.name) was removed from the jam")
    }

    func setGuestsControl(_ on: Bool) async {
        guard let code = jam?.id,
              let out = await act("gc", "PATCH", "/jam/" + esc(code), body: ["guests_control": on]),
              let view = out.obj("jam") else { return }
        await apply(view, full: false)
    }

    func declineInvite(_ inv: JamInvite) async {
        if banner?.id == inv.id { banner = nil }
        await act("id:\(inv.id)", "POST", "/invites/\(inv.id)/decline")
        invites.removeAll { $0.id == inv.id }
    }

    /** A guest's press for the host's player; a refusal is said. */
    func command(_ action: String, _ payload: JSON = [:]) async -> Bool {
        guard let code = jam?.id else { return false }
        let out = await client.social("POST", "/jam/\(esc(code))/command", body: ["action": action, "payload": payload])
        if !out.bool("ok") { say(out.str("error"), "error") }
        return out.bool("ok")
    }

    /** Whether a guest may send this press now (the host can allow queue adds only). */
    func allows(_ action: String) -> Bool {
        JamFollow.allowed(action, guestsControl: jam?.guestsControl ?? true)
    }

    // -- links, sign-in, the relay ---------------------------------------------------------

    /** https://marobotic.dev/jukebox/jam/<code> or jukebox://jam/<code>, opened from outside. */
    func openLink(_ url: String) {
        guard let code = JamLink.code(url) else {
            ConsoleLog.shared.info("Together", "Not a jam link: \(url)")
            return
        }
        ConsoleLog.shared.info("Together", "Opening the jam \(code)")
        Task { await join(code) }
    }

    /** Signed in (or started signed in): the jam this account is in, and a link opened meanwhile. */
    func signedIn() async {
        await sync()
        await refresh()
        if !pendingCode.isEmpty {
            let code = pendingCode
            pendingCode = ""
            await join(code)
        }
    }

    /** At start and after signing in: followed again if a guest; a queue put aside by a jam that ended comes back. */
    func sync() async {
        let out = await client.social("GET", "/jam")
        guard out.bool("ok") else { return }
        if let view = out.obj("jam") { await apply(view, full: true) } else { ended("") }
    }

    /** Signed out: in no jam, nothing listed. */
    func reset() {
        pageShown(false)
        jam = nil
        friends = []; incoming = []; outgoing = []; invites = []; results = []
        invited = []
        banner = nil
        preview = nil
    }

    /** The relay's "jam" and "social" messages. */
    func onRelay(_ type: String, _ p: JSON) async {
        if type == "jam" {
            if p.bool("ended") {
                if jam == nil || jam?.id == p.str("id") { ended(p.str("reason").ifEmpty("the jam ended")) }
            } else {
                await apply(p, full: false)
            }
            return
        }
        switch p.str("event") {
        case "friend.request":
            say("\(Person.from(p.obj("from")).name) sent you a friend request", "info")
        case "friend.accepted":
            say("\(Person.from(p.obj("friend")).name) accepted your friend request")
        case "jam.invite":
            if let inv = p.obj("invite") { banner = JamInvite.from(inv) }
        case "jam.joined":
            say("\(Person.from(p.obj("who")).name) joined your jam")
        default:
            break
        }
        await refresh()
    }

    /** A jam view from a call or a push. */
    private func apply(_ v: JSON, full: Bool) async {
        var view = v
        let guest = !view.bool("you_host")
        // A push without the queue keeps the one held; when that one is older
        // than the server's, the whole view is read again.
        if guest, !full, let p = view.obj("player"), p["queue"] == nil, (vm?.jamQueueRev ?? -1) != p.int("queueRev", -1) {
            let fresh = await client.social("GET", "/jam/" + esc(view.str("id")))
            if let j = fresh.obj("jam") { view = j }
        }
        let next = Jam.from(view, me: me)
        if next?.id != jam?.id { invited = [] }
        if next != jam { jam = next }
        await vm?.jamView(view, guest: guest)
    }

    /** The jam is over for this phone (ended, left, removed). */
    private func ended(_ reason: String) {
        let had = jam != nil
        jam = nil
        invited = []
        vm?.jamEnded()
        if had && !reason.isEmpty { say("The jam ended: \(reason)", "info") }
    }
}
