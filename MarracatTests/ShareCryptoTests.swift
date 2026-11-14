import CryptoKit
import XCTest
@testable import Marracat

/// The same fixed vector as the website's tests/fixtures/share-vector.json.
/// If either side changes, a share sealed on one stops opening on the other,
/// and one of the two tests fails.
final class ShareCryptoTests: XCTestCase {
    private let recipientPrivate = "1111111111111111111111111111111111111111111111111111111111111111"
    private let ephemeralPrivate = "2222222222222222222222222222222222222222222222222222222222222222"
    private let recipientPublic = "BAIX5hfwtkQ5KCePlpmeaaI6TywVK99tbN9m5bgCgtTtGUp968uXcS0t2jyoWqh2Wlb0X8dYWZZS8ol8ZTBuV5Q="
    private let expected = ShareCrypto.Envelope(
        ephemeral_key: "BNZak5d8qj0bCBhS/1ennkZfFmBXcwS66tUF3TpIWJzzUBheiVNy32Ih6joTdVfkc/3bZ1XwW9UHw8Uz/OnJEoU=",
        nonce: "AAECAwQFBgcICQoL",
        ciphertext: "OhOl5fTUuyOall5bARfLvOtYhMzOHUXObgN0GsRHauSEExKZEWDmY+TS/FGaTwxWzRxC6aGj4eqJo1XdqhEwg8fyemAdkiTBkUQ4m9wCQESD7RwXjlbd")
    private let message = ShareCrypto.Message(product_id: "koba-skincare-123", note: "Thought you would love this")

    private func key(_ hex: String) throws -> P256.KeyAgreement.PrivateKey {
        var bytes = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes)
    }

    func testPlaintextMatchesJavaScript() throws {
        XCTAssertEqual(String(decoding: try ShareCrypto.plaintext(message), as: UTF8.self),
                       #"{"note":"Thought you would love this","product_id":"koba-skincare-123"}"#)
    }

    func testSealReproducesTheWebsiteVector() throws {
        XCTAssertEqual(try key(recipientPrivate).publicKey.x963Representation.base64EncodedString(), recipientPublic)
        let nonce = try AES.GCM.Nonce(data: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))
        let sealed = try ShareCrypto.seal(message, to: recipientPublic, ephemeral: key(ephemeralPrivate), nonce: nonce)
        XCTAssertEqual(sealed, expected)
    }

    func testOpensWhatTheWebsiteSealed() throws {
        XCTAssertEqual(try ShareCrypto.open(expected, with: key(recipientPrivate)), message)
    }

    func testTamperingIsCaught() throws {
        var bytes = Data(base64Encoded: expected.ciphertext)!; bytes[3] ^= 1
        let tampered = ShareCrypto.Envelope(ephemeral_key: expected.ephemeral_key, nonce: expected.nonce, ciphertext: bytes.base64EncodedString())
        XCTAssertThrowsError(try ShareCrypto.open(tampered, with: key(recipientPrivate)))
    }

    func testRoundTripWithFreshKeys() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let sealed = try ShareCrypto.seal(message, to: device.publicKey.x963Representation.base64EncodedString())
        XCTAssertEqual(try ShareCrypto.open(sealed, with: device), message)
        XCTAssertThrowsError(try ShareCrypto.open(sealed, with: P256.KeyAgreement.PrivateKey()), "another device must not open it")
    }
}
