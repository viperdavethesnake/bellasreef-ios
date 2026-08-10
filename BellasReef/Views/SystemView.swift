// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @State private var confirmingUnpair = false
    @State private var liveClients: Int?
    @State private var signOutProblem: String?

    var body: some View {
        @Bindable var preferences = preferences

        NavigationStack {
            List {
                Section("Hub") {
                    if case let .paired(hub) = model.phase {
                        LabeledContent("Name", value: hub.name)
                        LabeledContent("Address", value: hub.baseURL.absoluteString)
                    }
                }

                Section {
                    Picker("Temperature", selection: $preferences.temperatureUnit) {
                        ForEach(TemperatureUnitPreference.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    // Inline rather than a segmented control: three options with
                    // words rather than glyphs, and it reflows instead of
                    // truncating at accessibility text sizes (§7.5). A segmented
                    // control clips "Fahrenheit" to "Fahre…" at XXL.
                    .pickerStyle(.inline)
                } header: {
                    Text("Units")
                } footer: {
                    Text(automaticExplanation)
                }

                Section {
                    // Standard iOS destructive styling, per design brief §2 as
                    // amended: control-red is the platform's word for "this
                    // deletes something", and is not the safety red that governs
                    // status and data.
                    Button("Sign out of this hub", role: .destructive) {
                        confirmingUnpair = true
                    }
                    // §7.4: nothing destructive fires on a single tap, and the
                    // row keeps a 44pt target.
                    .frame(minHeight: 44)

                    if let signOutProblem {
                        Label(signOutProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    }
                } footer: {
                    Text(isLastDevice
                         ? "This is the only device the hub still trusts. Signing out "
                           + "revokes it, and pairing again will need hub access."
                         : "Revokes this device on the hub and forgets the credential "
                           + "here. Another paired device can approve it again later.")
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("System")
            .task { liveClients = await model.liveClientCount() }
            .confirmationDialog(
                isLastDevice ? "Sign out the last device?" : "Sign out of this hub?",
                isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task { signOutProblem = await model.unpair() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Naming the exact command matters. The alternative — which is
                // what shipped, and what locked David out — is telling somebody
                // to wait for an approval that no device can give.
                Text(isLastDevice
                     ? "No other device is paired, so nothing can approve this one "
                       + "again. To get back in you will need to run `bellasreef pair` "
                       + "on the hub."
                     : "Another paired device can approve this one again later.")
            }
        }
    }

    /// True when this is the only client the hub still trusts.
    ///
    /// The caller is authenticated, so it is one of the live clients: a count of
    /// one means it is the only one.
    private var isLastDevice: Bool { (liveClients ?? 2) <= 1 }

    /// Says what `automatic` actually resolves to on *this* device, rather than
    /// leaving the operator to discover it by switching and watching.
    private var automaticExplanation: String {
        let resolved = TemperatureUnitPreference.automatic.resolved()
        let name = resolved == .fahrenheit ? "Fahrenheit" : "Celsius"
        return "Automatic follows your region, which here means \(name). "
            + "The hub always records Celsius; this only changes what you see."
    }
}
