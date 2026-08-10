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
            .navigationTitle("Tank")
        }
    }

    @ViewBuilder
    private func content(monitor: TankMonitor, catalog: DeviceCatalog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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

                LightSection(monitor: monitor)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
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
        .safeAreaInset(edge: .top) { StatusLine(monitor: monitor) }
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

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.tone.color)
                .frame(width: 8, height: 8)
            Text(monitor.statusLine)
                .font(Theme.caption)
                .foregroundStyle(monitor.tone == .allClear ? Theme.secondaryText : monitor.tone.color)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // Solid, not `.bar`. Design brief §7.6: glass belongs to the tab bar and
        // toolbars only. This displays data, so it is content, so it is opaque.
        .background(Theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(monitor.statusLine)")
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
        guard alert.unit == "degC" else {
            return "\(alert.value) \(alert.unit) — \(alert.isHigh ? "above" : "below") "
                + "\(alert.threshold) \(alert.unit)"
        }
        let reading = TemperatureDisplay.value(celsius: alert.value, as: unit)
        let limit = TemperatureDisplay.value(celsius: alert.threshold, as: unit)
        let symbol = TemperatureDisplay.symbol(for: unit)
        return "\(reading)\(symbol) — \(alert.isHigh ? "above" : "below") "
            + "\(limit)\(symbol) \(alert.isHigh ? "max" : "min")"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: alert.isHigh ? "thermometer.sun.fill" : "thermometer.snowflake")
                .foregroundStyle(Theme.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.attention)
                Text(headline)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                // The age. A breach that started four hours ago is a different
                // situation from one that started thirty seconds ago.
                Text(alert.raisedAt, format: .relative(presentation: .numeric))
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
                    Sparkline(values: monitor.history(sensorId))
                        .frame(height: 40)
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
        let seconds = Int(max(0, now.timeIntervalSince(from)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
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

/// Per-channel light state, with override context made loud.
struct LightSection: View {
    let monitor: TankMonitor

    private var channels: [(id: String, frame: Components.Schemas.StateFrame)] {
        monitor.channels
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, frame: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Light")
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.secondaryText)

            if channels.isEmpty {
                // Empty state (§7.1), distinguished from loading: the socket is
                // up, and no channel has reported.
                Text("No channels reporting yet")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }

            ForEach(channels, id: \.id) { channel in
                ChannelRow(id: channel.id, frame: channel.frame)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChannelRow: View {
    let id: String
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
                Text(id).foregroundStyle(Theme.primaryText)
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
                    "Held at \(Int(override.duty * 100))% · \(Self.remaining(override.expiresInS))",
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
        .accessibilityLabel(Self.spoken(id: id, duty: duty, frame: frame))
    }

    private static func spoken(
        id: String, duty: Double, frame: Components.Schemas.StateFrame
    ) -> String {
        var parts = ["\(id), \(Int(duty * 100)) percent"]
        if let override = frame.override {
            parts.append("held at \(Int(override.duty * 100)) percent")
        }
        if frame.payload.latched == true { parts.append("interlock latched") }
        return parts.joined(separator: ", ")
    }

    private static func remaining(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        if minutes >= 1 { return "\(minutes)m left" }
        return "under a minute left"
    }
}
