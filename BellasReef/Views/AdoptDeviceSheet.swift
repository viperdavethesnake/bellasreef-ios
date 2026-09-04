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
    /// Which button the safety confirm is standing in front of.
    private enum Pending { case adopt, identify }
    @State private var pending: Pending = .adopt
    /// Non-nil from the moment Identify is confirmed until the sheet closes.
    @State private var identify: IdentifyFlow?
    @State private var identifyName = ""

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
                    // Shown 0-based, exactly as the hub sent it (ruled
                    // 2026-08-24, rehearsal F5) — the number here matches the
                    // board silkscreen, the device id, and the audit log, so
                    // the old "numbered from 1 here" footer has nothing left
                    // to explain.
                    LabeledContent("Channel", value: capability.channel)
                    LabeledContent("Driver", value: driverType.rawValue)
                } header: {
                    Text("Channel")
                }
                if let identify {
                    identifyPhases(identify)
                } else {
                    deviceSection
                    actionSection
                }
            }
            .navigationTitle("Adopt hardware")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let identify, identify.adopted, identify.phase != .named, identify.phase != .left {
                            identify.leave()
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("adopt-sheet-cancel-button")
                }
            }
            .confirmationDialog(
                "Start real output?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(pending == .identify ? "Adopt and identify" : "Adopt", role: .destructive) {
                    Task { if pending == .identify { await startIdentify() } else { await adopt() } }
                }
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
        // The ghost warning above reads `model.library?.schedules`, which is
        // empty until something has fetched it — true on the likeliest path
        // to this sheet (Tank → System → adopt), where Lighting/Schedules was
        // never visited this launch. Without this the warning is silently
        // inert exactly when it matters most (final-review finding). Same
        // shape as `DeviceCatalog.refresh()`: it swallows its own errors, so
        // there is nothing to catch here — a failed refresh just leaves the
        // warning as it was.
        .task {
            await model.library?.refresh()
            await prefillDetachedName()
        }
        .onChange(of: identify?.phase) { _, phase in
            guard let phase else { return }
            switch phase {
            case .named, .left:
                onAdopted()
                dismiss()
            case .pulsing:
                AccessibilityNotification.Announcement("Pulsing \(identify?.channelLabel ?? "the channel")").post()
            case .answer:
                AccessibilityNotification.Announcement("Pulse finished. Did the right fixture light up?").post()
            case let .failed(reason, _):
                AccessibilityNotification.Announcement(reason).post()
            case .choose, .adopting, .naming:
                break
            }
        }
    }

    /// The name field and role/poll-interval controls. Hidden while an
    /// identify flow is active; its own phases take the form over instead.
    private var deviceSection: some View {
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
    }

    /// The Identify / Adopt buttons and the problem label. Hidden while an
    /// identify flow is active; its own phases take the form over instead.
    private var actionSection: some View {
        Section {
            if isActuator {
                // Identify needs the stream to prove the rebuild;
                // without a monitor the flow would time out every
                // time, so the button is not offered.
                Button {
                    pending = .identify
                    confirming = true
                } label: {
                    if working && pending == .identify { ProgressView() } else { Text("Identify this channel") }
                }
                .frame(minHeight: 44)
                .disabled(working || model.client == nil || model.monitor == nil)
                .accessibilityIdentifier("adopt-identify-button")
            }
            Button {
                pending = .adopt
                if isActuator { confirming = true } else { Task { await adopt() } }
            } label: {
                if working && pending == .adopt { ProgressView() } else { Text(isActuator ? "Adopt without identifying" : "Adopt") }
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
        } footer: {
            if isActuator {
                Text("Identify adopts the channel with no name, then holds it at 50 percent for 5 seconds so you can see which fixture it is.")
            }
        }
    }

    @ViewBuilder
    private func identifyPhases(_ flow: IdentifyFlow) -> some View {
        switch flow.phase {
        case .choose:
            // Only reachable for an instant: start() returned a refusal and
            // `problem` carries it, so fall back to the normal sections.
            deviceSection
            actionSection
        case .adopting:
            Section("Identify") {
                Label {
                    Text("Adopting the channel. The hub restarts to pick it up, about 15 seconds.")
                } icon: {
                    ProgressView()
                }
                Button("Cancel", role: .destructive) { flow.leave() }
                    .accessibilityIdentifier("identify-cancel-button")
            }
        case .pulsing:
            Section("Identify") {
                Label {
                    Text("Watch your fixtures. \(flow.channelLabel) is at 50 percent for 5 seconds.")
                } icon: {
                    Image(systemName: "sun.max.fill").foregroundStyle(Theme.accent)
                }
            }
        case .answer:
            Section("Identify") {
                Text("Did the right fixture light up?")
                Button("Yes, name it") { flow.chooseToName() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("identify-yes-button")
                Button("Pulse again") { flow.pulseAgain() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("identify-again-button")
                Button("Not this one", role: .destructive) { flow.leave() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("identify-no-button")
            }
        case .naming:
            Section("Name") {
                TextField("Name", text: $identifyName)
                    .accessibilityIdentifier("identify-name-field")
                Button {
                    Task { await flow.name(identifyName.trimmingCharacters(in: .whitespaces)) }
                } label: {
                    Text("Save")
                }
                .frame(minHeight: 44)
                .disabled(identifyName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("identify-save-button")
            }
        case .named, .left:
            // The sheet is on its way out; see the onChange below.
            EmptyView()
        case let .failed(reason, step):
            Section("Identify") {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
                Button("Retry") { flow.retry() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("identify-retry-button")
                if step != .leave {
                    Button("Not this one", role: .destructive) { flow.leave() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("identify-no-button")
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
            : "Light \(capability.channel)"
    }

    /// Re-claiming a channel the registry still remembers used to prefill the
    /// generic seed, and submitting overwrote the detached row's name — two
    /// devices both called "Light 1" by the end of the rehearsal (finding F8).
    /// Identity, history and assignment were preserved; only the name was
    /// clobbered. When the channel matches a detached row, offer that row's
    /// name instead. The operator can still type over it — which is why the
    /// swap only happens while the field holds the untouched seed.
    private func prefillDetachedName() async {
        await model.catalog?.refresh()
        guard name == Self.seedName(for: capability),
              let detached = model.catalog?.devices.first(where: {
                  $0.deviceId == proposedDeviceId && $0.adopted != true
              }),
              let existing = detached.displayName
        else { return }
        name = existing
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

    /// Identify: bind with no name, wait, pulse. Refusals land in `problem`
    /// exactly as `adopt()`'s do, with the sheet back on its normal sections.
    private func startIdentify() async {
        guard let client = model.client, let monitor = model.monitor else {
            problem = "Not connected to the hub."
            return
        }
        working = true
        defer { working = false }
        problem = nil
        let flow = IdentifyFlow(
            client: client,
            frames: monitor,
            request: .init(
                channel: capability.channel,
                deviceId: proposedDeviceId,
                driverType: driverType,
                role: .light
            ),
            channel: capability.channel
        )
        identify = flow
        do {
            switch try await flow.start() {
            case let .bound(_, created):
                // A matched row keeps its name; prefillDetachedName() already
                // put it in `name` when the catalog knew the row.
                identifyName = created ? "" : name
            case .channelGone:
                identify = nil
                problem = "The hub no longer announces this channel. Pull to refresh the list."
            case .alreadyBound:
                identify = nil
                problem = "Another device claimed this channel since the list loaded."
            case .roleNotLegal:
                identify = nil
                problem = "The hub refused the role for this device."
            }
        } catch {
            identify = nil
            problem = HumanError.describe(error)
        }
    }
}
