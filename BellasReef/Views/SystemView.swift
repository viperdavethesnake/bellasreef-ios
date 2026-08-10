// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @State private var confirmingUnpair = false

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
                    Button("Unpair this device", role: .destructive) {
                        confirmingUnpair = true
                    }
                    // §7.4: nothing destructive fires on a single tap, and the
                    // row keeps a 44pt target.
                    .frame(minHeight: 44)
                } footer: {
                    Text("Forgets the credential on this phone. The hub keeps its "
                         + "record, so pairing again needs approval from another "
                         + "device.")
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("System")
            .confirmationDialog(
                "Unpair this device?",
                isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) {
                    Task { await model.unpair() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need another paired device to approve this one again.")
            }
        }
    }

    /// Says what `automatic` actually resolves to on *this* device, rather than
    /// leaving the operator to discover it by switching and watching.
    private var automaticExplanation: String {
        let resolved = TemperatureUnitPreference.automatic.resolved()
        let name = resolved == .fahrenheit ? "Fahrenheit" : "Celsius"
        return "Automatic follows your region, which here means \(name). "
            + "The hub always records Celsius; this only changes what you see."
    }
}
