import SwiftUI

/// The shopping alert's card sliding down over the app (owner, 2026-11-15,
/// "Marracat Alert Videos" step 3): its buttons work, a tap opens what it's
/// about, a swipe up puts it away, and it leaves on its own after a few seconds.
struct InAppAlertBanner: View {
    private var alerts: InAppAlerts { .shared }
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let card = alerts.current {
            AlertCardView(card: card, buttons: true, opaque: true) { alerts.perform($0, card: card) }
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture { alerts.perform(.open, card: card) }
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .offset(y: min(0, drag))
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height < -30 || value.predictedEndTranslation.height < -80 { alerts.dismiss() }
                        withAnimation(.spring(duration: 0.3)) { drag = 0 }
                    })
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text("Dismiss", comment: "VoiceOver action on the in-app alert banner")) { alerts.dismiss() }
                .accessibilityIdentifier("inAppAlert")
                .id(card)
        }
    }
}

extension AlertCard: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(k); hasher.combine(t); hasher.combine(s); hasher.combine(pid); hasher.combine(bid)
    }
}
