import SwiftUI

/// You › Notifications (owner, 2026-10-13): the switch for today's deliveries
/// in the Dynamic Island and on the Lock Screen, and, for the owner's account
/// only, a test that runs one with made-up orders.
struct NotificationsView: View {
    @Environment(AccountStore.self) private var account
    private var live: LiveActivityStore { LiveActivityStore.shared }

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
}
