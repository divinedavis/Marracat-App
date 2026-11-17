import SwiftUI

/// A shopping alert's picture-rich content (owner, 2026-11-15: picked from the
/// "Marracat Alerts Preview v2" mockups and the alert videos). The server puts
/// it in the push as `card` (web/server/alert-cards.js); on-device alerts
/// (interest matches, weekly picks, brand suggestions) put it in the local
/// notification's userInfo the same way.
///
/// Where it shows (Apple's limits): inside the app as our own banner
/// (InAppAlertBanner), and when a notification is pressed and held
/// (MarracatNotificationContent). The Lock Screen banner itself stays Apple's,
/// with the product photo on the right (MarracatNotificationService).
///
/// Field names are short: a push has 4 KB for everything.
struct AlertCard: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case drop, sale, restock, interest, digest, price, saved, brand, lastsize, picks
    }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var t: String
        /// Price, already formatted ("$148").
        var p: String?
        /// Was-price, formatted.
        var w: String?
        var img: String?
        /// "−33%".
        var badge: String?
    }

    struct Size: Codable, Equatable, Sendable {
        var l: String
        /// Still in stock.
        var a: Bool
    }

    /// One update in the daily digest.
    struct Row: Codable, Equatable, Sendable {
        /// tag, restock, sale, new, size
        var tile: String
        var b: String
        var t: String
        /// "−15%", "Back", "Sale", "New"
        var st: String
        /// green, orange, blue
        var tint: String?
    }

    var k: Kind
    /// Headline.
    var t: String
    /// The line under it.
    var s: String?
    /// The photo for the Lock Screen thumbnail (the service extension's attachment).
    var img: String?
    var items: [Item]?
    var price: String?
    var was: String?
    var pct: String?
    var sizes: [Size]?
    /// The size that's left.
    var size: String?
    var pid: String?
    /// Shopify variant id, for Add to bag.
    var vid: String?
    var bid: String?
    var rows: [Row]?
    /// "$131.85" saved in all.
    var save: String?
    /// "149 items".
    var count: String?
    /// "Picked for you"
    var tag: String?
    /// "9:00 AM"
    var when: String?
    /// Where a tap goes: marracat://product/<id>, marracat://brand/<id>,
    /// marracat://picks?title=…&ids=a,b.
    var open: String?

    init(k: Kind, t: String) { self.k = k; self.t = t }

    /// The card in a notification's userInfo, if it has a well-formed one.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["card"], JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let card = try? JSONDecoder().decode(AlertCard.self, from: data) else { return nil }
        self = card
    }

    /// For a local notification's userInfo.
    var userInfoValue: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The notification category, which picks the press-and-hold card and its buttons.
    var category: String { Self.category(k) }
    static func category(_ kind: Kind) -> String { "MC_" + kind.rawValue.uppercased() }
    static let categories = Kind.allCases.map(category)

    /// The photo for the Lock Screen thumbnail.
    var thumbnail: String? { img ?? items?.first?.img }
}

// MARK: Buttons

extension AlertCard {
    enum Action: String, Sendable { case open, add, follow }

    struct Button: Identifiable {
        let id: String
        let title: String
        let action: Action
        let primary: Bool
    }

    /// The card's buttons, in the in-app banner, and (as native actions) under
    /// the press-and-hold card.
    var buttons: [Button] {
        func b(_ title: String, _ action: Action, primary: Bool = true) -> Button {
            Button(id: action.rawValue, title: title, action: action, primary: primary)
        }
        switch k {
        case .drop: return [b(String(localized: "Shop the drop", comment: "Alert button"), .open)]
        case .sale: return [b(String(localized: "See the sale", comment: "Alert button"), .open)]
        case .restock: return [b(String(localized: "Add to bag", comment: "Alert button"), .add), b(String(localized: "View", comment: "Alert button"), .open, primary: false)]
        case .interest: return [b(String(localized: "Show matches", comment: "Alert button"), .open)]
        case .digest: return [b(String(localized: "See all", comment: "Alert button"), .open)]
        case .price: return [b(String(localized: "Add to bag", comment: "Alert button"), .add), b(String(localized: "View", comment: "Alert button"), .open, primary: false)]
        case .saved: return [b(String(localized: "See them", comment: "Alert button"), .open)]
        case .brand: return [b(String(localized: "Follow", comment: "Alert button: follow a brand's sales"), .follow),
                             b(count.map { String(localized: "Browse \($0)", comment: "Alert button; the argument is like '149 items'") }
                               ?? String(localized: "Browse", comment: "Alert button"), .open, primary: false)]
        case .lastsize: return [b(size.map { String(localized: "Grab \($0)", comment: "Alert button; the argument is a size") }
                                  ?? String(localized: "Grab it", comment: "Alert button"), .add)]
        case .picks: return [b(String(localized: "See all \(items?.count ?? 5)", comment: "Alert button; the argument is how many picks"), .open)]
        }
    }
}

// MARK: The card

/// The design for every kind. `buttons`: shown in the in-app banner; under a
/// pressed-and-held notification iOS draws its own action buttons instead.
struct AlertCardView: View {
    let card: AlertCard
    var buttons = true
    var opaque = false
    var onAction: (AlertCard.Action) -> Void = { _ in }

    var body: some View {
        content
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(opaque ? AnyShapeStyle(Color(white: 0.1).opacity(0.96)) : AnyShapeStyle(Color.black.opacity(0.62)))
                    .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("alertCard_\(card.k.rawValue)")
    }

    @ViewBuilder private var content: some View {
        switch card.k {
        case .drop, .interest: stripCard
        case .sale: saleCard
        case .restock: restockCard
        case .digest: digestCard
        case .price: priceCard
        case .saved: savedCard
        case .brand: brandCard
        case .lastsize: lastSizeCard
        case .picks: picksCard
        }
    }

    // C01 new drop / C05 interest match: header, then the products in a row.
    private var stripCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(dot: card.k == .drop ? .blue : .purple)
            HStack(alignment: .top, spacing: 8) {
                ForEach((card.items ?? []).prefix(card.k == .drop ? 3 : 2)) { item in productTile(item) }
            }
            buttonRow
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // C03 brand sale: header, the best markdowns with their % off.
    private var saleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(dot: .orange)
            HStack(alignment: .top, spacing: 8) {
                ForEach((card.items ?? []).prefix(4)) { item in productTile(item, compact: true) }
            }
            buttonRow
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // C04 back in stock: the photo and one-tap Add to bag.
    private var restockCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(dot: .green)
            if let item = card.items?.first {
                HStack(spacing: 10) {
                    photo(item.img).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.t).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if let p = item.p { Text(p).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        if buttons { buttonRow.padding(.top, 5) }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // C06 daily digest: one card, a row per update.
    private var digestCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(dot: .blue)
            ForEach(Array((card.rows ?? []).prefix(4).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Image(systemName: Self.tileSymbol(row.tile))
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.b).font(.footnote.weight(.semibold))
                        Text(row.t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(row.st).font(.caption.weight(.semibold))
                        .foregroundStyle(Self.tint(row.tint))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
            }
            buttonRow
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // D01 price drop: the new price is the hero, the photo on the right.
    private var priceCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                kicker(String(localized: "Price drop", comment: "Alert kicker"))
                if let item = card.items?.first {
                    Text(item.t).font(.subheadline.weight(.semibold)).lineLimit(2).padding(.top, 10)
                }
                if let s = card.s { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.price ?? "").font(.system(size: 28, weight: .bold)).monospacedDigit()
                    if let was = card.was { Text(was).font(.subheadline).strikethrough().foregroundStyle(.secondary).monospacedDigit() }
                }
                .padding(.top, 6)
                HStack(spacing: 8) {
                    if let pct = card.pct { pill(pct, color: .green) }
                    if buttons, let b = card.buttons.first { capsule(b) }
                }
                .padding(.top, 8)
            }
            photo(card.items?.first?.img)
                .frame(width: 112, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(14)
    }

    // D02 several watched prices dropped: a photo mosaic and the total saved.
    private var savedCard: some View {
        let items = card.items ?? []
        return HStack(spacing: 14) {
            HStack(spacing: 4) {
                photo(items.first?.img).frame(width: 54, height: 112)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous))
                VStack(spacing: 4) {
                    photo(items.dropFirst().first?.img).frame(width: 54, height: 54)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 10, style: .continuous))
                    photo(items.dropFirst(2).first?.img).frame(width: 54, height: 54)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 10, topTrailingRadius: 4, style: .continuous))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                kicker(String(localized: "Price drops", comment: "Alert kicker"), logo: 18)
                Text(card.t).font(.headline).lineLimit(2).padding(.top, 6)
                if let s = card.s { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2) }
                HStack(spacing: 8) {
                    if let save = card.save { pill(String(localized: "Save \(save)", comment: "Alert pill; the argument is an amount"), color: .green) }
                    if buttons, let b = card.buttons.first { capsule(b) }
                }
                .padding(.top, 8)
            }
        }
        .padding(14)
    }

    // D03 a brand they'd like: a wide photo, then the pitch and Follow.
    private var brandCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo(card.img, fill: true)
                .frame(height: 150).frame(maxWidth: .infinity).clipped()
                .overlay(alignment: .topLeading) {
                    if let tag = card.tag {
                        Text(tag.uppercased()).font(.caption2.weight(.bold)).tracking(0.6)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .padding(12)
                    }
                }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    logo(32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.t).font(.custom("Futura-Medium", size: 19, relativeTo: .headline)).lineLimit(1)
                        if let s = card.s { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                buttonRow
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        }
    }

    // D04 last size left: which sizes are gone, the one that's left.
    private var lastSizeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                photo(card.items?.first?.img).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "LAST SIZE LEFT", comment: "Alert kicker"))
                        .font(.footnote.weight(.bold)).tracking(0.4).foregroundStyle(.orange)
                    Text(card.items?.first?.t ?? card.t).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let s = card.s { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(Array((card.sizes ?? []).prefix(6).enumerated()), id: \.offset) { _, size in
                    Text(size.l).font(.caption.weight(.semibold))
                        .strikethrough(!size.a)
                        .foregroundStyle(size.a ? .white : .white.opacity(0.38))
                        .frame(minWidth: 36, minHeight: 30).padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(size.a ? 0.12 : 0)))
                        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(size.a ? 1 : 0.22), lineWidth: size.a ? 1.5 : 1) }
                        .accessibilityLabel(size.a ? Text("\(size.l), in stock", comment: "VoiceOver: a size chip") : Text("\(size.l), sold out", comment: "VoiceOver: a size chip"))
                }
                Spacer(minLength: 4)
                if buttons, let b = card.buttons.first { capsule(b) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // D05 weekly picks: Futura headline, three fanned photos.
    private var picksCard: some View {
        let items = card.items ?? []
        return VStack(alignment: .leading, spacing: 10) {
            kicker(card.when.map { String(localized: "Sunday picks · \($0)", comment: "Alert kicker; the argument is a time") }
                   ?? String(localized: "Sunday picks", comment: "Alert kicker"), logo: 24)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.t).font(.custom("Futura-Medium", size: 24, relativeTo: .title2)).lineLimit(2).minimumScaleFactor(0.8)
                    if let s = card.s { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                    buttonRow
                }
                Spacer(minLength: 0)
                ZStack {
                    fanned(items.dropFirst().first?.img, angle: -9, x: -34)
                    fanned(items.dropFirst(2).first?.img, angle: 8, x: 34)
                    fanned(items.first?.img, angle: 0, x: 0, big: true)
                }
                .frame(width: 140, height: 124)
                .accessibilityHidden(true)
            }
        }
        .padding(16)
    }

    // MARK: Pieces

    private func header(dot: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            logo(32)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.t).font(.headline).lineLimit(1)
                if let s = card.s {
                    HStack(spacing: 5) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(s).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func kicker(_ text: String, logo size: CGFloat = 24) -> some View {
        HStack(spacing: 8) {
            logo(size)
            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func logo(_ size: CGFloat) -> some View {
        Image("MarracatLogo").resizable().scaledToFit()
            .frame(width: size, height: size)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }

    private func productTile(_ item: AlertCard.Item, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            photo(item.img)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if let badge = item.badge {
                        Text(badge).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.72)))
                            .padding(5)
                    }
                }
            if let p = item.p { Text(p).font(.caption.weight(.semibold)).monospacedDigit().padding(.top, 3) }
            Text(item.t).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func photo(_ url: String?, fill: Bool = false) -> some View {
        ZStack {
            Color.white
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { image in
                    image.resizable().aspectRatio(contentMode: fill ? .fill : .fill)
                } placeholder: { Color.white.opacity(0.9) }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func fanned(_ url: String?, angle: Double, x: CGFloat, big: Bool = false) -> some View {
        photo(url)
            .frame(width: big ? 80 : 76, height: big ? 108 : 100)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: big ? 10 : 8, y: 5)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: big ? -4 : 4)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.22)))
    }

    @ViewBuilder private var buttonRow: some View {
        if buttons, !card.buttons.isEmpty {
            HStack(spacing: 8) { ForEach(card.buttons) { capsule($0) } }
        }
    }

    private func capsule(_ b: AlertCard.Button) -> some View {
        SwiftUI.Button { onAction(b.action) } label: {
            Text(b.title).font(.caption.weight(.semibold)).lineLimit(1)
                .foregroundStyle(b.primary ? Color.black : Color.white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(b.primary ? Color.white : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("alertButton_\(b.id)")
    }

    static func tileSymbol(_ tile: String) -> String {
        switch tile {
        case "tag": "tag"
        case "restock": "arrow.counterclockwise"
        case "sale": "percent"
        case "size": "ruler"
        default: "sparkle"
        }
    }

    static func tint(_ name: String?) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "blue": .blue
        default: .white
        }
    }
}
