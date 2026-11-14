import Foundation
import CryptoKit
import UIKit
import Observation

struct PurchasedItem: Codable, Hashable {
    let title: String
    let quantity: Int
}

struct CheckoutRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    let brandID: String
    let date: Date
    let itemCount: Int
    let subtotal: Double
    let productIDs: [String]
    var orderID: String? = nil
    var total: Double? = nil
    var currency: String? = nil
    var subtotalCurrency: String? = nil
    var items: [PurchasedItem]? = nil
}

/// A folder of saved products, Airbnb-wishlist style. `cover` is a product
/// id whose photo fronts the folder, "photo" for a picture kept on this
/// device (CoverPhotos), or nil for the newest item's photo.
struct SavedList: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var items: [String] = []
    var cover: String? = nil
    var createdAt: Double = Date().timeIntervalSince1970
}

struct ShopperProfile: Codable, Equatable {
    var saved: [String] = []
    var recentlyViewed: [String] = []
    var recentSearches: [String] = []
    var checkouts: [CheckoutRecord] = []
    var hidden: [String] = []
    var personalizationEnabled = true
    var lists: [SavedList] = []

    init(saved: [String] = [], recentlyViewed: [String] = [], recentSearches: [String] = [], checkouts: [CheckoutRecord] = [],
         hidden: [String] = [], personalizationEnabled: Bool = true, lists: [SavedList] = []) {
        self.saved = saved; self.recentlyViewed = recentlyViewed; self.recentSearches = recentSearches
        self.checkouts = checkouts; self.hidden = hidden; self.personalizationEnabled = personalizationEnabled; self.lists = lists
    }
    // Profiles stored before folders existed have no `lists` key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = try c.decodeIfPresent([String].self, forKey: .saved) ?? []
        recentlyViewed = try c.decodeIfPresent([String].self, forKey: .recentlyViewed) ?? []
        recentSearches = try c.decodeIfPresent([String].self, forKey: .recentSearches) ?? []
        checkouts = try c.decodeIfPresent([CheckoutRecord].self, forKey: .checkouts) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        personalizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .personalizationEnabled) ?? true
        lists = try c.decodeIfPresent([SavedList].self, forKey: .lists) ?? []
    }
}

struct ActivityChange: Codable, Identifiable {
    var id = UUID().uuidString
    let kind: String
    var value: String? = nil
    var enabled: Bool? = nil
    var checkout: CheckoutRecord? = nil
    /// The folder a list operation is about.
    var list: String? = nil
    /// A folder's name, for listCreate and listRename.
    var name: String? = nil
}

/// Guest data stays on this device. Signed-in profiles use separate namespaces
/// and an idempotent outbox, so retries cannot resurrect removed likes/history.
@Observable
final class ShopperStore {
    private let defaults: UserDefaults
    private(set) var profile = ShopperProfile()
    private(set) var pending: [ActivityChange] = []
    private(set) var accountID: String?
    private(set) var feedRevision = 0
    @ObservationIgnored var onChange: (() -> Void)?
    var recentlyViewed: [String] { profile.recentlyViewed }
    var saved: [String] { profile.saved }
    var recentSearches: [String] { profile.recentSearches }
    var checkouts: [CheckoutRecord] { profile.checkouts }
    var hidden: [String] { profile.hidden }
    var lists: [SavedList] { profile.lists }
    var personalizationEnabled: Bool { profile.personalizationEnabled }
    private var key: String { "shopper.profile." + (accountID ?? "guest") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored: ShopperProfile = load("shopper.profile.guest") { profile = stored }
        else {
            profile.recentlyViewed = load("shopper.viewed") ?? []
            profile.saved = load("shopper.saved") ?? []
            profile.recentSearches = load("shopper.searches") ?? []
            profile.checkouts = load("shopper.checkouts") ?? []
            persist()
            for key in ["shopper.viewed", "shopper.saved", "shopper.searches", "shopper.checkouts"] { defaults.removeObject(forKey: key) }
        }
    }

    func activate(_ id: String?) {
        accountID = id
        profile = load(key) ?? ShopperProfile()
        pending = id == nil ? [] : (load(key + ".outbox") ?? [])
        feedRevision += 1
    }
    func accept(_ remote: ShopperProfile, acknowledged: Set<String> = []) {
        let previous = profile
        pending.removeAll { acknowledged.contains($0.id) }
        profile = remote
        for op in pending { apply(op) }
        persist()
        if profile != previous { feedRevision += 1 }
    }
    func eraseAccountCache() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: key + ".outbox")
        activate(nil)
    }
    func importGuestActivity() {
        guard accountID != nil, let guest: ShopperProfile = load("shopper.profile.guest") else { return }
        for id in guest.saved.reversed() { change(ActivityChange(kind: "save", value: id)) }
        if personalizationEnabled {
            for id in guest.recentlyViewed.reversed() { change(ActivityChange(kind: "view", value: id)) }
            for q in guest.recentSearches.reversed() { change(ActivityChange(kind: "search", value: q)) }
        }
        for c in guest.checkouts.reversed() { change(ActivityChange(kind: "checkout", checkout: c)) }
        for l in guest.lists {
            change(ActivityChange(kind: "listCreate", value: l.id, name: l.name))
            for id in l.items.reversed() { change(ActivityChange(kind: "listAdd", value: id, list: l.id)) }
            if let cover = l.cover { change(ActivityChange(kind: "listCover", value: cover, list: l.id)) }
        }
        // Explicit import transfers the guest profile to this account, so the
        // next guest on a shared device cannot see that person's activity.
        defaults.removeObject(forKey: "shopper.profile.guest")
        feedRevision += 1
    }
    func viewed(_ id: String) {
        guard personalizationEnabled, recentlyViewed.first != id else { return }
        SearchMemory.recordAction()
        change(ActivityChange(kind: "view", value: id))
    }
    func isSaved(_ id: String) -> Bool { saved.contains(id) }
    func toggleSaved(_ id: String) {
        let saving = !isSaved(id)
        Analytics.log(saving ? "save" : "unsave", ["product": .string(id)])
        change(ActivityChange(kind: saving ? "save" : "unsave", value: id))
        if saving {
            if personalizationEnabled { SearchMemory.recordAction() }
            Task { @MainActor in TasteProfile.shared.record(id, .save) }
        }
    }

    // MARK: Folders
    static let maxLists = 50
    func list(_ id: String) -> SavedList? { lists.first { $0.id == id } }
    func lists(containing productID: String) -> [SavedList] { lists.filter { $0.items.contains(productID) } }

    // MARK: Quick lists (hold Add to List)

    /// When each list last had something added on this phone.
    private static let usedKey = "lists.usedAt"
    static func markUsed(_ listID: String, at date: Date = .now) {
        var used = UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double] ?? [:]
        used[listID] = date.timeIntervalSince1970
        UserDefaults.standard.set(used, forKey: usedKey)
    }

    /// Holding Add to List (owner, 2026-10-05): the four lists used most
    /// recently, plus the list that holds the most items from the product's
    /// own department (if it isn't one of the four). A list never added to on
    /// this phone counts as used when it was made.
    func quickLists(for product: Product, catalog: CatalogStore) -> (recent: [SavedList], sameCategory: SavedList?) {
        let used = UserDefaults.standard.dictionary(forKey: Self.usedKey) as? [String: Double] ?? [:]
        let recent = Array(lists.sorted { (used[$0.id] ?? $0.createdAt) > (used[$1.id] ?? $1.createdAt) }.prefix(4))
        let taken = Set(recent.map(\.id))
        let match = lists.filter { !taken.contains($0.id) }
            .map { list in (list, list.items.filter { catalog.product($0)?.category == product.category }.count) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        return (recent, match?.0)
    }
    /// Makes a folder and returns its id, or nil at the limit or for a blank name.
    @discardableResult
    func createList(named raw: String) -> String? {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty, lists.count < Self.maxLists else { return nil }
        let id = UUID().uuidString.lowercased()
        Analytics.log("list_create")
        change(ActivityChange(kind: "listCreate", value: id, name: name))
        return id
    }
    func renameList(_ id: String, to raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty, list(id) != nil else { return }
        change(ActivityChange(kind: "listRename", value: id, name: name))
    }
    func deleteList(_ id: String) {
        guard list(id) != nil else { return }
        CoverPhotos.remove(id)
        change(ActivityChange(kind: "listDelete", value: id))
    }
    /// Adding to a folder also saves the item, so "All saved" stays the union.
    func add(_ productID: String, to listID: String) {
        guard list(listID) != nil else { return }
        Self.markUsed(listID)
        Analytics.log("list_add", ["product": .string(productID)])
        if !isSaved(productID) { change(ActivityChange(kind: "save", value: productID)) }
        change(ActivityChange(kind: "listAdd", value: productID, list: listID))
    }
    func remove(_ productID: String, from listID: String) {
        guard list(listID)?.items.contains(productID) == true else { return }
        change(ActivityChange(kind: "listRemove", value: productID, list: listID))
    }
    /// `cover` is a product id in the folder, "photo" for a picture kept on
    /// this device, or nil to go back to the newest item's photo.
    func setCover(_ cover: String?, for listID: String) {
        guard list(listID) != nil else { return }
        change(ActivityChange(kind: "listCover", value: cover ?? "", list: listID))
    }
    func searched(_ raw: String) {
        let q = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard personalizationEnabled, !q.isEmpty else { return }
        SearchMemory.recordSearch(q)
        change(ActivityChange(kind: "search", value: q))
    }
    func clearSearches() { SearchMemory.clear(); change(ActivityChange(kind: "clearSearches")) }
    func removeSearch(_ q: String) { change(ActivityChange(kind: "removeSearch", value: q)) }
    func clearHistory() {
        SearchMemory.clear()
        change(ActivityChange(kind: "clearHistory")); feedRevision += 1
        Task { @MainActor in TasteProfile.shared.clear() }
    }
    func hide(_ id: String) { change(ActivityChange(kind: "hide", value: id)); feedRevision += 1 }
    func unhide(_ id: String) { change(ActivityChange(kind: "unhide", value: id)); feedRevision += 1 }
    func resetHidden() { change(ActivityChange(kind: "resetHidden")); feedRevision += 1 }
    func setPersonalization(_ enabled: Bool) {
        change(ActivityChange(kind: "personalization", enabled: enabled)); feedRevision += 1
        Task { @MainActor in TasteProfile.shared.enabled = enabled }
    }
    func recordCheckout(brandID: String, lines: [CartLine], subtotal: Double,
                        orderID: String? = nil, total: Double? = nil, currency: String? = nil, subtotalCurrency: String? = nil, items: [PurchasedItem]? = nil) {
        if personalizationEnabled { SearchMemory.recordAction() }
        let record = CheckoutRecord(brandID: brandID, date: .now, itemCount: items?.reduce(0) { $0 + $1.quantity } ?? lines.reduce(0) { $0 + $1.quantity },
                                    subtotal: subtotal, productIDs: lines.map(\.productID),
                                    orderID: orderID, total: total, currency: currency, subtotalCurrency: subtotalCurrency, items: items)
        change(ActivityChange(kind: "checkout", checkout: record))
        let bought = lines.map(\.productID)
        Task { @MainActor in
            bought.forEach { TasteProfile.shared.record($0, .purchase) }
            Pairings.report(bought)
        }
    }
    private func change(_ op: ActivityChange) {
        apply(op)
        if accountID != nil { pending.append(op) }
        persist()
        onChange?()
    }
    private func apply(_ op: ActivityChange) {
        func front(_ list: [String], _ value: String, _ limit: Int) -> [String] { Array(([value] + list.filter { $0 != value }).prefix(limit)) }
        switch op.kind {
        case "save": profile.saved = front(saved, op.value!, 500); profile.hidden.removeAll { $0 == op.value }
        case "unsave":
            profile.saved.removeAll { $0 == op.value }
            for i in profile.lists.indices {
                profile.lists[i].items.removeAll { $0 == op.value }
                if profile.lists[i].cover == op.value { profile.lists[i].cover = nil }
            }
        case "listCreate":
            guard let id = op.value, let name = op.name, !lists.contains(where: { $0.id == id }), lists.count < Self.maxLists else { return }
            profile.lists.append(SavedList(id: id, name: String(name.prefix(40))))
        case "listRename":
            guard let i = profile.lists.firstIndex(where: { $0.id == op.value }), let name = op.name else { return }
            profile.lists[i].name = String(name.prefix(40))
        case "listDelete": profile.lists.removeAll { $0.id == op.value }
        case "listAdd":
            guard let i = profile.lists.firstIndex(where: { $0.id == op.list }), let id = op.value else { return }
            profile.lists[i].items = front(profile.lists[i].items, id, 500)
        case "listRemove":
            guard let i = profile.lists.firstIndex(where: { $0.id == op.list }) else { return }
            profile.lists[i].items.removeAll { $0 == op.value }
            if profile.lists[i].cover == op.value { profile.lists[i].cover = nil }
        case "listCover":
            guard let i = profile.lists.firstIndex(where: { $0.id == op.list }) else { return }
            let cover = op.value ?? ""
            profile.lists[i].cover = cover.isEmpty ? nil : (cover == "photo" || profile.lists[i].items.contains(cover) ? cover : profile.lists[i].cover)
        case "view": if personalizationEnabled { profile.recentlyViewed = front(recentlyViewed, op.value!, 100) }
        case "search": if personalizationEnabled { profile.recentSearches = Array(([op.value!] + recentSearches.filter { $0.caseInsensitiveCompare(op.value!) != .orderedSame }).prefix(30)) }
        case "removeSearch": profile.recentSearches.removeAll { $0.caseInsensitiveCompare(op.value!) == .orderedSame }
        case "clearSearches": profile.recentSearches = []
        case "clearHistory": profile.recentSearches = []; profile.recentlyViewed = []
        case "hide": profile.hidden = front(hidden, op.value!, 500)
        case "unhide": profile.hidden.removeAll { $0 == op.value }
        case "resetHidden": profile.hidden = []
        case "personalization":
            profile.personalizationEnabled = op.enabled!
            if !personalizationEnabled { profile.recentSearches = []; profile.recentlyViewed = [] }
        case "checkout":
            guard let c = op.checkout, !checkouts.contains(where: { $0.id == c.id || (c.orderID != nil && $0.orderID == c.orderID && $0.brandID == c.brandID) }) else { return }
            profile.checkouts = Array(([c] + checkouts).prefix(200))
        default: break
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: key) }
        if let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: key + ".outbox") }
    }
    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}


/// Folder cover pictures picked from the shopper's photo library. They stay
/// on this device (the synced profile records only that a photo is in use):
/// the account server never receives personal photos.
enum CoverPhotos {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func url(_ listID: String) -> URL { folder.appendingPathComponent(fileName(listID)) }
    /// The picture's file name. A folder's id comes back from the synced
    /// profile, so it is never trusted as a path: an id that isn't plain
    /// letters, digits, "-" and "_" (the app makes UUIDs) is replaced by its
    /// hash. Until 2026-11-12 an id like "../../x" named a file outside covers.
    static func fileName(_ listID: String) -> String {
        let plain = !listID.isEmpty && listID.count <= 80 && listID.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
        let stem = plain ? listID : SHA256.hash(data: Data(listID.utf8)).map { String(format: "%02x", $0) }.joined()
        return stem + ".jpg"
    }
    static func save(_ data: Data, for listID: String) { try? data.write(to: url(listID), options: .atomic) }
    static func remove(_ listID: String) { try? FileManager.default.removeItem(at: url(listID)) }
    static func image(_ listID: String) -> UIImage? { UIImage(contentsOfFile: url(listID).path) }
}
