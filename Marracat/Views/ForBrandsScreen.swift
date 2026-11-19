import SwiftUI

/// You › For brands (owner, 2026-10-06): a brand's team confirms they manage
/// it with a one-time link to an address at the brand's own domain
/// (web/server/brand-claims.js), then sees its sponsored-product stats and
/// pauses or resumes them (web/server/sponsored.js). Budgets and the card
/// live on marracat.com: Apple's 3.1.3(g) lets only ad-management apps take
/// ad payments outside in-app purchase.
struct ForBrandsScreen: View {
    @Environment(AccountStore.self) private var account
    @Environment(CatalogStore.self) private var catalog
    @State private var managed: [Managed] = []
    @State private var query = ""
    @State private var brandID: String?
    @State private var email = ""
    @State private var busy = false
    @State private var message: String?
    @State private var browser: IdentifiedURL?

    struct Managed: Decodable, Identifiable {
        struct BrandRef: Decodable { let id: String; let name: String }
        struct Campaign: Decodable { let productIDs: [String]; let dailyBudget: Double; let maxCPC: Double; let status: String }
        struct Stats: Decodable { let views: Int; let taps: Int; let spentCents: Int; let todayCents: Int }
        let brand: BrandRef
        let campaign: Campaign?
        let card: String?
        let stats: Stats
        var id: String { brand.id }
    }
    private struct Reply: Decodable { let brands: [Managed] }
    private var stubbed: Bool { ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") }

    var body: some View {
        List {
            if !managed.isEmpty {
                Section("Brands you manage") {
                    ForEach(managed) { m in brandCard(m) }
                }
            }
            Section {
                TextField("Your brand", text: $query)
                    .autocorrectionDisabled()
                    .onChange(of: query) { if brandID.flatMap(catalog.brand)?.name != query { brandID = nil } }
                    .accessibilityIdentifier("claimBrandField")
                if brandID == nil {
                    ForEach(matches) { b in
                        Button { brandID = b.id; query = b.name } label: {
                            VStack(alignment: .leading) { Text(b.name); Text(b.domain).font(.caption).foregroundStyle(.secondary) }
                        }
                        .accessibilityIdentifier("claimBrandOption")
                    }
                }
                if let b = brandID.flatMap(catalog.brand) {
                    TextField("you@\(Self.host(b.domain))", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("claimEmailField")
                    Button { Task { await sendLink(b) } } label: {
                        HStack { if busy { ProgressView() }; Text("Email me a link").bold() }
                    }
                    .disabled(busy || !email.lowercased().hasSuffix("@" + Self.host(b.domain)))
                    .accessibilityIdentifier("claimSendLink")
                }
            } header: {
                Text("Confirm you manage a brand")
            } footer: {
                Text("We email a one-time link to an address at your brand's own domain. Opening it confirms you're on the team; then you can promote your products on Marracat.")
            }
            if let message { Section { Text(message).font(.subheadline) } }
        }
        .navigationTitle("For brands")
        .marracatChrome()
        .markRefreshable { await load() }
        .task { await load() }
        .sheet(item: $browser) { SafariView(url: $0.url).ignoresSafeArea() }
        .overlay {
            if !account.signedIn && !stubbed {
                ContentUnavailableView {
                    Label("Sign in first", systemImage: "storefront")
                } description: { Text("Brands are managed from a Marracat account.") } actions: {
                    NavigationLink("Sign in", value: Route.accountSettings).buttonStyle(PillButtonStyle(color: Theme.gold, text: .black))
                }
            }
        }
    }

    private var matches: [Brand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return Array(catalog.brands.filter { $0.name.lowercased().contains(q) }.prefix(6))
    }
    static func host(_ domain: String) -> String {
        domain.lowercased().replacingOccurrences(of: "www.", with: "").components(separatedBy: "/").first ?? domain
    }

    @ViewBuilder
    private func brandCard(_ m: Managed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.brand.name).font(.headline)
            HStack(spacing: 18) {
                stat("\(m.stats.views)", "views")
                stat("\(m.stats.taps)", "taps")
                stat((Double(m.stats.spentCents) / 100).formatted(.currency(code: "USD")), "spent")
            }
            Text("Last 7 days").font(.caption2).foregroundStyle(.secondary)
            if let c = m.campaign {
                Button {
                    Task { await setStatus(m.brand.id, c.status == "active" ? "paused" : "active") }
                } label: {
                    Label(c.status == "active" ? "Pause ads" : "Resume ads", systemImage: c.status == "active" ? "pause.fill" : "play.fill")
                }
                .accessibilityIdentifier("adsToggle")
            }
            Button {
                browser = IdentifiedURL(url: URL(string: "https://marracat.com/#/brand-ads?brand=\(m.brand.id)")!)
            } label: { Label(m.campaign == nil ? "Set up ads on marracat.com" : "Budget and card on marracat.com", systemImage: "safari") }
                .accessibilityIdentifier("adsManageWeb")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("managedBrand")
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title3.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }
    }

    // MARK: Network

    private func load() async {
        guard account.signedIn, let (status, data) = try? await call("ads/brands"), status == 200,
              let r = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        managed = r.brands
    }
    private func sendLink(_ b: Brand) async {
        busy = true; defer { busy = false }
        let body = try? JSONSerialization.data(withJSONObject: ["brand": b.id, "email": email.trimmingCharacters(in: .whitespaces)])
        guard let (status, data) = try? await call("brand-claims/email", method: "POST", body: body) else {
            message = String(localized: "That didn't send. Try again.", comment: "Error"); return
        }
        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        message = status == 201 ? String(localized: "We emailed a link to \(email). Open it within 30 minutes, then pull down here to refresh.", comment: "Sign-in link sent; the argument is an email address") : (err ?? String(localized: "That didn't send. Try again.", comment: "Error"))
    }
    private func setStatus(_ brand: String, _ status: String) async {
        let body = try? JSONSerialization.data(withJSONObject: ["brand": brand, "status": status])
        _ = try? await call("ads/campaign/status", method: "POST", body: body)
        await load()
    }
    private func call(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: "https://marracat.com/api/" + path)!)
        r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        account.authorize(&r)
        let (data, response) = try await URLSession.shared.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
