// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Adopt one announced channel as a device. The channel and driver are facts
/// from the capability row and are shown, never typed. The safety confirm is
/// the guardrail that lets these screens exist while actuator bring-up is
/// still bench-gated: the consequence is stated at the moment of decision.
struct AdoptDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let capability: Components.Schemas.CapabilityView
    let onAdopted: () -> Void

    @State private var name: String
    @State private var confirming = false
    @State private var working = false
    @State private var problem: String?

    init(capability: Components.Schemas.CapabilityView, onAdopted: @escaping () -> Void) {
        self.capability = capability
        self.onAdopted = onAdopted
        _name = State(initialValue: Self.seedName(for: capability))
    }

    /// Actuator sources get the safety confirm; a probe read has no failure
    /// mode worth the friction.
    private var isActuator: Bool { capability.source.rawValue != "w1-bus" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel") {
                    LabeledContent("Source", value: capability.source.rawValue)
                    LabeledContent("Channel", value: capability.channel)
                    LabeledContent("Driver", value: driverType.rawValue)
                }
                Section("Device") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("adopt-name-field")
                    // One legal role today. A picker rather than a label so
                    // future roles have a home; disabled because a choice of
                    // one is not a choice.
                    if isActuator {
                        Picker("Role", selection: .constant("light")) {
                            Text("Light").tag("light")
                        }
                        .disabled(true)
                    }
                }
                Section {
                    Button {
                        if isActuator { confirming = true } else { Task { await adopt() } }
                    } label: {
                        if working { ProgressView() } else { Text("Adopt") }
                    }
                    .frame(minHeight: 44)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    .accessibilityIdentifier("adopt-confirm-button")

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    }
                }
            }
            .navigationTitle("Adopt hardware")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Start real output?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Adopt", role: .destructive) { Task { await adopt() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Adopting starts real output on this channel as soon as the "
                     + "engine's schedule runs. Only adopt hardware you have "
                     + "bench-verified.")
            }
        }
    }

    private var driverType: Components.Schemas.BindDeviceRequest.DriverTypePayload {
        switch capability.source.rawValue {
        case "w1-bus": .ds18b20
        case "pi-pwm": .piPwm
        default: .pca9685
        }
    }

    private static func seedName(for capability: Components.Schemas.CapabilityView) -> String {
        capability.source.rawValue == "w1-bus"
            ? "Temperature probe"
            : "Light \(capability.channel)"
    }

    private func adopt() async {
        working = true
        defer { working = false }
        problem = nil
        do {
            let proposed = "\(driverType.rawValue)-\(capability.channel)"
                .lowercased().replacingOccurrences(of: " ", with: "-")
            // BindDeviceRequest's memberwise init parameter order is
            // alphabetical (generated, verified against Types.swift):
            // channel, deviceId, displayName, driverType, location,
            // pollIntervalS, role. `location` and `pollIntervalS` are
            // omitted here and default to nil.
            let outcome = try await model.client?.bind(
                .init(
                    channel: capability.channel,
                    deviceId: proposed,
                    displayName: name.trimmingCharacters(in: .whitespaces),
                    driverType: driverType,
                    role: isActuator ? .light : nil
                )
            )
            switch outcome {
            case .bound:
                onAdopted()
                dismiss()
            case .channelGone:
                problem = "The hub no longer announces this channel. Pull to refresh the list."
            case .alreadyBound:
                problem = "Another device claimed this channel since the list loaded."
            case .roleNotLegal:
                problem = "The hub refused the role for this device."
            case nil:
                problem = "Not connected to the hub."
            }
        } catch {
            problem = "\(error)"
        }
    }
}
