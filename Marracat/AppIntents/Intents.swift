import AppIntents
import Foundation

// Siri, Shortcuts, Spotlight and the Action button: each intent opens a screen
// of the app (AppDestination) and nothing else — no purchase, no account
// change, nothing sent anywhere. The app comes to the foreground for each.

struct SearchMarracatIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Marracat"
    static let description = IntentDescription("Searches Marracat's catalog and shows the results.")
    static let openAppWhenRun = true

    @Parameter(title: "Search for", requestValueDialog: "What would you like to find on Marracat?")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Search Marracat for \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let destination = AppDestination.searchFor(query) { IntentRouter.shared.open(destination) }
        return .result()
    }
}

/// The search schema Apple Intelligence and Spotlight's "Search in app" use.
@available(iOS 18.0, *)
@AppIntent(schema: .system.search)
struct ShowMarracatSearchResultsIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        if let destination = AppDestination.searchFor(criteria.term) { IntentRouter.shared.open(destination) }
        return .result()
    }
}

struct OpenProductIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Product"
    static let description = IntentDescription("Opens a product on Marracat.")

    @Parameter(title: "Product", requestValueDialog: "Which product?")
    var target: ProductEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(.product(target.id))
        return .result()
    }
}

struct OpenBrandIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Brand"
    static let description = IntentDescription("Opens a brand's shop on Marracat.")

    @Parameter(title: "Brand", requestValueDialog: "Which brand?")
    var target: BrandEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(.brand(target.id))
        return .result()
    }
}

struct OpenCategoryIntent: OpenIntent {
    static let title: LocalizedStringResource = "Shop Department"
    static let description = IntentDescription("Opens a department on Marracat, like Skincare or Menswear.")

    @Parameter(title: "Department", requestValueDialog: "Which department?")
    var target: CategoryEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(.category(target.id))
        return .result()
    }
}

struct ShowDealsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Deals"
    static let description = IntentDescription("Shows what's on sale on Marracat.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(.deals)
        return .result()
    }
}

struct TrackOrderIntent: AppIntent {
    static let title: LocalizedStringResource = "Track My Order"
    static let description = IntentDescription("Opens Your Orders, with tracking for each order.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(.orders)
        return .result()
    }
}

/// Phrases Siri knows as soon as the app is installed. Every phrase names the
/// app; a phrase can only carry an entity or enum parameter (not free text),
/// so "Search Marracat" asks what to search for.
struct MarracatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchMarracatIntent(), phrases: [
            "Search \(.applicationName)",
            "Search \(.applicationName) for something",
            "Find something on \(.applicationName)",
            "Shop on \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenBrandIntent(), phrases: [
            "Show \(\.$target) on \(.applicationName)",
            "Open \(\.$target) on \(.applicationName)",
            "Shop \(\.$target) on \(.applicationName)",
            "Show a brand on \(.applicationName)",
        ], shortTitle: "Show Brand", systemImageName: "storefront")
        AppShortcut(intent: ShowDealsIntent(), phrases: [
            "What's on sale on \(.applicationName)",
            "What's on sale at \(.applicationName)",
            "Show deals on \(.applicationName)",
            "\(.applicationName) deals",
        ], shortTitle: "Deals", systemImageName: "tag")
        AppShortcut(intent: TrackOrderIntent(), phrases: [
            "Track my order on \(.applicationName)",
            "Track my \(.applicationName) order",
            "Where's my \(.applicationName) order",
            "Show my \(.applicationName) orders",
        ], shortTitle: "Track Order", systemImageName: "shippingbox")
        AppShortcut(intent: OpenCategoryIntent(), phrases: [
            "Browse \(\.$target) on \(.applicationName)",
            "Show the \(\.$target) department on \(.applicationName)",
            "Browse \(.applicationName)",
        ], shortTitle: "Departments", systemImageName: "square.grid.2x2")
    }
}

extension AppDestination {
    /// A search for what was said or typed, or nil when it's blank.
    static func searchFor(_ text: String) -> AppDestination? {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : .search(String(q.prefix(maxQuery)))
    }
}
