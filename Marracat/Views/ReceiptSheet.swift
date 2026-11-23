import SwiftUI
import UIKit

// An order's receipt, printed (owner, 2026-10-23, after a "receipt print"
// animation, previewed first): Order details › Receipt opens a sheet where the
// receipt feeds out of a printer in bursts, a PAID stamp lands, and it can be
// torn off, re-printed or copied. It's filled from what the app keeps for the
// order (OrderExtras, CheckoutRecord); a row the brand didn't report is left
// off, as on Order details.

/// What a receipt shows, and the same as text for Copy.
struct OrderReceipt: Equatable {
    struct Line: Equatable {
        var title: String
        var option: String?
        var quantity: Int
        /// The line's amount (quantity included), when the brand reported it.
        var amount: Double?
    }
    var brand: String
    /// "#1042" from the brand's emails, when they've arrived.
    var orderName: String?
    var shopifyNumber: String?
    var date: Date
    var payment: String?
    var lines: [Line]
    var subtotal: Double?
    var shipping: Double?
    var discounts: Double?
    var taxes: Double?
    var total: Double?
    var currency: String

    @MainActor
    init(record: CheckoutRecord, brand: String, extras: OrderExtras?, items: [OrderItem], orderName: String?) {
        self.brand = brand
        self.orderName = orderName
        shopifyNumber = ShopifyIDs.number(record.orderID)
        date = record.date
        payment = extras?.payment
        lines = items.map { Line(title: $0.title, option: $0.line?.option, quantity: $0.quantity, amount: $0.line?.price) }
        subtotal = extras?.subtotal ?? record.subtotal
        shipping = extras?.shipping
        discounts = extras?.discounts
        taxes = extras?.taxes
        total = extras?.total ?? record.total
        currency = extras?.currency ?? record.currencyCode
    }

    init(brand: String, orderName: String?, shopifyNumber: String? = nil, date: Date, payment: String?, lines: [Line],
         subtotal: Double?, shipping: Double?, discounts: Double? = nil, taxes: Double?, total: Double?, currency: String) {
        self.brand = brand; self.orderName = orderName; self.shopifyNumber = shopifyNumber; self.date = date
        self.payment = payment; self.lines = lines; self.subtotal = subtotal; self.shipping = shipping
        self.discounts = discounts; self.taxes = taxes; self.total = total; self.currency = currency
    }

    func money(_ v: Double) -> String { v.formatted(.currency(code: currency)) }

    /// The number under the barcode: the brand's order number, or Shopify's.
    var code: String { (orderName ?? shopifyNumber.map { "#\($0)" } ?? "").replacingOccurrences(of: "#", with: "") }

    /// The money rows, in order, for whatever the brand reported.
    var rows: [(String, String)] {
        var out: [(String, String)] = []
        if let subtotal { out.append((String(localized: "Item(s) subtotal", comment: "Receipt row"), money(subtotal))) }
        if let shipping { out.append((String(localized: "Shipping & handling", comment: "Receipt row"), shipping == 0 ? String(localized: "Free", comment: "Shipping cost is zero") : money(shipping))) }
        if let discounts { out.append((String(localized: "Discounts", comment: "Receipt row"), "-" + money(discounts))) }
        if let taxes { out.append((String(localized: "Tax", comment: "Receipt row"), money(taxes))) }
        return out
    }

    var text: String {
        var out = [String(localized: "Marracat receipt", comment: "First line of a copied receipt"),
                   String(localized: "Sold by \(brand)", comment: "Copied receipt line")]
        if let orderName { out.append(String(localized: "Order \(orderName)", comment: "Copied receipt line")) }
        out.append(date.formatted(date: .long, time: .omitted))
        for l in lines {
            out.append("\(l.quantity) × \(l.title)" + (l.option.map { " (\($0))" } ?? "") + (l.amount.map { "  \(money($0))" } ?? ""))
        }
        out += rows.map { "\($0.0): \($0.1)" }
        if let total { out.append(String(localized: "Total: \(money(total))", comment: "Copied receipt line")) }
        if let payment { out.append(String(localized: "Paid with \(payment)", comment: "Copied receipt line")) }
        if let shopifyNumber { out.append(String(localized: "Shopify order ID \(shopifyNumber)", comment: "Copied receipt line")) }
        return out.joined(separator: "\n")
    }
}

struct ReceiptSheet: View {
    let receipt: OrderReceipt
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case blank, printing, printed, torn }
    @State private var phase = Phase.blank
    /// How far the paper is out of the printer: 0 inside, 1 all the way out.
    @State private var feed: CGFloat = 0
    @State private var paperHeight: CGFloat = 460
    @State private var stamped = false
    @State private var bump: CGFloat = 0
    @State private var falling = false
    @State private var fade: Double = 1
    @State private var copied = false
    @State private var thud = 0
    @State private var ticks = 0

    /// UI tests (MARRACAT_NO_ANIMATIONS) and Reduce Motion skip the feed and the fall.
    private var still: Bool { reduceMotion || MarracatApp.noAnimations }

    var body: some View {
        VStack(spacing: 0) {
            printer
                .padding(.top, 56)   // clear of the close button
                .zIndex(1)
            paperWindow
                .padding(.top, -11)
            VStack(spacing: 4) {
                Text(title).brandFont(.title3.bold())
                Text(subtitle).brandFont(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            .frame(minHeight: 48)
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("receiptStatus")
            actions.padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").brandFont(.footnote.bold()).foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32).background(Theme.field, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel(Text("Close", comment: "Close the receipt"))
            .accessibilityIdentifier("receiptClose")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: thud)
        .sensoryFeedback(.selection, trigger: ticks)
        .task { await print() }
    }

    private var title: String {
        switch phase {
        case .blank, .printing: String(localized: "Printing your receipt", comment: "Receipt sheet title while the receipt prints")
        case .printed: String(localized: "Order placed", comment: "Receipt sheet title once the receipt has printed")
        case .torn: String(localized: "Receipt torn off", comment: "Receipt sheet title after tearing the receipt off")
        }
    }

    private var subtitle: String {
        switch phase {
        case .blank, .printing: String(localized: "From \(receipt.brand)", comment: "Receipt sheet subtitle while printing; the brand's name")
        case .printed: String(localized: "Here's your receipt. Let it roll.", comment: "Receipt sheet subtitle once printed")
        case .torn: String(localized: "Print a fresh copy anytime.", comment: "Receipt sheet subtitle after tearing")
        }
    }

    // A glossy dark bar with a slot the paper feeds out of.
    private var printer: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(LinearGradient(stops: [.init(color: Color(red: 0.23, green: 0.25, blue: 0.29), location: 0),
                                         .init(color: Color(red: 0.11, green: 0.12, blue: 0.15), location: 0.38),
                                         .init(color: Color(red: 0.05, green: 0.06, blue: 0.08), location: 0.7),
                                         .init(color: Color(red: 0.10, green: 0.11, blue: 0.14), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 3).padding(.horizontal, 60).padding(.top, 5)
            }
            .overlay(alignment: .bottom) {
                Capsule().fill(.black).frame(height: 3).padding(.horizontal, 10).padding(.bottom, 9)
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .frame(maxWidth: 330).frame(height: 44)
            .shadow(color: .black.opacity(0.55), radius: 11, y: 10)
            .accessibilityHidden(true)
    }

    // The paper, clipped to the space under the slot so it seems to come out of it.
    private var paperWindow: some View {
        ReceiptPaper(receipt: receipt, stamped: stamped)
            .fixedSize(horizontal: false, vertical: true)   // its own height, not the window's
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paperHeight = $0 + 8 }
            .offset(y: -(1 - feed) * paperHeight + bump + (falling ? 170 : 0))
            .rotationEffect(.degrees(falling ? 7 : 0), anchor: .topLeading)
            .opacity(fade)
            .frame(maxWidth: 300, alignment: .top)
            .frame(height: paperHeight + 14, alignment: .top)
            .clipped()
            .accessibilityHidden(phase != .printed)
    }

    // One row; stacked when large text doesn't fit it.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(spacing: 8) { buttons }
        }
        .brandFont(.footnote.weight(.medium))
        .labelStyle(TightLabel())
        .lineLimit(1)
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .blank, .printing:
            Label { Text("Printing…", comment: "Receipt button while the receipt prints") } icon: { Image(systemName: "printer").symbolEffect(.pulse) }
                .modifier(PillLook(primary: true)).opacity(0.75)
                .accessibilityIdentifier("receiptPrinting")
        case .printed:
            Button { Task { await print() } } label: { Label { Text("Re-print receipt", comment: "Button") } icon: { Image(systemName: "printer") } }
                .buttonStyle(ReceiptPill(primary: true)).accessibilityIdentifier("receiptReprint")
            Button { Task { await tear() } } label: { Label { Text("Tear receipt", comment: "Button") } icon: { Image(systemName: "scissors") } }
                .buttonStyle(ReceiptPill()).accessibilityIdentifier("receiptTear")
        case .torn:
            Button { Task { await print() } } label: { Label { Text("Print receipt", comment: "Button") } icon: { Image(systemName: "printer") } }
                .buttonStyle(ReceiptPill(primary: true)).accessibilityIdentifier("receiptPrint")
        }
        Button {
            UIPasteboard.general.string = receipt.text
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
        } label: {
            Label { copied ? Text("Copied", comment: "Receipt button after copying") : Text("Copy", comment: "Button: copy the receipt") }
                icon: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
        }
        .buttonStyle(ReceiptPill())
        .accessibilityIdentifier("receiptCopy")
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func print() async {
        guard phase != .printing else { return }
        // A fresh copy: one still out tears away first.
        if phase == .printed { await tear(quietly: true) }
        phase = .printing
        stamped = false
        if still {
            feed = 1
            if reduceMotion && !MarracatApp.noAnimations {
                fade = 0
                withAnimation(.easeIn(duration: 0.3)) { fade = 1 }
                await pause(0.3)
            }
        } else {
            await pause(0.45)   // the sheet finishes rising first
            // The paper feeds in bursts, like a thermal printer, bottom edge first.
            for (to, seconds) in [(0.22, 0.5), (0.25, 0.18), (0.5, 0.5), (0.53, 0.18), (0.8, 0.5), (0.83, 0.15), (1.0, 0.3)] as [(CGFloat, Double)] {
                withAnimation(.linear(duration: seconds)) { feed = to }
                ticks += 1
                await pause(seconds)
            }
        }
        // The PAID stamp lands, and the paper takes the hit.
        withAnimation(still ? nil : .spring(response: 0.3, dampingFraction: 0.55)) { stamped = true }
        thud += 1
        if !still {
            await pause(0.22)
            withAnimation(.easeOut(duration: 0.08)) { bump = 3 }
            await pause(0.08)
            withAnimation(.easeOut(duration: 0.1)) { bump = 0 }
        }
        phase = .printed
    }

    private func tear(quietly: Bool = false) async {
        guard phase == .printed else { return }
        if still {
            if reduceMotion && !MarracatApp.noAnimations {
                withAnimation(.easeOut(duration: 0.25)) { fade = 0 }
                await pause(0.25)
            }
        } else {
            // A little tug, then the strip comes away and drops.
            withAnimation(.easeOut(duration: 0.12)) { bump = 5 }
            await pause(0.12)
            withAnimation(.easeIn(duration: 0.45)) { falling = true; fade = 0 }
            await pause(0.45)
        }
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { feed = 0; bump = 0; falling = false; fade = 1; stamped = false }
        if !quietly { phase = .torn }
    }
}

/// The paper itself: monospaced, off-white, a torn zig-zag along the bottom.
private struct ReceiptPaper: View {
    let receipt: OrderReceipt
    let stamped: Bool
    private static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    private static let faint = Color(red: 0.42, green: 0.42, blue: 0.44)
    private static let paper = Color(red: 0.984, green: 0.984, blue: 0.972)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "MARRACAT").brandFont(.system(size: 15, weight: .bold)).tracking(4.8)
                    Text("ORDER RECEIPT", comment: "Heading printed on a receipt").font(mono(11)).tracking(0.7).foregroundStyle(Self.faint)
                }
                Spacer()
                MarracatMark().stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .padding(6).frame(width: 26, height: 26).background(.black, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Text("SOLD BY", comment: "Receipt band label, before the brand's name")
                Spacer()
                Text(receipt.brand.uppercased()).lineLimit(1).truncationMode(.tail)
            }
            .font(mono(11).weight(BrandFont.heaviest))
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color(red: 0.937, green: 0.937, blue: 0.925))
            .padding(.horizontal, -6).padding(.top, 12).padding(.bottom, 8)

            if let total = receipt.total {
                Text(receipt.money(total)).brandFont(.system(size: 24, weight: .bold, design: .monospaced))
            }
            Text(([receipt.date.formatted(date: .abbreviated, time: .omitted)] + (receipt.orderName.map { [String(localized: "ORDER \($0)", comment: "Receipt line; the order number")] } ?? [])).joined(separator: " | ").uppercased())
                .font(mono(9.5)).foregroundStyle(Self.faint)
            if let payment = receipt.payment {
                Text(String(localized: "PAID WITH \(payment.uppercased())", comment: "Receipt line; the payment method")).font(mono(9.5)).foregroundStyle(Self.faint)
            }
            dashes
            ForEach(Array(receipt.lines.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .top) {
                    Text("\(l.quantity)X \(l.title)" + (l.option.map { " · \($0)" } ?? "")).lineLimit(2)
                    Spacer(minLength: 8)
                    if let amount = l.amount { Text(receipt.money(amount)) }
                }
            }
            if !receipt.rows.isEmpty {
                dashes
                ForEach(receipt.rows, id: \.0) { row in
                    HStack { Text(row.0); Spacer(); Text(row.1) }
                }
            }
            if let total = receipt.total {
                Rectangle().fill(Color(white: 0.85)).frame(height: 1).padding(.top, 6)
                HStack { Text("GRAND TOTAL", comment: "Receipt total row"); Spacer(); Text(receipt.money(total)) }
                    .font(mono(12).weight(BrandFont.heaviest)).padding(.top, 8)
            }
            Text("THANK YOU FOR SHOPPING \(receipt.brand.uppercased()) ON MARRACAT", comment: "Receipt footer; the brand's name")
                .font(mono(9.5)).tracking(0.5).foregroundStyle(Color(red: 0.27, green: 0.27, blue: 0.29))
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 8)
            if !receipt.code.isEmpty {
                Barcode(code: receipt.code).frame(height: 34).frame(maxWidth: .infinity)
                Text(verbatim: "\(receipt.code) · MARRACAT.COM").font(mono(9)).tracking(0.7).foregroundStyle(Self.faint)
                    .frame(maxWidth: .infinity).padding(.top, 3)
            }
        }
        .font(mono(11))
        .foregroundStyle(Self.ink)
        .padding(18)
        .frame(width: 290)
        .background(Self.paper)
        .overlay(alignment: .bottom) { ZigZag().fill(Self.paper).frame(height: 7).offset(y: 7) }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 1) {
                Text("PAID", comment: "Stamp on a receipt").brandFont(.system(size: 19, weight: .heavy)).tracking(1.5)
                Text(receipt.date.formatted(date: .abbreviated, time: .omitted).uppercased()).font(mono(8).weight(BrandFont.heaviest))
            }
            .foregroundStyle(Color(red: 0.82, green: 0.14, blue: 0.16))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(red: 0.82, green: 0.14, blue: 0.16), style: StrokeStyle(lineWidth: 2.5, dash: [5, 3])))
            .rotationEffect(.degrees(stamped ? -12 : -18))
            .scaleEffect(stamped ? 1 : 2.3)
            .opacity(stamped ? 1 : 0)
            .padding(.trailing, 16).padding(.top, 92)
            .accessibilityIdentifier("receiptStamp")
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("receiptPaper")
    }

    private var dashes: some View {
        Line().stroke(Color(white: 0.79), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1).padding(.vertical, 10)
    }

    private func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

private struct Line: Shape {
    func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
}

/// The torn edge: 10pt teeth pointing down.
private struct ZigZag: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: .zero)
            var x: CGFloat = 0
            while x < r.width {
                p.addLine(to: CGPoint(x: min(x + 5, r.width), y: r.height))
                p.addLine(to: CGPoint(x: min(x + 10, r.width), y: 0))
                x += 10
            }
            p.closeSubpath()
        }
    }
}

/// A barcode drawn from the order number, so each order's looks different.
/// Decorative: it doesn't encode a scannable symbology.
private struct Barcode: View {
    let code: String
    var body: some View {
        Canvas { ctx, size in
            var h = 7, x: CGFloat = 0, bars: [(CGFloat, CGFloat)] = []
            let chars = Array(code.unicodeScalars)
            for i in 0..<58 {
                h = (h * 31 + Int(chars[i % chars.count].value) + i) % 9973
                let w = CGFloat(1 + h % 3), gap = CGFloat(1 + (h >> 3) % 2)
                bars.append((x, w)); x += w + gap
            }
            let start = (size.width - x) / 2
            for (bx, w) in bars { ctx.fill(Path(CGRect(x: start + bx, y: 0, width: w, height: size.height)), with: .color(.black)) }
        }
        .accessibilityHidden(true)
    }
}

/// Icon and title 5pt apart, so the three buttons share one row.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
    }
}

/// OrderPill's look (surface capsule, grey rim; the primary one light grey).
private struct PillLook: ViewModifier {
    var primary = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(primary ? Theme.onGold : Color.primary)
            .fixedSize()
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Capsule().fill(primary ? Theme.gold : Theme.surface))
            .overlay(Capsule().stroke(primary ? Color.clear : Theme.amber, lineWidth: 1))
    }
}

private struct ReceiptPill: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PillLook(primary: primary)).opacity(configuration.isPressed ? 0.7 : 1)
    }
}
