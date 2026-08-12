// Bella's Reef iOS — closed source.

import Foundation
import UIKit

/// What to call this device on the hub, before the operator says otherwise.
///
/// `UIDevice.current.name` used to be "David's iPhone". Since iOS 16 it returns
/// the *model* unless the app declares the user-assigned-device-name
/// entitlement, which this project does not and will not: the entitlement needs
/// a justified request to Apple to solve a problem a text field solves.
///
/// So every device pairs as "iPhone", and a clients list — which now exists —
/// would show a column of identical rows with a Revoke button beside each. The
/// operator cannot revoke a lost phone they cannot pick out of a list.
///
/// Two halves fix it. The name is **editable** on the identify card, so the
/// person holding the device gets the last word. And the default carries a
/// four-character tag derived from `identifierForVendor`, so even an operator
/// who never edits it gets rows that differ. The tag is stable for as long as
/// the app is installed, which is exactly the lifetime of the pairing it names.
public enum DeviceName {

    /// The suggested name, as the identify card seeds its field.
    ///
    /// `UIDevice` is main-actor isolated, so the device-reading half lives here
    /// and the decision-making half is the nonisolated overload below.
    @MainActor
    public static func suggested() -> String {
        suggested(model: UIDevice.current.model, vendorId: UIDevice.current.identifierForVendor)
    }

    /// Both inputs injectable so this is testable off-device: on a simulator
    /// `identifierForVendor` is real but not interesting, and the property worth
    /// testing is that two vendor ids never produce one name.
    public static func suggested(model: String, vendorId: UUID?) -> String {
        let base = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Device" : base
        guard let tag = tag(from: vendorId) else { return name }
        return "\(name) \(tag)"
    }

    /// Four hex characters, or nothing at all.
    ///
    /// `identifierForVendor` is documented as optional — it is nil before first
    /// unlock — and inventing a random tag in that case would make the
    /// suggestion change between launches, which is worse than a plain "iPhone".
    private static func tag(from vendorId: UUID?) -> String? {
        guard let vendorId else { return nil }
        let hex = vendorId.uuidString.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 4 else { return nil }
        return String(hex.prefix(4))
    }

    /// What the hub will accept: 1–128 characters, not blank.
    ///
    /// `PairRequest.client_name` is `minLength: 1, maxLength: 128` and
    /// `extra="forbid"`, so a name this app would not send is a 422 the
    /// operator has to decode from a validation envelope. Cheaper to refuse the
    /// button.
    public static func isUsable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 128
    }
}
