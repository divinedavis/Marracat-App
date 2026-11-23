import SwiftUI

/// You › Your taste (owner, 2026-11-08: "5: lets do it"): what the app has
/// learned on this iPhone, in plain words, with a way to correct each part.
/// Research on recommendation profiles (Ramos et al., ACL 2024) found people
/// trust and fix a profile they can read; nothing here leaves the phone.
struct YourTasteScreen: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @State private var styles: [(style: ShopStyle, affinity: Float)] = []
    @State private var interests: [(label: String, interest: TasteInterest, products: [Product])] = []
    @State private var sizes = SizeMemory.load()
    @State private var comfort = PriceComfort(bands: [:])
    @State private var lean: String?
    @State private var confirmStartOver = false

    private var taste: TasteProfile { TasteProfile.shared }

    var body: some View {
        List {
            if !shopper.personalizationEnabled {
                Section {
                    Text("Personalized recommendations are off, so nothing is being learned. Turn them on in Account settings.")
                    NavigationLink("Account settings", value: Route.accountSettings)
                }
            } else if !taste.hasHistory && sizes == SizeMemory() && taste.notMeStyles.isEmpty {
                Section {
                    Text("Look around, save and shop, and what you like shows up here. It's learned on this iPhone and never leaves it.")
                        .accessibilityIdentifier("tasteEmpty")
                }
            } else {
                stylesSection
                interestsSection
                sizesSection
                priceSection
                leanSection
                Section {
                    NavigationLink(value: Route.interests) {
                        Label("Describe what you're into", systemImage: "sparkles")
                    }
                    Button(role: .destructive) { confirmStartOver = true } label: { Text("Start over") }
                        .accessibilityIdentifier("startOverTaste")
                } footer: {
                    Text("Learned from what you look at, save and buy, on this iPhone only. Start over clears all of it.").foregroundStyle(Theme.secondary)
                }
            }
        }
        .confirmationDialog("Start over?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Clear what's been learned", role: .destructive) {
                taste.clear()
                Task { await reload() }
            }
        } message: {
            Text("Your styles, interests, sizes and price ranges will be forgotten. Saved items and orders stay.")
        }
        .task(id: taste.revision) { await reload() }
        .barTitle("Your taste")
        .marracatChrome()
    }

    // MARK: Sections

    @ViewBuilder private var stylesSection: some View {
        let notMe = Set(taste.notMeStyles)
        let yours = styles.filter { !notMe.contains($0.style.id) }.prefix(3)
        if !yours.isEmpty || !notMe.isEmpty {
            Section {
                ForEach(Array(yours), id: \.style.id) { s in
                    HStack {
                        NavigationLink(value: Route.style(s.style.id)) { Text(s.style.name) }
                        Button("Not me") { taste.setNotMe(s.style.id, true) }
                            .buttonStyle(.borderless).brandFont(.subheadline)
                            .accessibilityIdentifier("notMeStyle")
                    }
                    .accessibilityIdentifier("tasteStyle")
                }
                ForEach(taste.notMeStyles, id: \.self) { id in
                    if let style = ShopStyle.all.first(where: { $0.id == id }) {
                        HStack {
                            Text(style.name).foregroundStyle(Theme.secondary).strikethrough()
                            Spacer()
                            Button("Bring back") { taste.setNotMe(id, false) }
                                .buttonStyle(.borderless).brandFont(.subheadline)
                                .accessibilityIdentifier("bringBackStyle")
                        }
                    }
                }
            } header: {
                Text("Your styles").foregroundStyle(Theme.secondary)
            } footer: {
                Text("Not me keeps a style out of your picks and moves it to the end of Shop by style.").foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var interestsSection: some View {
        if !interests.isEmpty {
            Section {
                ForEach(interests.indices, id: \.self) { i in
                    let item = interests[i]
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.label).brandFont(.headline)
                            Spacer()
                            Text("\(Int((item.interest.share * 100).rounded()))%").foregroundStyle(Theme.secondary).brandFont(.subheadline)
                        }
                        HStack(spacing: 8) {
                            ForEach(item.products.prefix(4)) { p in
                                ProductImageWell(url: p.images.first, width: 200, padding: 2).frame(width: 64)
                            }
                        }
                        Button("Less of this") { taste.mute(item.interest.products) }
                            .buttonStyle(.borderless).brandFont(.subheadline)
                            .accessibilityIdentifier("muteInterest")
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tasteInterest")
                }
            } header: {
                Text("What you're into").foregroundStyle(Theme.secondary)
            } footer: {
                Text("Picked for you takes turns between these, so one doesn't crowd out the other.").foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var sizesSection: some View {
        let departments = sizes.byDepartment.keys.sorted()
        if !departments.isEmpty {
            Section {
                ForEach(departments, id: \.self) { d in
                    HStack {
                        Text(catalog.categoriesByID[d]?.name ?? d.capitalized)
                        Spacer()
                        Text(sizes.byDepartment[d] ?? "").bold()
                        Button("Forget") {
                            sizes.forget(department: d)
                            sizes.save()
                        }
                        .buttonStyle(.borderless).brandFont(.subheadline)
                        .accessibilityIdentifier("forgetSize")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tasteSize")
                }
            } header: {
                Text("Your sizes").foregroundStyle(Theme.secondary)
            } footer: {
                Text("Product pages start on your size when it's in stock. A brand you've bought a different size from keeps its own.").foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var priceSection: some View {
        let bands = comfort.bands.sorted { $0.key < $1.key }
        if !bands.isEmpty {
            Section {
                ForEach(bands, id: \.key) { d, band in
                    HStack {
                        Text(catalog.categoriesByID[d]?.name ?? d.capitalized)
                        Spacer()
                        Text("\(Money.string(band.lowerBound, currency: "USD"))–\(Money.string(band.upperBound, currency: "USD"))")
                            .foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tastePrice")
                }
            } header: {
                Text("Your price range").foregroundStyle(Theme.secondary)
            } footer: {
                Text("From what you look at and buy in each department. Picks above it come after the ones inside it.").foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var leanSection: some View {
        if let lean {
            Section {
                HStack {
                    Text(lean == "women" ? "Clothing and shoes: Women" : "Clothing and shoes: Men")
                    Spacer()
                    Button("Forget") { GenderLean.clear(); self.lean = nil }
                        .buttonStyle(.borderless).brandFont(.subheadline)
                        .accessibilityIdentifier("forgetLean")
                }
            } footer: {
                Text("From the Women or Men filter you keep choosing. Picks leave out the other side's clothing and shoes.").foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: Loading

    private func reload() async {
        sizes = SizeMemory.load()
        lean = GenderLean.side()
        comfort = MeaningPicks.priceComfort(catalog: catalog)
        guard taste.hasHistory, await MeaningIndex.shared.prepare() else {
            styles = []; interests = []; return
        }
        // Styles whose boards reach the shopper's own departments (owner,
        // 2026-11-09): a style they'd only see things they never looked for
        // in isn't theirs.
        let allowed = catalog.touchedDepartments(of: shopper)
        var theirs: [(style: ShopStyle, affinity: Float)] = []
        for s in await ShopStyle.affinities() {
            let board = await s.style.products(catalog: catalog)
            if allowed.isEmpty || board.filter({ allowed.contains($0.category) }).count >= 6 { theirs.append(s) }
        }
        styles = theirs
        var out: [(String, TasteInterest, [Product])] = []
        for interest in taste.interests() {
            let products = interest.products.compactMap(catalog.product)
            out.append((await label(interest, products), interest, products))
        }
        interests = out
    }

    /// "Skincare · Natural Glow": the department most of it sits in and the
    /// style it's closest to.
    private func label(_ interest: TasteInterest, _ products: [Product]) async -> String {
        let department = Dictionary(grouping: products, by: \.category).max { $0.value.count < $1.value.count }?.key
        let name = department.flatMap { catalog.categoriesByID[$0]?.name }
        var best: (String, Float)?
        for s in ShopStyle.all {
            if let v = await s.vector() {
                let a = TasteMath.dot(interest.vector, v)
                if best == nil || a > best!.1 { best = (s.name, a) }
            }
        }
        return [name, best?.0].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Home's "Something new to try" (owner, 2026-11-08: "7: lets do it"): one
/// row a day from a style next to the shopper's own (MeaningPicks.exploration).
/// Built once per visit to Home and only below the fold, so it never moves
/// what the shopper is looking at.
struct ExploreRow: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @State private var row: (style: ShopStyle, products: [Product])?

    var body: some View {
        Group {
            if let row {
                ProductRow(title: String(localized: "Something new to try: \(row.style.name)", comment: "Home row title: a style next to the shopper's own; the argument is a style name"),
                           products: row.products, route: .style(row.style.id), track: "explore")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("exploreRow")
            } else {
                Color.clear.frame(height: 0)   // so .task below starts (as ShopByStyleRow)
            }
        }
        // Again once the shopper has a history: a first launch has none, and
        // the row fills in while Home is behind what they're browsing.
        // (`revision` is the observed part of the taste; the row is built once.)
        .task(id: "\(catalog.isComplete)-\(TasteProfile.shared.revision / 4)") {
            guard catalog.isComplete, row == nil, shopper.personalizationEnabled else { return }
            row = await MeaningPicks.exploration(catalog: catalog, hidden: Set(shopper.hidden), allowed: catalog.touchedDepartments(of: shopper))
        }
    }
}
