// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Everything about one probe: what it is called, what it reads, and the band
/// it is expected to stay inside.
///
/// The raw id lives here and only here. On the Tank tab a probe is "Display
/// tank"; `ds18b20-28-000000bfe244` is provenance, not a label, and it belongs
/// on the screen where you are deciding *which physical probe* you are editing.
struct SensorDetailSheet: View {
    let sensorId: String
    let monitor: TankMonitor
    let catalog: DeviceCatalog

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var clearMargin = ""
    @State private var saving = false
    /// The hub's own words when it refuses a band. Never paraphrased — it is
    /// the only part of a 422 the operator can act on.
    @State private var problem: String?
    @State private var savedTick = false

    private var unit: TemperatureUnitPreference {
        model.preferences?.temperatureUnit ?? .automatic
    }

    private var isPrimary: Bool { model.preferences?.primarySensorId == sensorId }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    LabeledContent("Now") { currentReading }
                    LabeledContent("Sensor id") {
                        Text(sensorId)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    TextField("Display tank", text: $name)
                        .textInputAutocapitalization(.words)
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("sensor-name")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Leave this empty to show the sensor id instead.")
                }

                Section {
                    thresholdField("Minimum", text: $minimum, identifier: "threshold-minimum")
                    thresholdField("Maximum", text: $maximum, identifier: "threshold-maximum")
                    thresholdField("Clear margin", text: $clearMargin, identifier: "threshold-margin")
                } header: {
                    Text("Alert thresholds (\(TemperatureDisplay.symbol(for: unit)))")
                } footer: {
                    Text("An alert clears only once the reading comes back inside "
                         + "the band by the clear margin. Without that gap a probe "
                         + "sitting on its limit would alert on every sample. "
                         + "Leave all three empty to switch alerting off.")
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.attention)
                            .accessibilityIdentifier("threshold-error")
                    }
                }

                Section {
                    // Immediate and device-local (UX review E6): it writes the
                    // preference on tap and Cancel does not undo it, so it must
                    // not look like a field Save will commit. A toggle-shaped
                    // row with the fact in the footer, rather than a button
                    // among the form's fields.
                    Toggle(isOn: Binding(
                        get: { isPrimary },
                        set: { on in if on { model.preferences?.primarySensorId = sensorId } }
                    )) {
                        Text("Show large on the Tank tab")
                    }
                    .disabled(isPrimary)
                    .frame(minHeight: 44)
                } footer: {
                    Text("Applies on this device as soon as you switch it on — it is not "
                         + "part of Save, and Cancel leaves it as it is. One sensor at a time.")
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle(catalog.name(for: sensorId))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .accessibilityIdentifier("save-sensor")
                    }
                }
            }
            .task { load() }
        }
    }

    @ViewBuilder
    private var currentReading: some View {
        switch monitor.probe(sensorId) {
        case .waiting:
            Text("—").foregroundStyle(Theme.tertiaryText)
        case .faulted:
            Label("Fault", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.attention)
        case let .reading(celsius, _, _):
            Text(TemperatureDisplay.value(celsius: celsius, as: unit)
                 + TemperatureDisplay.symbol(for: unit))
                .foregroundStyle(Theme.primaryText)
        }
    }

    private func thresholdField(
        _ label: String, text: Binding<String>, identifier: String
    ) -> some View {
        LabeledContent(label) {
            TextField("—", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                // Tinted, the way Settings tints an editable value. In plain
                // primary text these read as a read-out — the review found them
                // indistinguishable from the "Now" row directly above, which
                // genuinely is not editable.
                .foregroundStyle(Theme.accent)
                // Identifiers rather than positional matching: a UI test that
                // finds "the second text field" breaks the moment a row moves,
                // and then reports a layout change as a write failure.
                .accessibilityIdentifier(identifier)
        }
        .frame(minHeight: 44)
    }

    /// Fill the form from the hub, converted into whatever unit is on screen.
    private func load() {
        guard let device = catalog.device(sensorId) else { return }
        name = device.displayName ?? ""
        minimum = display(device.alertMin)
        maximum = device.alertMax.map(display) ?? ""
        clearMargin = displayDelta(device.alertClearMargin)
    }

    /// A threshold is a temperature, so it converts like one.
    private func display(_ celsius: Double?) -> String {
        guard let celsius else { return "" }
        return TemperatureDisplay.value(celsius: celsius, as: unit)
    }

    /// A margin is a *difference*, so it scales but does not shift.
    ///
    /// Converting 0.5 °C as if it were a temperature gives 32.9 °F, which is
    /// nonsense — a half-degree gap is 0.9 °F. Offsets and intervals are not
    /// the same kind of quantity, and this is the one place that matters.
    private func displayDelta(_ celsiusDelta: Double?) -> String {
        guard let celsiusDelta else { return "" }
        let scaled = unit.resolved() == .fahrenheit ? celsiusDelta * 9 / 5 : celsiusDelta
        return scaled.formatted(.number.precision(.fractionLength(1)))
    }

    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        guard unit.resolved() == .fahrenheit else { return value }
        return Measurement(value: value, unit: UnitTemperature.fahrenheit)
            .converted(to: .celsius).value
    }

    private func parseDelta(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        return unit.resolved() == .fahrenheit ? value * 5 / 9 : value
    }

    private func save() async {
        saving = true
        problem = nil
        defer { saving = false }

        let wanted = name.trimmingCharacters(in: .whitespaces)
        do {
            if wanted != (catalog.device(sensorId)?.displayName ?? "") {
                try await catalog.rename(sensorId, to: wanted.isEmpty ? nil : wanted)
            }
            try await catalog.setThresholds(
                sensorId,
                minimum: parse(minimum),
                maximum: parse(maximum),
                clearMargin: parseDelta(clearMargin)
            )
            dismiss()
        } catch let error as HubClient.ClientError {
            // Inline, next to the fields, and in the hub's own words. A band
            // whose clear zone is empty is refused with a sentence that explains
            // why; replacing it with "invalid input" would throw that away.
            problem = error.description
        } catch {
            problem = error.localizedDescription
        }
    }
}
