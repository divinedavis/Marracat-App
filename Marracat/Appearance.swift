import SwiftUI

/// The app's look: light, the default, or dark, the black look Marracat had
/// until 2026-11-22 (owner: "The app needs to be all white theme as default
/// and allow the current theme to be set as dark mode in the settings").
/// Chosen in Profile > Appearance and kept on this device. It is the app's
/// own setting and does not follow the iPhone's: a shopper who never opens
/// the setting gets light, day and night.
///
/// A launch can name one (`-appearance dark`): UserDefaults reads launch
/// arguments before what is stored, which is how the UI tests and the
/// screenshot tour pick a look.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var scheme: ColorScheme { self == .dark ? .dark : .light }

    var title: String {
        switch self {
        case .light: String(localized: "Light", comment: "Appearance setting: the white look")
        case .dark: String(localized: "Dark", comment: "Appearance setting: the black look")
        }
    }

    /// The accessibility audit flips the simulator between light and dark
    /// with a screen open (`-APPEARANCE_FOLLOWS_SYSTEM`), so for it alone the
    /// app follows the system. Never set in a shipped launch.
    static let followsSystem = ProcessInfo.processInfo.arguments.contains("-APPEARANCE_FOLLOWS_SYSTEM")

    /// What is stored, or light when nothing is (or it is not a look we know).
    static func stored(in defaults: UserDefaults = .standard) -> Appearance {
        defaults.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .light
    }
}

/// The Profile row: the two looks, side by side.
struct AppearanceRow: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.light

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.lefthalf.filled").frame(width: 24).accessibilityHidden(true)
            Text("Appearance", comment: "Row in the You tab menu: light or dark look").brandFont(.subheadline)
            Spacer()
            Picker(String(localized: "Appearance", comment: "Row in the You tab menu: light or dark look"), selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("appearancePicker")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearanceRow")
    }
}
