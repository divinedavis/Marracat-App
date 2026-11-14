import Foundation
import Observation
import Security

/// The shopper's name, email, phone and shipping address, saved on this
/// phone so a checkout across several brands asks for them once. Kept per
/// account like the cart; erased with the account cache on a full sign-out.
///
/// Stored in the Keychain (AfterFirstUnlockThisDeviceOnly), not
/// UserDefaults (audit 2026-10-07: a plist in the app container ends up in
/// backups and is readable on a jailbroken phone). Details saved by older
/// builds are moved over on first launch and deleted from UserDefaults.
@Observable
final class BuyerStore {
    private static let key = "buyer.details.v1"
    private var activeKey = BuyerStore.key
    private let vault: BuyerVault

    private(set) var details: BuyerDetails? {
        didSet {
            if let details, let data = try? JSONEncoder().encode(details) { vault.write(activeKey, data) }
            else { vault.write(activeKey, nil) }
        }
    }

    init(defaults: UserDefaults = .standard, vault: BuyerVault = KeychainBuyerVault()) {
        self.vault = vault
        Self.migrate(from: defaults, to: vault)
        details = Self.load(vault, Self.key)
    }

    func save(_ d: BuyerDetails) { details = d }
    func clear() { details = nil }

    func activate(_ accountID: String?) {
        activeKey = accountID.map { "buyer.account." + $0 } ?? Self.key
        details = Self.load(vault, activeKey)
    }
    func eraseAccountCache() { vault.write(activeKey, nil); activate(nil) }

    private static func load(_ vault: BuyerVault, _ key: String) -> BuyerDetails? {
        vault.read(key).flatMap { try? JSONDecoder().decode(BuyerDetails.self, from: $0) }
    }

    /// Every buyer record an older build left in UserDefaults goes to the
    /// vault (unless the vault already has a newer one) and leaves defaults.
    static func migrate(from defaults: UserDefaults, to vault: BuyerVault) {
        for key in defaults.dictionaryRepresentation().keys where key == Self.key || key.hasPrefix("buyer.account.") {
            if let data = defaults.data(forKey: key), vault.read(key) == nil { vault.write(key, data) }
            defaults.removeObject(forKey: key)
        }
    }
}

/// Where buyer details live: the Keychain in the app, memory in tests.
protocol BuyerVault: AnyObject {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ data: Data?)
}

final class KeychainBuyerVault: BuyerVault {
    let service: String
    init(service: String = "com.divinedavis.marracat.buyer") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    func read(_ key: String) -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    func write(_ key: String, _ data: Data?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let data else { return }
        var q = query(key); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    /// UI tests start clean (-UITEST_RESET), Keychain included.
    func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

final class MemoryBuyerVault: BuyerVault {
    private var items: [String: Data] = [:]
    func read(_ key: String) -> Data? { items[key] }
    func write(_ key: String, _ data: Data?) { items[key] = data }
}
