// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Home. One glance = is my tank okay (design brief §3).
///
/// Composition, top to bottom: status line, alerts, the primary reading, any
/// other probes, then light. Nothing is centred in the viewport — a hero
/// floating in the middle left the bottom third empty on every device, which
/// read as a loading state that never finished.
///
/// All five §7.1 states are present: `connecting` before the first frame,
/// `waiting` when the socket is up but no probe has reported, populated, the
/// amber disconnected line, and the terminal contract mismatch.
struct TankView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var inspecting: String?

    var body: some View {
        NavigationStack {
            Group {
                if let monitor = model.monitor, let catalog = model.catalog {
                    content(monitor: monitor, catalog: catalog)
                } else {
                    ContentUnavailableView(
                        "Not connected",
                        systemImage: "wifi.slash",
                        description: Text("Reopen the app, or re-pair from the System tab.")
                    )
                }
            }
            .reefBackground()
            // No navigation bar. It contributed an empty band above the status
            // line and a full-width seam where its background met the content,
            // for a title the tab bar already provides. The screen now begins at
            // the safe area with the status line.
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private func content(monitor: TankMonitor, catalog: DeviceCatalog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // In the stack rather than a safeAreaInset: an inset paints its
                // own full-width background, and any colour that was not exactly
                // the page background drew a seam across the screen.
                StatusLine(monitor: monitor, catalog: catalog)
                AlertBannerStack(monitor: monitor, catalog: catalog)

                if monitor.probes.isEmpty {
                    WaitingForSensors(monitor: monitor)
                } else {
                    PrimaryReading(
                        monitor: monitor,
                        catalog: catalog,
                        sensorId: primaryId(monitor),
                        onInspect: { inspecting = $0 }
                    )

                    OtherSensors(
                        monitor: monitor,
                        catalog: catalog,
                        primary: primaryId(monitor),
                        onInspect: { inspecting = $0 }
                    )
                }

                ActuatorSections(monitor: monitor, catalog: catalog)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Pull-to-refresh on a pushed stream means "prove the connection is
        // real": drop the socket and watch it come back, and re-read the
        // configuration that does not push.
        .refreshable {
            await monitor.reconnect()
            await catalog.refresh()
        }
        .sheet(item: Binding(get: { inspecting.map(Identified.init) },
                             set: { inspecting = $0?.id })) { target in
            SensorDetailSheet(sensorId: target.id, monitor: monitor, catalog: catalog)
        }
        .task { await catalog.refresh() }
        // REST data does not push, so it goes stale in the background. Coming
        // back to the app is the moment the operator expects it to be current.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await catalog.refresh() } }
        }
    }

    /// The chosen probe, or the first reporting one when nothing is chosen.
    private func primaryId(_ monitor: TankMonitor) -> String {
        let preferred = model.preferences?.primarySensorId
        if let preferred, monitor.probes[preferred] != nil { return preferred }
        return monitor.sensorIds.first ?? ""
    }
}

/// `String` is not `Identifiable`; this is the smallest honest wrapper.
private struct Identified: Identifiable {
    let id: String
}

/// Empty state: the socket is up and no probe has spoken yet.
struct WaitingForSensors: View {
    let monitor: TankMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sensors reporting")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(monitor.connection == .live
                 ? "The hub is connected but no probe has sent a reading yet."
                 : "Waiting for the hub.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

/// The safety line. Teal / amber / red, and red only ever means safety.
struct StatusLine: View {
    let monitor: TankMonitor
    /// Where the coverage note comes from. Optional so a caller without a
    /// catalog still gets the plain line.
    var catalog: DeviceCatalog? = nil

    var body: some View {
        // A clock, for the same reason the hero has one. `tone` and
        // `statusLine` are computed against `Date()`, and staleness arrives
        // through the *absence* of frames — so nothing mutates observed state
        // and nothing triggers a redraw. Without this the line sat on a teal
        // "All clear" beside a dimmed reading stamped "1m ago": the staleness
        // indicator had itself gone stale.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            line
        }
    }

    /// "All clear" plus what it is standing on (UX review A1): if any reporting
    /// probe has no band, the line says so. Only on the clear line — every
    /// other state already names its problem.
    private var text: String {
        guard monitor.tone == .allClear, let catalog else { return monitor.statusLine }
        let note = MonitoringCoverage.note(sensorIds: monitor.sensorIds) { id in
            let device = catalog.device(id)
            return device?.alertMin != nil && device?.alertMax != nil
        }
        return note.map { "\(monitor.statusLine) · \($0)" } ?? monitor.statusLine
    }

    private var line: some View {
        HStack(spacing: 8) {
            // A symbol, not a Circle shape: `.symbolEffect` only animates SF
            // Symbols. A state change is worth one beat of motion (UX review
            // B8); steady states stay still.
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(monitor.tone.color)
                .symbolEffect(.pulse, options: .nonRepeating, value: monitor.tone)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(monitor.tone == .allClear ? Theme.secondaryText : monitor.tone.color)
            Spacer()
        }
        .padding(.vertical, 4)
        // No background of its own. Design brief §7.6 rules out glass on content;
        // a *different solid* is not much better when it spans the width — it
        // reads as a bar the screen does not have.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)")
    }
}

/// Amber banners for open threshold breaches (§7.7).
struct AlertBannerStack: View {
    let monitor: TankMonitor
    let catalog: DeviceCatalog
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            ForEach(monitor.alerts) { alert in
                AlertBanner(
                    alert: alert,
                    name: catalog.name(for: alert.deviceId),
                    unit: model.preferences?.temperatureUnit ?? .automatic
                )
            }
        }
        .animation(.snappy, value: monitor.alerts)
    }
}

struct AlertBanner: View {
    let alert: TankMonitor.Alert
    let name: String
    let unit: TemperatureUnitPreference

    /// "Display tank · 22.0 °C — below 24.0 °C min".
    ///
    /// §7.7 wants the reading *and* the threshold, not "alert". The operator
    /// needs to know how far out of range the tank is to decide whether this is
    /// a look-in-the-morning or a get-up-now.
    private var headline: String {
        // A silence has no reading to report — that is the whole point of it —
        // so it says how long we have been in the dark instead. "Not reporting"
        // rather than a temperature, because the honest answer to "how warm is
        // the tank" here is that nobody knows.
        if alert.kind == .silence {
            let since = alert.lastReadingAt ?? alert.raisedAt
            return "Not reporting for \(RelativeAge.describe(from: since))"
        }

        guard let value = alert.value, let threshold = alert.threshold,
              let alertUnit = alert.unit
        else {
            return "Out of range"
        }
        guard alertUnit == "degC" else {
            return "\(value) \(alertUnit) — \(alert.isHigh ? "above" : "below") "
                + "\(threshold) \(alertUnit)"
        }
        let reading = TemperatureDisplay.value(celsius: value, as: unit)
        let limit = TemperatureDisplay.value(celsius: threshold, as: unit)
        let symbol = TemperatureDisplay.symbol(for: unit)
        return "\(reading)\(symbol) — \(alert.isHigh ? "above" : "below") "
            + "\(limit)\(symbol) \(alert.isHigh ? "max" : "min")"
    }

    /// Violet and a broken-antenna glyph for silence: this is a statement about
    /// the instrumentation, not about the water, and amber would file it beside
    /// "slightly cold" when it is strictly worse than that.
    private var tint: Color {
        alert.kind == .silence ? Theme.silence : Theme.attention
    }

    private var glyph: String {
        switch alert.kind {
        case .silence: "sensor.tag.radiowaves.forward.fill"
        case .threshold: alert.isHigh ? "thermometer.sun.fill" : "thermometer.snowflake"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.attention)
                Text(headline)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                // The age. A breach that started four hours ago is a different
                // situation from one that started thirty seconds ago.
                // Not `.relative(presentation: .numeric)`: at zero age that
                // renders "in 0 seconds" — future tense for something that has
                // already happened, exactly when it is most likely to be read.
                Text(RelativeAge.describe(from: alert.raisedAt))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Theme.attention.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Alert on \(name). \(headline).")
    }
}

/// The hero reading, tappable through to its detail sheet.
/// Range and span under the trace.
struct SparklineCaption: View {
    let values: [Double]
    let unit: TemperatureUnitPreference
    let samples: Int
    let cadence: Double?

    var body: some View {
        if let low = values.min(), let high = values.max() {
            Text(caption(low: low, high: high))
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func caption(low: Double, high: Double) -> String {
        let symbol = TemperatureDisplay.symbol(for: unit)
        let range = "\(TemperatureDisplay.value(celsius: low, as: unit))–"
            + "\(TemperatureDisplay.value(celsius: high, as: unit))\(symbol)"
        // The span is derived from the probe's declared cadence rather than
        // assumed. Claiming "24h" for what is actually twenty minutes of buffer
        // would be the same class of lie as a stale reading shown as current.
        guard let cadence, cadence > 0, samples > 1 else { return range }
        let seconds = Double(samples - 1) * cadence
        return "\(range) · last \(Self.span(seconds))"
    }

    private static func span(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }
}

struct PrimaryReading: View {
    let monitor: TankMonitor
    let catalog: DeviceCatalog
    let sensorId: String
    let onInspect: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Theme.heroNumberSize

    private var unit: TemperatureUnitPreference {
        model.preferences?.temperatureUnit ?? .automatic
    }

    var body: some View {
        Button { onInspect(sensorId) } label: {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalog.name(for: sensorId))
                        .font(Theme.sectionTitle)
                        .foregroundStyle(Theme.secondaryText)
                    reading(now: context.date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .snappy, value: monitor.probe(sensorId))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens sensor settings")
    }

    @ViewBuilder
    private func reading(now: Date) -> some View {
        switch monitor.probe(sensorId) {
        case .waiting:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("—")
                    .font(.system(size: heroSize, weight: .light, design: .rounded))
                    .foregroundStyle(Theme.tertiaryText)
                Text("waiting for a reading")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }

        case let .faulted(_, at):
            // §7.2: a faulted sensor shows *fault*, never its last good number.
            VStack(alignment: .leading, spacing: 4) {
                Label("Sensor fault", systemImage: "exclamationmark.triangle.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Theme.attention)
                Text("no reading · \(Self.age(from: at, now: now))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sensor fault. No reading available.")

        case let .reading(celsius, _, at):
            let stale = monitor.isStale(sensorId)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 2) {
                    Text(TemperatureDisplay.value(celsius: celsius, as: unit))
                        .font(.system(size: heroSize, weight: .light, design: .rounded))
                        .foregroundStyle(stale ? Theme.tertiaryText : Theme.primaryText)
                        .contentTransition(.numericText())
                    Text(TemperatureDisplay.symbol(for: unit))
                        .font(.title2)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, heroSize * 0.18)
                }
                // §7.2: a stale reading gains an age stamp. A fresh one does not
                // need one — "now" is the default reading of a live number.
                if stale {
                    Text(Self.age(from: at, now: now))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
                // A single sample is a dot, not a trend. Reserving the height
                // for it leaves a band of empty space under the hero that reads
                // as something failing to load.
                if monitor.history(sensorId).count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        Sparkline(values: monitor.history(sensorId))
                            .frame(height: 40)
                        // A line with no scale is decoration. The range is the
                        // smallest thing that makes it readable: it says whether
                        // that wobble is a tenth of a degree or three.
                        SparklineCaption(
                            values: monitor.history(sensorId),
                            unit: unit,
                            samples: monitor.history(sensorId).count,
                            cadence: catalog.device(sensorId)?.pollIntervalS
                        )
                    }
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                } else {
                    Text("trend: collecting…")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                stale
                    ? "\(catalog.name(for: sensorId)), last reading \(TemperatureDisplay.spoken(celsius: celsius, as: unit)), \(Self.age(from: at, now: now)), not current"
                    : "\(catalog.name(for: sensorId)), \(TemperatureDisplay.spoken(celsius: celsius, as: unit))"
            )
        }
    }

    static func age(from: Date, now: Date) -> String {
        RelativeAge.describe(from: from, now: now)
    }
}

/// Every probe that is not the hero, one row each.
struct OtherSensors: View {
    let monitor: TankMonitor
    let catalog: DeviceCatalog
    let primary: String
    let onInspect: (String) -> Void

    @Environment(AppModel.self) private var model

    private var others: [String] { monitor.sensorIds.filter { $0 != primary } }

    var body: some View {
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Other sensors")
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.secondaryText)
                ForEach(others, id: \.self) { id in
                    Button { onInspect(id) } label: {
                        SensorRow(
                            name: catalog.name(for: id),
                            probe: monitor.probe(id),
                            stale: monitor.isStale(id),
                            unit: model.preferences?.temperatureUnit ?? .automatic
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SensorRow: View {
    let name: String
    let probe: TankMonitor.Probe
    let stale: Bool
    let unit: TemperatureUnitPreference

    var body: some View {
        HStack {
            Text(name)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            value
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 14)
        // 44pt minimum touch target (§7.4).
        .frame(minHeight: 44)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var value: some View {
        switch probe {
        case .waiting:
            Text("—").foregroundStyle(Theme.tertiaryText)
        case .faulted:
            Label("Fault", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.caption)
                .foregroundStyle(Theme.attention)
        case let .reading(celsius, _, _):
            Text(TemperatureDisplay.value(celsius: celsius, as: unit)
                 + TemperatureDisplay.symbol(for: unit))
                .font(Theme.value)
                .foregroundStyle(stale ? Theme.tertiaryText : Theme.primaryText)
        }
    }
}

/// A plain line. Not a chart — History is where charts live.
///
/// Values stay in Celsius: Celsius-to-Fahrenheit is affine, so the shape of the
/// trace is identical either way and converting would only add rounding.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            if values.count > 1,
               let low = values.min(), let high = values.max() {
                // A flat trace would collapse to a divide-by-zero; a hair of
                // span keeps a steady tank drawing a line rather than nothing.
                let span = max(high - low, 0.05)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width * Double(index) / Double(values.count - 1)
                        let y = geo.size.height * (1 - (value - low) / span)
                        index == 0 ? path.move(to: .init(x: x, y: y))
                                   : path.addLine(to: .init(x: x, y: y))
                    }
                }
                .stroke(Theme.accent.opacity(0.8), style: .init(lineWidth: 2, lineJoin: .round))
            }
        }
    }
}

/// Actuator state, grouped by what each actuator is *for*.
///
/// This was one "Light" heading over every state frame the hub published, which
/// was fine while the only actuator was an LED channel and wrong the moment an
/// `ato-pump` showed up beneath it. A state frame says what an actuator is
/// doing and never what it is for, so the role comes from the registry.
///
/// A role this build does not recognise renders under its own name rather than
/// being folded into a neighbouring section. Filing a device under the wrong
/// heading is worse than admitting the app has not learned that word yet: the
/// first is confidently wrong, the second is merely unfinished, and only one of
/// them can convince somebody that a doser is a light.
struct ActuatorSections: View {
    let monitor: TankMonitor
    let catalog: DeviceCatalog

    /// Husbandry-ordered sections, merged from the registry and the stream by
    /// `equipmentRows` — grouping/ordering is that function's job, not
    /// duplicated here. This view only adds the operator-facing titles.
    private var sections: [(role: String, title: String, rows: [EquipmentRow])] {
        equipmentRows(
            devices: catalog.devices, frames: monitor.channels, roles: monitor.roles,
            registryLoaded: catalog.state == .loaded
        )
            .map { (role: $0.role, title: Self.title(for: $0.role), rows: $0.rows) }
    }

    /// The contract's roles in the operator's words. Anything else keeps its own
    /// name, capitalised and nothing more, so the screen still says something
    /// true about a role this build predates.
    private static func title(for role: String) -> String {
        switch role {
        case "light": "Light"
        case "heater": "Heat"
        case "pump": "Flow"
        case "doser": "Dosing"
        case "outlet": "Outlets"
        case "": "Unassigned"
        default: role.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if sections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Equipment")
                        .font(Theme.sectionTitle)
                        .foregroundStyle(Theme.secondaryText)
                    // Two distinct emptinesses (UX-3): before the registry has
                    // loaded, we do not yet know whether there is equipment to
                    // show, so this stays the old, more tentative wording. Once
                    // `catalog` has loaded and confirms there is truly nothing
                    // adopted, the copy says that plainly instead of implying a
                    // stream that just hasn't spoken yet.
                    Text(catalog.state == .loaded ? "No equipment adopted yet" : "No channels reporting yet")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            ForEach(sections, id: \.role) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title)
                        .font(Theme.sectionTitle)
                        .foregroundStyle(Theme.secondaryText)

                    ForEach(section.rows) { row in
                        EquipmentRowView(row: row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row in the merged Equipment list: either a live state frame, or an
/// adopted actuator the stream has not spoken for yet.
struct EquipmentRowView: View {
    let row: EquipmentRow

    var body: some View {
        switch row {
        case let .reporting(id, name, frame):
            ChannelRow(id: id, name: name, frame: frame)
        case let .adoptedSilent(_, name):
            AdoptedSilentRow(name: name)
        }
    }
}

/// An adopted actuator with no state frame yet. No duty bar and no
/// percentage — inventing 0% would claim a state we do not have.
struct AdoptedSilentRow: View {
    let name: String

    var body: some View {
        HStack {
            Text(name).foregroundStyle(Theme.primaryText)
            Spacer()
            Text("no state yet")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), no state yet")
    }
}

struct ChannelRow: View {
    let id: String
    let name: String
    let frame: Components.Schemas.StateFrame
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Duty for a PWM channel; a binary channel reads as fully on or off.
    ///
    /// The generator turned the discriminated union into a real enum, so this
    /// is exhaustive — a new actuator class in the contract becomes a compile
    /// error here rather than a channel that silently renders as 0%.
    private var duty: Double {
        switch frame.payload.level {
        case let .pwm(level): level.duty
        case let .binary(level): level.on ? 1 : 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(Int(duty * 100))%")
                    .font(Theme.value)
                    .foregroundStyle(Theme.secondaryText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceRaised)
                    Capsule()
                        .fill(frame.payload.latched == true ? Theme.safety : Theme.accent)
                        .frame(width: max(2, geo.size.width * duty))
                }
            }
            .frame(height: 8)
            // The bar animates at the engine's slew rate rather than jumping
            // (§7.3); Reduce Motion swaps it for an instant change.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: duty)

            if let override = frame.override {
                Label(
                    "Held at \(Int(override.duty * 100))% · \(formatRemaining(override.expiresInS))",
                    systemImage: "hand.raised.fill"
                )
                .font(Theme.caption)
                .foregroundStyle(Theme.attention)
            }

            if frame.payload.latched == true {
                Label("Interlock latched", systemImage: "exclamationmark.octagon.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.safety)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(name: name, duty: duty, frame: frame))
    }

    private static func spoken(
        name: String, duty: Double, frame: Components.Schemas.StateFrame
    ) -> String {
        var parts = ["\(name), \(Int(duty * 100)) percent"]
        if let override = frame.override {
            parts.append("held at \(Int(override.duty * 100)) percent")
        }
        if frame.payload.latched == true { parts.append("interlock latched") }
        return parts.joined(separator: ", ")
    }
}

/// Minutes/hours-left phrasing for a live hold's countdown.
///
/// Hoisted out of `ChannelRow` (review fold, 2026-08-15): `LightingView`'s
/// hold banner needs the identical wording for the identical wire concept
/// (`OverrideContext`/`LightingCard.ActiveHold`'s time-to-expiry), and a
/// second copy is exactly the kind of thing that drifts one small edit at a
/// time. File-scope rather than a type member — neither caller has a
/// natural type to hang it on that the other should also depend on.
func formatRemaining(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
    if minutes >= 1 { return "\(minutes)m left" }
    return "under a minute left"
}
