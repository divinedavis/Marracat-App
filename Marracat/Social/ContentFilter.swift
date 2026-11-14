import Foundation

/// The same screen as the website's server/content-filter.js. Comments are
/// checked by the server, but a note on a shared product is end-to-end
/// encrypted and the server can't read it, so it's checked here, on the
/// sender's phone, before it's sealed. Keep the two lists in step.
enum ContentFilter {
    private static let terms = [
        "nigger", "niggers", "nigga", "niggas", "negroid", "coon", "coons", "jigaboo", "porchmonkey",
        "sambo", "pickaninny", "chink", "chinks", "gook", "gooks", "spic", "spics", "wetback",
        "wetbacks", "beaner", "beaners", "kike", "kikes", "raghead", "towelhead", "sandnigger",
        "paki", "pakis", "redskin", "redskins", "squaw", "zipperhead",
        "faggot", "faggots", "fag", "fags", "dyke", "dykes", "tranny", "trannies", "shemale",
        "retard", "retards", "retarded",
        "rape", "raping", "rapist", "whore", "whores", "slut", "sluts", "cunt", "cunts",
        "kys", "killyourself",
    ]
    private static let leet: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"]
    private static let words = try! NSRegularExpression(pattern: "\\b(?:" + terms.joined(separator: "|") + ")\\b")
    private static let phrases = try! NSRegularExpression(pattern: "\\bkill\\s*your\\s*self\\b|\\bgo\\s+die\\b")
    private static let spaced = try! NSRegularExpression(pattern: "\\b(\\w)(?:[\\s._*-]+(?=\\w\\b))")
    private static let link = try! NSRegularExpression(
        pattern: "(?:https?://|www\\.)\\S|\\b[a-z0-9-]+\\.(?:com|net|org|io|co|shop|store|xyz|link|ly|me|app)\\b",
        options: .caseInsensitive)

    private static func normalise(_ text: String) -> String {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: .init(identifier: "en_US"))
        let swapped = String(folded.map { leet[$0] ?? $0 })
        let range = NSRange(swapped.startIndex..., in: swapped)
        return spaced.stringByReplacingMatches(in: swapped, range: range, withTemplate: "$1")
    }
    private static func hit(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Why `text` can't be sent, or nil if it can.
    static func refusal(_ text: String) -> String? {
        let plain = normalise(text)
        if hit(words, plain) || hit(phrases, plain) { return String(localized: "That includes language Marracat doesn't allow. Please keep it respectful.", comment: "Why a comment can't be posted") }
        if hit(link, text) { return String(localized: "Links can't be posted. Share a product with the share button instead.", comment: "Why a comment can't be posted") }
        return nil
    }
}
