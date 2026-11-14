import CryptoKit
import Foundation

/// The published catalog's Ed25519 signature (audit 2026-10-07). The catalog
/// carries every brand's store and checkout endpoint, so a downloaded
/// catalog-v3.json is only cached when catalog-v3.json.sig checks out
/// against this key; otherwise the app keeps the catalog it has (the cached
/// one or the bundle). scripts/sign_catalog.py signs at publish with the
/// private half, kept on the publishing Mac and never in the repo.
enum CatalogSignature {
    static let publicKey = "i4nSqpfQx581y1lOIFUZ3y+mAMKFW0h0wudahAm3fas="

    static func signatureURL(for url: URL) -> URL { URL(string: url.absoluteString + ".sig")! }

    /// `signature`: the .sig file's contents, base64 with any whitespace.
    static func isValid(_ data: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        guard let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let sig = Data(base64Encoded: text), sig.count == 64,
              let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Fetches the signature for `url` and checks `data` against it.
    static func verify(_ data: Data, from url: URL, session: URLSession) async -> Bool {
        var request = URLRequest(url: signatureURL(for: url))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (sig, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return isValid(data, signature: sig)
    }
}
