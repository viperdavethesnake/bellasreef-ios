// Bella's Reef iOS — closed source.

import Foundation

/// What the tab-bar accessory strip is allowed to say.
///
/// UX review B3: connection and staleness are only visible on the Tank tab.
/// On Lighting, History and System a dead hub looks healthy until you tab
/// back, which is exactly the bench capture of 2026-09-01 — the unreachable
/// banner helped only because we happened to be on Tank. David ruled for a
/// prototype on 2026-09-02, option 1: three states, teal/amber, no taps.
///
/// This is a projection of what `TankMonitor` already publishes, never a
/// second source of truth. Staleness in particular arrives as a `Bool` the
/// monitor computed with its own per-probe threshold: nothing here owns a
/// clock, a threshold, or a timer.
public enum StatusStripState: Equatable, Sendable {
    /// The socket is live and the primary probe's reading is current. Celsius,
    /// the wire unit — conversion stays at the render edge like everywhere
    /// else (`TemperatureDisplay`).
    case live(reading: Double)
    /// Connected, and the primary probe has stopped saying anything.
    case stale
    /// The socket is down. `since` is the last frame of any kind, `nil` when
    /// this session never had one.
    case unreachable(since: Date?)
    /// No sensor is adopted, so there is nothing to be silent about and the
    /// accessory does not appear at all.
    case hidden
}

/// Turns the monitor's state into the strip's.
public enum StatusStrip {

    /// The same inputs the Tank tab reads: the socket, the primary probe, the
    /// monitor's own staleness verdict for that probe, when the last frame of
    /// any kind arrived, and how many sensors the registry says are adopted.
    ///
    /// Two entry points rather than one `state(from:)` over a bundle of
    /// inputs, deliberately. This one is pure and takes five values that have
    /// nothing in common but the screen they end on, so a single unlabelled
    /// `from:` would hide which is which at the call site and buy nothing but
    /// a shorter name; the other is `@MainActor` and reads a live monitor.
    /// They are the same rule seen from two sides — a test hands it a world,
    /// the app hands it the monitor — and that is what the shared base name
    /// with distinct labels says.
    ///
    /// Order of precedence, and why:
    ///
    /// 1. **No sensor adopted hides the strip.** A lighting-only hub is a
    ///    configuration, not a fault (the same rule `TankMonitor.tone` follows
    ///    for `.allClear`), and it must not carry a permanent strip in either
    ///    colour. `adoptedSensorCount` is the registry's count, `nil` while
    ///    the registry has not loaded — and `nil` does **not** hide. The case
    ///    that most needs the strip is a hub we cannot reach, which is also
    ///    the case where the count can never arrive, so silence-on-unknown
    ///    would silence exactly the fault B3 exists to report. That was the
    ///    prototype's rule ("no probe has ever reported"), and the controller
    ///    ruled it out on 2026-09-03: a cold launch against a dead hub shows
    ///    the amber strip on every tab.
    /// 2. **Only a live socket may claim a live reading.** Every other
    ///    connection state is unreachable, including `.connecting`: a reading
    ///    is current or the socket is, and this strip must never be the reason
    ///    a stale number looks fresh.
    /// 3. A probe with nothing to say is amber and reads as no data —
    ///    a fault, or an adopted sensor that has not reported. Which of the
    ///    two is the Tank tab's job, not a one-line strip's.
    public static func state(
        connection: TankMonitor.Connection,
        probe: TankMonitor.Probe,
        isStale: Bool,
        lastFrameAt: Date?,
        adoptedSensorCount: Int?
    ) -> StatusStripState {
        if adoptedSensorCount == 0 { return .hidden }
        switch probe {
        case .waiting, .faulted:
            return connection == .live ? .stale : .unreachable(since: lastFrameAt)
        case let .reading(celsius, _, _):
            guard connection == .live else { return .unreachable(since: lastFrameAt) }
            return isStale ? .stale : .live(reading: celsius)
        }
    }

    /// The same rule, read straight off the monitor.
    ///
    /// One adapter, because two callers need the same answer: the tab view
    /// decides whether to install the accessory at all, and the strip decides
    /// what to write in it. Deriving that twice is how they would come to
    /// disagree.
    ///
    /// `preferred` is the operator's chosen probe; the first reporting one
    /// stands in when nothing is chosen, which is the Tank tab's own rule, so
    /// the strip and the hero can never be about different thermometers.
    ///
    /// The adopted count comes off the monitor rather than the catalog for the
    /// same reason the monitor's own status line takes it that way: the app
    /// wires one closure at pairing (`AppModel`, which excludes detached rows),
    /// and every reader of that number gets the one the Tank tab is using.
    @MainActor
    public static func state(
        monitor: TankMonitor?,
        preferred: String?,
        now: Date = Date()
    ) -> StatusStripState {
        guard let monitor else { return .hidden }
        let id: String
        if let preferred, monitor.probes[preferred] != nil {
            id = preferred
        } else {
            id = monitor.sensorIds.first ?? ""
        }
        return state(
            connection: monitor.connection,
            probe: monitor.probe(id),
            isStale: monitor.isStale(id, now: now),
            lastFrameAt: monitor.lastFrameAt,
            adoptedSensorCount: monitor.adoptedSensorCount()
        )
    }
}

extension StatusStripState {

    /// Teal for live, amber for both amber states. `nil` when there is nothing
    /// to show. Red is not reachable from here on purpose — a lost socket is
    /// not a safety event (`Theme`).
    public var tone: HealthTone? {
        switch self {
        case .live: .allClear
        case .stale, .unreachable: .attention
        case .hidden: nil
        }
    }

    /// The dot is the live state's whole punctuation; the triangle carries the
    /// other two.
    public var symbolName: String? {
        switch self {
        case .live: "circle.fill"
        case .stale, .unreachable: "exclamationmark.triangle.fill"
        case .hidden: nil
        }
    }

    /// The line, at full width.
    public func text(
        unit: TemperatureUnitPreference,
        locale: Locale = .current,
        now: Date = Date()
    ) -> String? {
        switch self {
        case let .live(celsius):
            return "\(reading(celsius, unit: unit, locale: locale)) · live"
        case .stale:
            // The Tank tab's own wording for the same condition
            // (`TankMonitor.statusLine`). Two phrasings for one state on two
            // screens is how an operator learns to distrust both.
            return "No data for a minute"
        case let .unreachable(since):
            guard let since else { return "Hub unreachable" }
            return "Hub unreachable · \(RelativeAge.compact(from: since, now: now))"
        case .hidden:
            return nil
        }
    }

    /// The line with the detail dropped, for a width that cannot hold the
    /// full one — largest accessibility type on the narrowest phone. The
    /// state survives; only the number and the age go.
    public func compactText(
        unit: TemperatureUnitPreference,
        locale: Locale = .current
    ) -> String? {
        switch self {
        case let .live(celsius): reading(celsius, unit: unit, locale: locale)
        case .stale: "No data"
        case .unreachable: "Hub unreachable"
        case .hidden: nil
        }
    }

    /// Spoken form. The symbol carries the state visually and a screen reader
    /// cannot see it, so the words have to (design brief §7.5).
    public func spokenLabel(
        unit: TemperatureUnitPreference,
        locale: Locale = .current,
        now: Date = Date()
    ) -> String? {
        switch self {
        case let .live(celsius):
            return "Hub live. \(TemperatureDisplay.spoken(celsius: celsius, as: unit, locale: locale))"
        case .stale:
            return "No data for a minute."
        case let .unreachable(since):
            guard let since else { return "Hub unreachable." }
            return "Hub unreachable. Last data \(RelativeAge.describe(from: since, now: now))."
        case .hidden:
            return nil
        }
    }

    private func reading(_ celsius: Double, unit: TemperatureUnitPreference, locale: Locale) -> String {
        let value = TemperatureDisplay.value(celsius: celsius, as: unit, locale: locale)
        return "\(value) \(TemperatureDisplay.symbol(for: unit, locale: locale))"
    }
}
