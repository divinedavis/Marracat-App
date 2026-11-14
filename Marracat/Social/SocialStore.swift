import CryptoKit
import Foundation
import Observation

/// Comments, profiles, friends and encrypted sharing, against /api/social —
/// the same server the website uses, so a friend added on one shows up on the
/// other. Signed-out shoppers can read comments; everything else needs an
/// account.
@MainActor @Observable
final class SocialStore {
    struct Profile: Codable, Hashable { let handle: String; let name: String }
    struct Counts: Codable { let incoming: Int; let unseen_shares: Int; var reports: Int? }
    struct Me: Codable { let profile: Profile; let agreed_terms: Bool; let owner: Bool; let counts: Counts }
    struct Comment: Codable, Identifiable, Hashable {
        let id: String
        let author: Profile?
        let body: String
        let created_at: Double
        let mine: Bool
        let deleted: Bool
        let under_review: Bool
        var replies: [Comment]?
        /// Likes (2026-11-04); absent from an older server, read as none.
        var likes: Int? = nil
        var liked: Bool? = nil
        var date: Date { Date(timeIntervalSince1970: created_at / 1000) }
        var likeCount: Int { likes ?? 0 }
        var isLiked: Bool { liked ?? false }
    }
    struct Viewer: Codable { let signed_in: Bool; let agreed_terms: Bool; let owner: Bool }
    struct Thread: Codable { let comments: [Comment]; let viewer: Viewer? }
    struct Friends: Codable { var friends: [Profile] = []; var incoming: [Profile] = []; var outgoing: [Profile] = [] }
    struct Person: Codable, Hashable, Identifiable { let handle: String; let name: String; var relationship: String; var id: String { handle } }
    struct ProfileReply: Codable { let profile: Profile; let relationship: String }
    struct Share: Codable, Identifiable { let id: String; let from: Profile; let created_at: Double; let seen: Bool; let envelope: ShareCrypto.Envelope? }
    struct Received: Identifiable { let share: Share; let message: ShareCrypto.Message?; var id: String { share.id } }

    /// What the server said when it said no, in its own words.
    struct Refused: LocalizedError {
        let status: Int, message: String, code: String?
        var errorDescription: String? { message }
        var needsTerms: Bool { code == "terms_required" }
    }

    private(set) var me: Me?
    private(set) var friends = Friends()
    private(set) var inbox: [Received] = []
    private(set) var blocked: [Profile] = []
    /// Bumped whenever something might change what a comment list shows, so
    /// open product pages reload.
    private(set) var revision = 0

    private let account: AccountStore
    @ObservationIgnored private var deviceAccount: String?
    @ObservationIgnored private var retriedDevice = false

    init(account: AccountStore) {
        self.account = account
        account.willSignOut = { [weak self] in await self?.retireDevice() }
    }

    var signedIn: Bool { account.signedIn }

    // --- plumbing ------------------------------------------------------------

    private struct ErrorBody: Decodable { let error: String?; let code: String? }

    @discardableResult
    private func send(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let (status, data) = try await account.social(path, method: method, body: body)
        guard (200..<300).contains(status) else {
            let e = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw Refused(status: status, message: e?.error ?? String(localized: "That didn't work. Try again.", comment: "Generic error"), code: e?.code)
        }
        return data
    }
    private func get<T: Decodable>(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(path, method: method, json: json))
    }
    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }

    // --- you -------------------------------------------------------------------

    /// Profile, counts, friends and this phone's sharing key. Called when the
    /// app comes forward and whenever the account changes.
    func refresh() async {
        guard let user = account.user, account.signedIn else {
            if let previous = deviceAccount { DeviceKey.remove(for: previous) }
            me = nil; friends = Friends(); inbox = []; blocked = []; deviceAccount = nil
            return
        }
        me = try? await get("me")
        friends = (try? await get("friends")) ?? friends
        await ensureDevice(for: user.id)
    }

    func agreeToTerms() async throws {
        try await send("terms", method: "POST", json: ["agree": true])
        me = try? await get("me")
    }

    func updateProfile(name: String?, handle: String?) async throws {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let handle { body["handle"] = handle }
        try await send("me", method: "PATCH", json: body)
        me = try? await get("me")
        revision += 1
    }

    // --- this phone's key ----------------------------------------------------

    private func ensureDevice(for user: String) async {
        deviceAccount = user
        if DeviceKey.load(for: user) != nil { return }
        let key = P256.KeyAgreement.PrivateKey()
        struct Registered: Decodable { let device_id: String }
        guard let r: Registered = try? await get("devices", method: "POST",
                                                  json: ["public_key": key.publicKey.x963Representation.base64EncodedString()]) else { return }
        DeviceKey.save(key, deviceID: r.device_id, for: user)
    }

    private func retireDevice() async {
        guard let user = account.user, let device = DeviceKey.load(for: user.id) else { return }
        try? await send("devices/\(device.id)", method: "DELETE")
        DeviceKey.remove(for: user.id)
    }

    // --- comments --------------------------------------------------------------

    func comments(for product: String) async throws -> Thread {
        try await get("products/\(Self.escape(product))/comments")
    }

    func post(_ body: String, on product: String, replyingTo parent: String?) async throws {
        var json: [String: Any] = ["body": body]
        if let parent { json["parent_id"] = parent }
        try await send("products/\(Self.escape(product))/comments", method: "POST", json: json)
    }

    struct LikeState: Decodable { let likes: Int; let liked: Bool }
    /// Likes or unlikes a comment; the server's count after it.
    func setLike(_ comment: Comment, _ on: Bool) async throws -> LikeState {
        try await get("comments/\(comment.id)/like", method: on ? "POST" : "DELETE", json: on ? [:] : nil)
    }

    func delete(_ comment: Comment) async throws {
        try await send("comments/\(comment.id)", method: "DELETE")
    }

    func report(_ comment: Comment, reason: String) async throws {
        try await send("comments/\(comment.id)/report", method: "POST", json: ["reason": reason])
        revision += 1
    }

    func blockAuthor(of comment: Comment) async throws {
        try await send("comments/\(comment.id)/block", method: "POST", json: [:])
        friends = (try? await get("friends")) ?? friends
        revision += 1
    }

    // --- people --------------------------------------------------------------

    func profile(_ handle: String) async throws -> ProfileReply {
        try await get("users/\(Self.escape(handle))")
    }

    func search(_ query: String) async throws -> [Person] {
        struct Found: Decodable { let people: [Person] }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return (try await get("search?q=\(q)") as Found).people
    }

    /// Send a request, or accept theirs if they already asked.
    @discardableResult
    func befriend(_ handle: String) async throws -> String {
        struct R: Decodable { let relationship: String }
        let r: R = try await get("users/\(Self.escape(handle))/friend", method: "POST", json: [:])
        await reloadFriends()
        return r.relationship
    }
    /// Cancel a request, decline one, or unfriend.
    func unfriend(_ handle: String) async throws {
        try await send("users/\(Self.escape(handle))/friend", method: "DELETE")
        await reloadFriends()
    }
    func block(_ handle: String) async throws {
        try await send("users/\(Self.escape(handle))/block", method: "POST", json: [:])
        await reloadFriends()
        revision += 1
    }
    func unblock(_ handle: String) async throws {
        try await send("users/\(Self.escape(handle))/block", method: "DELETE")
        await loadBlocked()
        revision += 1
    }
    func reportUser(_ handle: String, reason: String) async throws {
        try await send("users/\(Self.escape(handle))/report", method: "POST", json: ["reason": reason])
    }
    func reloadFriends() async {
        friends = (try? await get("friends")) ?? friends
        me = (try? await get("me")) ?? me
    }
    func loadBlocked() async {
        struct B: Decodable { let blocked: [Profile] }
        blocked = ((try? await get("blocks")) as B?)?.blocked ?? blocked
    }

    // --- encrypted sharing -----------------------------------------------------

    /// Seal the product for every device each friend has, and send it. Friends
    /// who have never opened Marracat have no key yet and are returned instead.
    func share(product: String, note: String, with handles: [String]) async throws -> (sent: [Profile], unreachable: [String]) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let why = ContentFilter.refusal(trimmed) { throw Refused(status: 422, message: why, code: nil) }
        struct Key: Decodable { let device_id: String; let public_key: String }
        struct Keys: Decodable { let keys: [String: [Key]] }
        let list = handles.map { Self.escape($0) }.joined(separator: ",")
        let keys: Keys = try await get("keys?handles=\(list)")
        let message = ShareCrypto.Message(product_id: product, note: trimmed)
        var messages: [[String: Any]] = [], unreachable: [String] = []
        for handle in handles {
            let devices = keys.keys[handle] ?? []
            guard !devices.isEmpty else { unreachable.append(handle); continue }
            let envelopes: [[String: Any]] = try devices.map { d in
                let e = try ShareCrypto.seal(message, to: d.public_key)
                return ["device_id": d.device_id, "ephemeral_key": e.ephemeral_key, "nonce": e.nonce, "ciphertext": e.ciphertext]
            }
            messages.append(["to": handle, "envelopes": envelopes])
        }
        guard !messages.isEmpty else { return ([], unreachable) }
        struct Sent: Decodable { let sent: [Profile] }
        let sent: Sent = try await get("shares", method: "POST", json: ["messages": messages])
        return (sent.sent, unreachable)
    }

    /// Everything friends have sent, opened with this phone's key. A share sent
    /// before this phone had a key can't be opened here, by design.
    func loadInbox() async {
        guard let user = account.user else { return }
        await ensureDevice(for: user.id)
        guard let device = DeviceKey.load(for: user.id) else { return }
        struct Shares: Decodable { let shares: [Share]; let device_known: Bool? }
        guard let found: Shares = try? await get("shares?device=\(device.id)") else { return }
        // The server forgot this phone's key: make a new one and ask again.
        // Shares sent from now on will open; earlier ones were for the old key.
        if found.device_known == false, !retriedDevice {
            retriedDevice = true
            DeviceKey.remove(for: user.id)
            await loadInbox()
            return
        }
        retriedDevice = false
        inbox = found.shares.map { s in
            Received(share: s, message: s.envelope.flatMap { try? ShareCrypto.open($0, with: device.key) })
        }
        if found.shares.contains(where: { !$0.seen }) {
            try? await send("shares/seen", method: "POST", json: [:])
            me = (try? await get("me")) ?? me
        }
    }

    /// The server can't read shares, so a report carries the one message this
    /// phone decrypted. The confirmation says so before it's sent.
    func report(_ received: Received) async throws {
        var body: [String: Any] = [:]
        if let m = received.message { body["message"] = ["product_id": m.product_id, "note": m.note] }
        try await send("shares/\(received.share.id)/report", method: "POST", json: body)
        inbox.removeAll { $0.id == received.id }
    }
}
