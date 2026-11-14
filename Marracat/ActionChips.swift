import SwiftUI

/// The product page's actions as chips (owner, 2026-10-05: "button logos ...
/// have the symbol and the name of the button next to it ... when a button is
/// touched make sure its highlighted ... and give the user a quick prompt").
/// A colored symbol and a short name in a rounded card; chips wrap in a
/// ChipFlow, two or three to a row. "On" chips (tracking, saved, hidden) stay
/// highlighted; every chip lights up while pressed.
struct ActionChipLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    var on = false
    var busy = false
    /// Inside an ActionBar: the symbol alone, filling its equal part.
    @Environment(\.actionBarSegment) private var segment

    var body: some View {
        if segment { segmentBody } else { chipBody }
    }

    /// The symbol alone; the name goes to VoiceOver. An "on" action (tracking,
    /// saved, hidden) gets its filled symbol and a tinted wash.
    private var segmentBody: some View {
        ZStack {
            if busy { ProgressView().controlSize(.small) }
            else {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: on)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background {
            if on { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.18)).padding(5) }
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var chipBody: some View {
        HStack(spacing: 7) {
            if busy { ProgressView().controlSize(.small) }
            else {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: on)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? tint.opacity(0.18) : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? tint : Theme.hairline, lineWidth: on ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension EnvironmentValues {
    /// ActionChipLabel draws as one part of an ActionBar.
    @Entry var actionBarSegment = false
}

/// The product page's actions as symbols in one rounded bar of equal parts,
/// split by hairlines (owner, 2026-11-01, picked from previews: "One bar").
/// Put an ActionBarDivider between the actions.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .environment(\.actionBarSegment, true)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ActionBarDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 26).accessibilityHidden(true)
    }
}

/// Lights a chip up while a finger is on it, with a light tap of haptics.
struct ActionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// "Added to Your List": a short note at the top of the page that the tap took.
struct ActionToast: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Color.white))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("actionToast")
    }
}

extension View {
    /// Shows `toast` for a moment, then clears it.
    func actionToast(_ toast: Binding<ActionToastMessage?>) -> some View {
        overlay(alignment: .top) {
            if let t = toast.wrappedValue {
                ActionToast(text: t.text, symbol: t.symbol)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t.id) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { if toast.wrappedValue?.id == t.id { toast.wrappedValue = nil } }
                    }
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: t.text) }
            }
        }
        .animation(.spring(duration: 0.3), value: toast.wrappedValue?.id)
    }
}

struct ActionToastMessage: Equatable {
    let id = UUID()
    let text: String
    let symbol: String
}

/// One action as a symbol alone, in the chip's rounded card: the three
/// buttons under each search result (owner, 2026-10-17: "3 buttons on each
/// product, see option or cart button ..., track price button ..., add to
/// list button"). The name goes to VoiceOver instead of the screen.
struct IconChipLabel<Glyph: View>: View {
    let title: String
    let tint: Color
    var on = false
    var busy = false
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        ZStack {
            if busy { ProgressView().controlSize(.small) }
            else { glyph().foregroundStyle(tint).symbolEffect(.bounce, value: on) }
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? tint.opacity(0.18) : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? tint : Theme.hairline, lineWidth: on ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension IconChipLabel where Glyph == Image {
    init(title: String, symbol: String, tint: Color, on: Bool = false, busy: Bool = false) {
        self.init(title: title, tint: tint, on: on, busy: busy) { Image(systemName: symbol) }
    }
}

/// Marracat's "See options" symbol: three option chips, the middle one
/// picked, like a size row (S M L). Drawn, not an SF Symbol, because none
/// says "choose a size or colour" (owner asked for one, 2026-10-17).
/// Sized from the surrounding font, like a symbol.
struct OptionsGlyph: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        let chip = size * 0.36, gap = size * 0.13, line = max(1.5, size * 0.085)
        HStack(spacing: gap) {
            RoundedRectangle(cornerRadius: chip * 0.3, style: .continuous).strokeBorder(lineWidth: line)
                .frame(width: chip, height: chip * 1.25)
            RoundedRectangle(cornerRadius: chip * 0.3, style: .continuous)
                .frame(width: chip, height: chip * 1.25)
            RoundedRectangle(cornerRadius: chip * 0.3, style: .continuous).strokeBorder(lineWidth: line)
                .frame(width: chip, height: chip * 1.25)
        }
        .frame(height: size)
        .accessibilityHidden(true)
    }
}
