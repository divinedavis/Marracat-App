import CryptoKit
import Foundation
import Security

/// End-to-end encryption for products shared between friends.
///
/// Byte for byte the same scheme as the website's src/e2ee.js, so a share
/// sealed on either opens on the other; ShareCryptoTests and the website's
/// e2ee test both check one fixed test vector.
///
///   ECDH (P-256) between a fresh ephemeral key and the recipient device's key
///   HKDF-SHA256, salt = ephemeral public key || recipient public key (65 bytes each),
///                info = "marracat-share-v1"
///   AES-256-GCM, 12-byte nonce, the 16-byte tag appended to the ciphertext
///   plaintext = JSON with sorted keys: {"note":"…","product_id":"…"}
enum ShareCrypto {
    struct Envelope: Codable, Equatable {
        let ephemeral_key: String
        let nonce: String
        let ciphertext: String
    }
    struct Message: Codable, Equatable {
        let product_id: String
        let note: String
    }
    enum Failure: Error { case badKey, badEnvelope }

    private static let info = Data("marracat-share-v1".utf8)

    /// The exact bytes sealed. Sorted keys and unescaped slashes, to match
    /// JavaScript's JSON.stringify of the same object.
    static func plaintext(_ m: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(m)
    }

    private static func key(_ secret: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient, sharedInfo: info, outputByteCount: 32)
    }

    /// Seal `message` for one device. `ephemeral` and `nonce` are only passed by
    /// tests, to reproduce the shared vector.
    static func seal(_ message: Message, to recipientPublic: String,
                     ephemeral: P256.KeyAgreement.PrivateKey = .init(),
                     nonce: AES.GCM.Nonce = .init()) throws -> Envelope {
        guard let raw = Data(base64Encoded: recipientPublic), raw.count == 65, raw.first == 4,
              let recipient = try? P256.KeyAgreement.PublicKey(x963Representation: raw) else { throw Failure.badKey }
        let ephemeralRaw = ephemeral.publicKey.x963Representation
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let box = try AES.GCM.seal(try plaintext(message), using: key(secret, ephemeral: ephemeralRaw, recipient: raw), nonce: nonce)
        return Envelope(ephemeral_key: ephemeralRaw.base64EncodedString(),
                        nonce: Data(box.nonce).base64EncodedString(),
                        ciphertext: (box.ciphertext + box.tag).base64EncodedString())
    }

    /// Open an envelope sealed for this device. Throws if it was tampered with.
    static func open(_ envelope: Envelope, with device: P256.KeyAgreement.PrivateKey) throws -> Message {
        guard let ephemeralRaw = Data(base64Encoded: envelope.ephemeral_key),
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralRaw),
              let nonceData = Data(base64Encoded: envelope.nonce), let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = Data(base64Encoded: envelope.ciphertext), sealed.count > 16 else { throw Failure.badEnvelope }
        let secret = try device.sharedSecretFromKeyAgreement(with: ephemeral)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try AES.GCM.open(box, using: key(secret, ephemeral: ephemeralRaw, recipient: device.publicKey.x963Representation))
        return try JSONDecoder().decode(Message.self, from: plain)
    }
}

/// This phone's own key pair for shares, one per signed-in account. The private
/// key stays in the Keychain, readable only on this device after first unlock,
/// never backed up or synced.
enum DeviceKey {
    struct Stored: Codable { let deviceID: String; let privateKey: Data }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.divinedavis.marracat.share-key",
         kSecAttrAccount as String: account]
    }
    static func load(for account: String) -> (id: String, key: P256.KeyAgreement.PrivateKey)? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored.privateKey) else { return nil }
        return (stored.deviceID, key)
    }
    static func save(_ key: P256.KeyAgreement.PrivateKey, deviceID: String, for account: String) {
        remove(for: account)
        var q = query(account)
        q[kSecValueData as String] = try? JSONEncoder().encode(Stored(deviceID: deviceID, privateKey: key.rawRepresentation))
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func remove(for account: String) { SecItemDelete(query(account) as CFDictionary) }
}
