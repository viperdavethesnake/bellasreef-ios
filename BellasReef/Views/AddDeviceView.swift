// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// auth.md §2 step 3a, from the approver's side.
///
/// The whole second-device journey as the operator experiences it: they are
/// holding the new device, it is showing six digits, and they type them here.
/// Nothing has to tell them a request is waiting and nothing has to identify the
/// asking device — they are looking at it.
///
/// v1 had this screen approve a *named request*, which could not be built: no
/// endpoint ever handed a `request_id` to a client that might approve it.
struct AddDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// So the caller can refresh its list without this view knowing about it.
    let onApproved: () -> Void

    /// What the hub said. Every documented status gets its own sentence,
    /// because 404 and 409 send the operator to different places: one means
    /// check the digits, the other means go back to the new device.
    private enum Result: Equatable {
        case approved
        case noSuchCode
        case notPending
        case malformed
        case failed(String)
    }

    @State private var code = ""
    @State private var working = false
    @State private var result: Result?

    private var isComplete: Bool { code.count == 6 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(.largeTitle, design: .rounded).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("claim-code-field")
                        .accessibilityLabel("Pairing code")
                        .frame(minHeight: 44)
                        // Filtered on the way in rather than validated on the
                        // way out: the hub's pattern is `^[0-9]{6}$`, and a 422
                        // for a stray space is a validation envelope the
                        // operator would have to decode.
                        .onChange(of: code) { _, typed in
                            let digits = String(typed.filter(\.isNumber).prefix(6))
                            if digits != code { code = digits }
                            if result != nil { result = nil }
                        }
                } header: {
                    Text("Code")
                } footer: {
                    Text("Open Bella's Reef on the new device and tap Pair. It shows six "
                         + "digits — type them here before they expire.")
                }

                Section {
                    Button {
                        Task { await approve() }
                    } label: {
                        if working {
                            ProgressView()
                        } else {
                            Text("Approve")
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(!isComplete || working || result == .approved)
                }

                if let result {
                    Section { outcome(result) }
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("Add a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == .approved ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func outcome(_ result: Result) -> some View {
        switch result {
        case .approved:
            Label {
                Text("Approved. The other device collects its credential within a few "
                     + "seconds and lands on its dashboard.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
            .font(Theme.caption)
        case .noSuchCode:
            problem("No device is waiting with that code. Check the digits, and check the "
                    + "code on the other device has not expired.")
        case .notPending:
            problem("That request is not waiting any more — it expired, or it has already "
                    + "been approved. Pair again on the other device for a fresh code.")
        case .malformed:
            problem("A pairing code is exactly six digits.")
        case let .failed(detail):
            problem("The hub could not be asked: \(detail)")
        }
    }

    @ViewBuilder
    private func problem(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.secondaryText)
    }

    private func approve() async {
        guard let client = model.client else {
            result = .failed("this device is not paired")
            return
        }
        working = true
        defer { working = false }

        do {
            switch try await client.claim(code: code) {
            case .approved:
                result = .approved
                onApproved()
            case .noSuchCode: result = .noSuchCode
            case .notPending: result = .notPending
            case .malformed: result = .malformed
            }
        } catch {
            result = .failed("\(error)")
        }
    }
}
