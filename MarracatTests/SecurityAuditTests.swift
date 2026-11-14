import CryptoKit
import Foundation
import Testing
@testable import Marracat

/// Audit 2026-10-07: the catalog signature (L5), the web checkout's
/// navigation policy (L3) and buyer details in the Keychain (L4).
struct CatalogSignatureTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    @Test func aSignedCatalogVerifies() throws {
        let data = Data(#"{"generated_at":"2026-10-07T00:00:00Z"}"#.utf8)
        let sig = Data((try key.signature(for: data).base64EncodedString() + "\n").utf8)
        #expect(CatalogSignature.isValid(data, signature: sig, publicKey: publicKey))
    }

    @Test(arguments: ["tampered", "", "not base64 !!", String(repeating: "A", count: 88)])
    func anythingElseFails(_ variant: String) throws {
        let data = Data("catalog".utf8)
        let good = try key.signature(for: data).base64EncodedString()
        let (body, sig): (Data, String) = variant == "tampered" ? (Data("catalog!".utf8), good) : (data, variant)
        #expect(!CatalogSignature.isValid(body, signature: Data(sig.utf8), publicKey: publicKey))
    }

    @Test func theBuiltInKeyIsAValidEd25519Key() throws {
        let raw = try #require(Data(base64Encoded: CatalogSignature.publicKey))
        #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil)
        #expect(CatalogSignature.signatureURL(for: CatalogStore.remoteURL).absoluteString == "https://marracat.com/catalog-v3.json.sig")
    }
}

/// A newer catalog with no signature (the .sig 404s) is not taken.
private final class UnsignedOrigin: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isSig = request.url!.path.hasSuffix(".sig")
        let response = HTTPURLResponse(url: request.url!, statusCode: isSig ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !isSig { client?.urlProtocol(self, didLoad: Data(#"{"generated_at":"9999-01-01T00:00:00Z","categories":[]}"#.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct UnsignedCatalogTests {
    @Test func aNewerUnsignedCatalogIsRefused() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnsignedOrigin.self]
        let fetched = await CatalogStore.downloadNewer(than: "2000-01-01T00:00:00Z", session: URLSession(configuration: config))
        #expect(fetched == nil)
    }

    /// The background refresh keeps the file without decoding it (2026-10-18):
    /// the signature is all that stands between it and the next launch.
    @Test func theBackgroundDownloadRefusesItToo() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnsignedOrigin.self]
        let kept = await CatalogStore.downloadForLater(than: "2000-01-01T00:00:00Z", session: URLSession(configuration: config))
        #expect(!kept)
    }
}

struct CheckoutNavigationPolicyTests {
    let policy = CheckoutNavigationPolicy(
        brand: Brand(id: "b", name: "B", domain: "www.shop.example", category: "grocery", tagline: nil, shopify: false, platform: "woocommerce", image: nil),
        start: [URL(string: "https://b.bigcartel.com/cart")!])

    @Test(arguments: [
        ("https://shop.example/checkout/", CheckoutNavigationPolicy.Decision.allow),
        ("https://pay.shop.example/x", .allow),
        ("https://www.paypal.com/checkoutnow?token=1", .allow),
        ("https://checkout.stripe.com/c/pay/x", .allow),
        ("https://js.klarna.com/x", .allow),
        ("https://portal.afterpay.com/x", .allow),
        ("https://b.bigcartel.com/cart", .allow),
        ("https://shop.example.evil.io/login", .openOutside),
        ("https://evil-paypal.com/login", .openOutside),
        ("https://instagram.com/shopexample", .openOutside),
        ("javascript:alert(1)", .block),
        ("data:text/html,<form>", .block),
        ("about:blank", .allow),
    ])
    func decides(_ url: String, _ expected: CheckoutNavigationPolicy.Decision) throws {
        #expect(policy.decision(for: try #require(URL(string: url))) == expected)
    }
}

struct BuyerKeychainTests {
    @Test func olderBuildsDetailsMoveOutOfUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "BuyerKeychainTests.\(UUID())"))
        let details = BuyerDetails(firstName: "A", lastName: "B", email: "a@b.co", phone: "7185550100",
                                   street: "1 Main St", city: "Brooklyn", region: "NY", postalCode: "11201")
        let data = try JSONEncoder().encode(details)
        defaults.set(data, forKey: "buyer.details.v1") // gitleaks:allow (a UserDefaults key name)
        defaults.set(data, forKey: "buyer.account.google:1")
        let vault = MemoryBuyerVault()
        let store = BuyerStore(defaults: defaults, vault: vault)
        #expect(store.details == details)
        #expect(defaults.data(forKey: "buyer.details.v1") == nil) // gitleaks:allow
        #expect(defaults.data(forKey: "buyer.account.google:1") == nil)
        store.activate("google:1")
        #expect(store.details == details, "every account's details moved")
    }

    @Test func theKeychainVaultRoundTrips() {
        let vault = KeychainBuyerVault(service: "com.divinedavis.marracat.buyer.tests.\(UUID())")
        defer { vault.removeAll() }
        vault.write("k", Data("x".utf8))
        #expect(vault.read("k") == Data("x".utf8))
        vault.write("k", nil)
        #expect(vault.read("k") == nil)
    }
}
