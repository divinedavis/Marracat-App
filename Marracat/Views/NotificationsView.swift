import SwiftUI

/// You › Notifications (owner, 2026-10-13): the switch for today's deliveries
/// in the Dynamic Island and on the Lock Screen, and, for the owner's account
/// only, a test that runs one with made-up orders.
struct NotificationsView: View {
    @Environment(AccountStore.self) private var account
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    private var live: LiveActivityStore { LiveActivityStore.shared }
    private var deals: DealAlertStore { .shared }
    @State private var picks = WeeklyAlerts.picksOn
    @State private var brandIdeas = WeeklyAlerts.brandIdeasOn

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { live.enabled }, set: { on in Task { await live.setEnabled(on) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deliveries arriving today")
                        Text("Live in the Dynamic Island and on the Lock Screen")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("liveActivitiesToggle")
            } footer: {
                Text("When an order is out for delivery or due today, Marracat shows it live. With more than one, tap ‹ › on it to go through them; tap it to open the order. Turn Live Activities off for Marracat in the iPhone's Settings to stop them everywhere.")
            }
            // Shopping alerts (owner, 2026-11-15). The two on-phone ones are
            // promotional: off until turned on here (App Review 4.5.4).
            Section {
                Toggle(isOn: Binding(get: { deals.digest }, set: { on in Task { await deals.setDigest(on, account: account) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Daily digest")
                        Text("Price drops, sales, new drops and last sizes together at 9 AM")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!account.signedIn || deals.busy.contains("digest"))
                .accessibilityIdentifier("digestToggle")
                Toggle(isOn: $picks) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sunday picks")
                        Text("New pieces from brands you follow, once a week")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("weeklyPicksToggle")
                Toggle(isOn: $brandIdeas) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Brands you might like")
                        Text("One brand a week, only in departments you shop")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("brandIdeasToggle")
            } header: {
                Text("Shopping alerts")
            } footer: {
                Text(account.signedIn
                     ? "Back-in-stock alerts always come right away. Turn any of these off here at any time."
                     : "Sign in to get the daily digest. Back-in-stock alerts always come right away.")
            }
            .onChange(of: picks) { _, on in WeeklyAlerts.picksOn = on; changed(on) }
            .onChange(of: brandIdeas) { _, on in WeeklyAlerts.brandIdeasOn = on; changed(on) }
            .alert("Daily digest", isPresented: Binding(get: { deals.message != nil }, set: { if !$0 { deals.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(deals.message ?? "") }
            if live.isOwner {
                Section {
                    Button {
                        Task { await live.runDemo(account: account) }
                    } label: {
                        Label(live.demoRunning ? "Starting the test…" : "Test the Live Activity", systemImage: "play.circle")
                    }
                    .disabled(live.demoRunning)
                    .accessibilityIdentifier("liveActivityDemo")
                    if let message = live.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("liveActivityDemoMessage")
                    }
                } header: {
                    Text("Owner")
                } footer: {
                    Text("Starts one on this iPhone with three made-up orders (Ripl Efek, KOBA, Telfar) that go out for delivery, nearby, then delivered over about two minutes.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .marracatChrome()
        .task { await live.refresh(account: account) }
    }

    /// A weekly alert turned on or off: ask for notifications the first time,
    /// and schedule (or take back) the next one.
    private func changed(_ on: Bool) {
        Analytics.shared.track(on ? "alert_on" : "alert_off", ["kind": .string("weekly")])
        Task {
            if on { await WeeklyAlerts.requestPermission() }
            await WeeklyAlerts.refresh(catalog: catalog, shopper: shopper)
        }
    }
}
