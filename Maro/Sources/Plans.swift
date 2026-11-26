import Foundation

/**
 * Each signed-in service's plan ("Premium", "Duo", "Family", "Student",
 * "Go+", "Free"...), for the tag in Settings > Accounts. Read from answers
 * the services give anyway, as the desktop does: Spotify's ProductInfo (the
 * player's "tier" event), SoundCloud's /me, YouTube Music's Paid memberships
 * page. Kept on the phone with the account it belongs to, so a plan never
 * shows next to another account's name.
 */
@MainActor
final class Plans: ObservableObject {
    static let shared = Plans()

    private let defaults = UserDefaults.standard

    /** key ("spotify", "ytm", "sc") to (account, plan). */
    @Published private(set) var all: [String: (who: String, plan: String)] = [:]

    /** YouTube Music's plan is asked for at most this often (the desktop's 6 hours). */
    private static let ytmEvery: TimeInterval = 6 * 3600

    private init() {
        for key in ["spotify", "ytm", "sc"] {
            let plan = defaults.string(forKey: "plans.\(key).plan") ?? ""
            if !plan.isEmpty { all[key] = (defaults.string(forKey: "plans.\(key).who") ?? "", plan) }
        }
    }

    /** The plan of `key` for `who`; "" when unknown or kept for another account. */
    func of(_ key: String, _ who: String) -> String {
        guard let kept = all[key] else { return "" }
        return kept.who.isEmpty || who.isEmpty || kept.who == who ? kept.plan : ""
    }

    func set(_ key: String, _ who: String, _ plan: String) {
        if plan.isEmpty { return }
        if let kept = all[key], kept.who == who, kept.plan == plan { return }
        defaults.set(who, forKey: "plans.\(key).who")
        defaults.set(plan, forKey: "plans.\(key).plan")
        all[key] = (who, plan)
    }

    /** YouTube Music's plan is due again (none yet, or older than 6 hours). */
    var ytmDue: Bool { Date().timeIntervalSince1970 - defaults.double(forKey: "plans.ytm.at") > Self.ytmEvery }

    func ytmAsked(answered: Bool) {
        // Not answered: try again in 10 minutes instead of 6 hours.
        let now = Date().timeIntervalSince1970
        defaults.set(answered ? now : now - Self.ytmEvery + 600, forKey: "plans.ytm.at")
    }

    // -- the plan in each service's own answer (ports of the desktop's) --------

    /**
     * Spotify's ProductInfo attributes: "type" is premium / free / open; a
     * shared Premium plan names itself (Duo, Family, Student) in the plan's
     * name or product keys. nil when the attributes say nothing.
     */
    nonisolated static func spotify(_ attrs: JSON) -> String? {
        let kind = attrs.str("type").lowercased()
        let words = attrs.keys.filter { $0 != "type" }.map { attrs.str($0).lowercased() }.joined(separator: " ")
        switch kind {
        case "premium":
            if words.contains("family") { return "Family" }
            if words.contains("duo") { return "Duo" }
            if words.contains("student") { return "Student" }
            return "Premium"
        case "free", "open": return "Free"
        default: return nil
        }
    }

    /**
     * SoundCloud's /me: the listener plan ("high_tier" is Go+, "mid_tier" is
     * Go), else a creator Pro plan (Next Pro), else Free when a plan list says
     * "free". nil when /me carries no plan at all.
     */
    nonisolated static func soundcloud(_ me: JSON) -> String? {
        func ids(_ keys: String...) -> [String] {
            keys.flatMap { k -> [String] in
                let list: [JSON]
                switch me[k] {
                case let a as [Any]: list = a.compactMap { $0 as? JSON }
                case let o as JSON: list = [o]
                default: list = []
                }
                return list.compactMap { x in
                    let id = (x["product"] as? JSON)?.str("id") ?? x.str("product").ifEmpty(x.str("id"))
                    return id.isEmpty ? nil : id.lowercased()
                }
            }
        }
        let listen = ids("consumer_subscription", "consumer_subscriptions")
        let create = ids("creator_subscription", "creator_subscriptions")
        if listen.contains(where: { $0 == "high_tier" || $0.contains("go-plus") || $0.contains("go_plus") || $0.contains("goplus") }) { return "Go+" }
        if listen.contains(where: { $0 == "mid_tier" || $0 == "go" || $0.hasPrefix("go-") || $0.hasPrefix("go_") }) { return "Go" }
        if create.contains(where: { $0.contains("pro") || $0.contains("next") }) { return "Next Pro" }
        if (listen + create).contains(where: { $0.contains("free") }) { return "Free" }
        return nil
    }

    /**
     * YouTube Music's "Paid memberships" page (browse FEmemberships_and_purchases):
     * a managed YouTube Premium or YouTube Music Premium membership is Premium
     * (Family / Student / Duo when its plan line says so); none of those is
     * Free. nil when the answer is not that page at all.
     */
    nonisolated static func youtube(_ v: JSON) -> String? {
        let tab = ((v.obj("contents")?.obj("singleColumnBrowseResultsRenderer")?.arr("tabs"))?.first as? JSON)?
            .obj("tabRenderer")?.str("tabIdentifier") ?? ""
        if tab != "FEmemberships_and_purchases" { return nil }
        var best: String?
        for card in membershipCards(v) {
            let p = card.product.lowercased()
            if !card.managed || !(p == "youtube premium" || p.contains("music premium")) { continue }
            let l = card.line.lowercased()
            let plan = l.contains("family") ? "Family" : l.contains("student") ? "Student" : l.contains("duo") ? "Duo" : "Premium"
            if best == nil || best == "Premium" { best = plan }
        }
        return best ?? "Free"
    }

    /** Each membership card on the page: its product, its plan line, whether it is managed (owned). */
    private nonisolated static func membershipCards(_ v: JSON) -> [(product: String, line: String, managed: Bool)] {
        var out: [(product: String, line: String, managed: Bool)] = []
        func label(_ o: JSON?) -> String { o?.obj("accessibility")?.obj("accessibilityData")?.str("label") ?? "" }
        func walk(_ x: Any?) {
            if let o = x as? JSON {
                if let card = o.obj("cardItemContainerRenderer") {
                    let base = card.obj("baseRenderer")?.obj("cardItemRenderer")
                    let head = base?.obj("headingRenderer")?.obj("cardItemTextWithImageRenderer")
                    let img = head?.obj("imageRenderer")?.obj("themedImageRenderer")
                    let product = label(img?.obj("imageLight")).ifEmpty(label(img?.obj("imageDark")))
                    let line = ((head?.arr("textCollectionRenderer") as? [JSON]) ?? []).flatMap { t -> [String] in
                        ((t.obj("cardItemTextCollectionRenderer")?.arr("textRenderers") as? [JSON]) ?? []).map {
                            YTMParse.text($0.obj("cardItemTextRenderer")?.obj("text"))
                        }
                    }.joined(separator: " ")
                    let actions = base?.obj("additionalInfoRenderer")?.obj("cardItemActionsRenderer")?.obj("primaryButtonRenderer")
                    let button = YTMParse.text(actions?.obj("buttonRenderer")?.obj("text"))
                        + YTMParse.text(actions?.obj("toggleButtonRenderer")?.obj("defaultText"))
                    if !product.isEmpty { out.append((product, line, button.lowercased().hasPrefix("manage"))) }
                    return
                }
                for value in o.values { walk(value) }
            } else if let a = x as? [Any] {
                for value in a { walk(value) }
            }
        }
        walk(v["contents"])
        return out
    }
}
