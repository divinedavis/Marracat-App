import Foundation

/// Ask for an App Store rating once, right after the shopper's first purchase
/// in the app (owner, 2026-10-06): a finished order is the happiest moment we
/// can see. Apple decides whether the prompt actually shows (at most three
/// times a year, never in TestFlight), so this only decides when to ask.
enum ReviewPrompt {
    static let askedKey = "reviewPrompt.askedAfterPurchase"

    /// Whether a just-completed order should bring up the prompt: only if this
    /// phone has never been asked. UI tests (-UITEST_RESET) never see it, since
    /// the system dialog would sit over whatever the test taps next.
    static func shouldAsk(defaults: UserDefaults = .standard,
                          arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        !arguments.contains("-UITEST_RESET") && !defaults.bool(forKey: askedKey)
    }

    static func markAsked(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: askedKey)
    }
}
