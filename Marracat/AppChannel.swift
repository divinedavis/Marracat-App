import Foundation

/// Which kind of install is running. It rides in the user agent on requests to
/// marracat.com so the owner dashboard counts App Store shoppers and nobody
/// else: before this, the owner's own TestFlight phone showed up as five
/// "devices" because a phone on cellular changes address all day and the
/// dashboard can only tell devices apart by address.
///
/// No identifier is involved, only the kind of build, so it changes nothing in
/// the App Privacy answers.
enum AppChannel {
    static let current: String = {
        #if DEBUG
        return "debug"
        #elseif targetEnvironment(simulator)
        return "debug"
        #else
        // TestFlight and App Review installs carry a sandbox receipt; only an
        // App Store download carries a production one.
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "testflight" : "appstore"
        #endif
    }()

    /// False while XCTest is loaded or the app runs under a UI-test launch
    /// (-UITEST_RESET): tests must never reach marracat.com's order endpoints
    /// (2026-10-13: the unit-test host app on simulator install c8ebe62c
    /// registered made-up orders with /api/orders/tracked). The same rule as
    /// Analytics.sendsToServer; the stores' stubs stand in for the server.
    nonisolated static var reachesOrderServer: Bool { Analytics.sendsToServer }

    /// "Marracat/46 channel/testflight iOS/26.3". The dashboard reads the build
    /// from the leading "Marracat/<build>", so that part must not move.
    static let userAgent: String = {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Marracat/\(build) channel/\(current) iOS/\(os.majorVersion).\(os.minorVersion)"
    }()
}
