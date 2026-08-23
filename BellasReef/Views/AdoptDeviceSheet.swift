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
    @State private var pollIntervalText: String
    @State private var confirming = false
    @State private var working = false
    @State private var problem: String?

    init(capability: Components.Schemas.CapabilityView, onAdopted: @escaping () -> Void) {
        self.capability = capability
        self.onAdopted = onAdopted
        _name = State(initialValue: Self.seedName(for: capability))
        _pollIntervalText = State(initialValue: "5")
    }

    /// Actuator sources get the safety confirm; a probe read has no failure
    /// mode worth the friction.
    private var isActuator: Bool { capability.source.rawValue != "w1-bus" }

    /// An identifier, not a label: this stays 0-based like the wire, so a
    /// pi-pwm channel 0 is still `pi-pwm-0` on the hub. Hoisted so the confirm
    /// dialog can look up a ghost assignment before `adopt()` ever runs.
    private var proposedDeviceId: String {
        "\(driverType.rawValue)-\(capability.channel)"
            .lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The hub 422s a sensor bind with no `poll_interval_s` — "a sensor must
    /// declare poll_interval_s" — so a sensor adopt needs a cadence from the
    /// operator. Actuators never poll and always send nil.
    private var pollIntervalSeconds: Int? { Int(pollIntervalText.trimmingCharacters(in: .whitespaces)) }

    private var pollIntervalValid: Bool {
        isActuator || PollInterval.isValid(pollIntervalText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Source", value: capability.source.rawValue)
                    // Displayed 1-based (ruling 2026-08-17); the bind below
                    // sends `capability.channel` raw, as the hub numbers it.
                    LabeledContent("Channel", value: ChannelLabel.humanNumber(capability.channel))
                    LabeledContent("Driver", value: driverType.rawValue)
                } header: {
                    Text("Channel")
                } footer: {
                    if isActuator {
                        // The one screen where a person cross-references a
                        // board. Boards and datasheets count from 0.
                        Text("Numbered from 1 here; the board prints it from 0, so channel \(ChannelLabel.humanNumber(capability.channel)) is the board's \(capability.channel).")
                    }
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
                    } else {
                        // LabeledContent, matching the sheet's own idiom for a
                        // row with a fixed caption (Source/Channel/Driver above,
                        // the Role picker below): the unit lives in the label
                        // itself, "(seconds)", the same way SensorDetailSheet's
                        // threshold fields carry their unit on the section
                        // header rather than leaving a bare number to speak for
                        // itself — which is exactly what put an unexplained "5"
                        // in front of David adopting the DS18B20.
                        LabeledContent("Poll interval (seconds)") {
                            TextField("Seconds", text: $pollIntervalText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(Theme.accent)
                                .accessibilityIdentifier("adopt-poll-interval-field")
                        }
                        if !pollIntervalValid {
                            // Smallest honest hint for the floor below. Amber,
                            // not red, per §7.1 — this is guidance, not a
                            // destructive-action warning.
                            Text("At least \(PollInterval.minimumSeconds) seconds — "
                                 + "a probe read can take up to 831 ms.")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.attention)
                                .accessibilityIdentifier("adopt-poll-interval-hint")
                        }
                    }
                }
                Section {
                    Button {
                        if isActuator { confirming = true } else { Task { await adopt() } }
                    } label: {
                        if working { ProgressView() } else { Text("Adopt") }
                    }
                    .frame(minHeight: 44)
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                            || working
                            || !pollIntervalValid
                    )
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
                        .accessibilityIdentifier("adopt-sheet-cancel-button")
                }
            }
            .confirmationDialog(
                "Start real output?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Adopt", role: .destructive) { Task { await adopt() } }
                // confirmationDialog content becomes a UIAlertAction, which
                // does not carry a custom accessibilityIdentifier (verified
                // on-device: the identifier is silently dropped), so this
                // Cancel is distinguished from the toolbar's only by proving
                // the dialog is gone before anything else touches the sheet.
                Button("Cancel", role: .cancel) {}
            } message: {
                if let ghost = model.library?.schedule(assignedTo: proposedDeviceId) {
                    Text("Adopting starts real output on this channel as soon as the "
                         + "engine's schedule runs. “\(ghost.name)” is still assigned to "
                         + "this channel and resumes immediately. Only adopt hardware "
                         + "you have bench-verified.")
                } else {
                    Text("Adopting starts real output on this channel as soon as the "
                         + "engine's schedule runs. Only adopt hardware you have "
                         + "bench-verified.")
                }
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
            : "Light \(ChannelLabel.humanNumber(capability.channel))"
    }

    private func adopt() async {
        working = true
        defer { working = false }
        problem = nil
        do {
            // BindDeviceRequest's memberwise init parameter order is
            // alphabetical (generated, verified against Types.swift):
            // channel, deviceId, displayName, driverType, location,
            // pollIntervalS, role. `location` is omitted here and defaults
            // to nil. `pollIntervalS` is nil for an actuator (it never
            // polls) and the operator's validated cadence for a sensor —
            // the hub 422s a sensor bind without it.
            let outcome = try await model.client?.bind(
                .init(
                    channel: capability.channel,
                    deviceId: proposedDeviceId,
                    displayName: name.trimmingCharacters(in: .whitespaces),
                    driverType: driverType,
                    pollIntervalS: isActuator ? nil : pollIntervalSeconds.map(Double.init),
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
            problem = HumanError.describe(error)
        }
    }
}
