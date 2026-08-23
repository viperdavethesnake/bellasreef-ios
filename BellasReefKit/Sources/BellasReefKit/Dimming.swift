// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation

/// The dimmer floor, and what a proposed value means before it is held.
///
/// The hub snaps any duty under 8 % to 0 before it reaches the pin
/// (`services/hardware_io/bellasreef_hardware_io/drivers/dimming.py`,
/// `MIN_USABLE_DUTY = 0.08`; ruled 2026-08-11: snap *down*, never clamp up,
/// because 0 is the declared safe state and must never land inside the band
/// the fixture leaves undefined). Proven end to end at Stage 2: 5 % commanded
/// measured 0 V on both silicons.
///
/// So a slider at 5 % is not undefined — it is dark — but the app used to say
/// "Set to 5%" and let the operator believe otherwise (UX review A6). This
/// applies the hub's own rule where the operator can see it. The constant
/// lives here until the floor is a per-channel fact on the wire (review E3);
/// one place, named after its source.
public enum Dimming {
    /// Duty (0…1) below which the hub holds the channel at 0.
    public static let minUsableDuty: Double = 0.08

    /// The hub's `snap_duty`, in percent: under the floor is 0, otherwise unchanged.
    public static func snapPercent(_ percent: Double) -> Double {
        percent < minUsableDuty * 100 ? 0 : percent
    }

    /// The line under "Set to N%", or nil when the proposal is what the hub
    /// already reports. A proposal is the operator's pending choice, not a
    /// state report (UX review A4); it must never read as one.
    public static func proposalCaption(proposedPercent: Double, reportedDuty: Double?) -> String? {
        if proposedPercent > 0, proposedPercent < minUsableDuty * 100 {
            return "below \(Int(minUsableDuty * 100))% is off — this will hold at 0%"
        }
        if let reportedDuty, Int((reportedDuty * 100).rounded()) == Int(proposedPercent.rounded()) {
            return nil
        }
        return "not applied yet — tap Hold"
    }

    /// A duty (0…1) as the whole percent a person reads on a dial. Rounds,
    /// never truncates — `Int(duty * 100)` on 0.29 reads 28 and printed a
    /// number the hub never reported (UX review SF1).
    public static func percent(_ duty: Double) -> Int {
        Int((duty * 100).rounded())
    }

    /// Below this gap between reported and target duty, a slew in progress
    /// reads as arrived rather than as still catching up.
    public static let convergenceThreshold: Double = 0.01

    /// The line under a schedule-driven duty while the engine's slew hasn't
    /// caught up to the curve yet — nil once the two are close enough that
    /// showing "catching up" would just be noise on top of a converged value.
    public static func convergenceCaption(reportedDuty: Double?, targetDuty: Double?) -> String? {
        guard let reportedDuty, let targetDuty,
              abs(reportedDuty - targetDuty) > convergenceThreshold else { return nil }
        return "Catching up to the schedule — now \(percent(reportedDuty))%, heading to \(percent(targetDuty))%"
    }

    /// The line explaining the floor itself, composed from `minUsableDuty`
    /// so the 8 never appears as a literal a reader could mistake for a
    /// magic number unconnected to the hub's own constant.
    public static let floorFootnote: String =
        "Below \(percent(minUsableDuty))% this dimmer is off — points under \(percent(minUsableDuty))% run at 0%."
}
