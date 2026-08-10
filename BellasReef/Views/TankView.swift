// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Home. One glance = is my tank okay (design brief §3).
///
/// All five §7.1 states are here rather than implied: `connecting` before the
/// first frame, `waiting` when the socket is up but the probe has not reported,
/// `populated`, the amber disconnected line, and the terminal contract
/// mismatch. None of them is a bare spinner.
struct TankView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let monitor = model.monitor {
                    ScrollView {
                        VStack(spacing: 32) {
                            // Banners sit above the hero, never over it — §7.7:
                            // an alert must not cover the data it describes.
                            AlertBannerStack(monitor: monitor)
                            TemperatureHero(monitor: monitor)
                            SpectrumBar(monitor: monitor)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 20)
                    }
                    .safeAreaInset(edge: .top) { StatusLine(monitor: monitor) }
                } else {
                    // Error state: paired, but no monitor could be built.
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
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(spacing: 10) {
            ForEach(monitor.alerts) { alert in
                AlertBanner(alert: alert, unit: preferences.temperatureUnit)
            }
        }
        .padding(.horizontal, 20)
        // Reduce Motion turns the slide into a plain appearance (§7.3).
        .animation(.snappy, value: monitor.alerts)
    }
}

struct AlertBanner: View {
    let alert: TankMonitor.Alert
    let unit: TemperatureUnitPreference

    /// "22.0 °C — below 24.0 °C min".
    ///
    /// §7.7 wants the reading *and* the threshold, not "alert". The operator
    /// needs to know how far out of range the tank is to decide whether this is
    /// a look-in-the-morning or a get-up-now.
    private var headline: String {
        guard alert.unit == "degC" else {
            // An unexpected unit is shown raw rather than mislabelled. Silently
            // converting a pH reading as if it were Celsius would be worse than
            // ugly.
            return "\(alert.value) \(alert.unit) — \(alert.isHigh ? "above" : "below") "
                + "\(alert.threshold) \(alert.unit)"
        }
        let reading = TemperatureDisplay.value(celsius: alert.value, as: unit)
        let limit = TemperatureDisplay.value(celsius: alert.threshold, as: unit)
        let symbol = TemperatureDisplay.symbol(for: unit)
        let side = alert.isHigh ? "above" : "below"
        let bound = alert.isHigh ? "max" : "min"
        return "\(reading)\(symbol) — \(side) \(limit)\(symbol) \(bound)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: alert.isHigh ? "thermometer.sun.fill" : "thermometer.snowflake")
                .foregroundStyle(Theme.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                // The age. A breach that started four hours ago is a different
                // situation from one that started thirty seconds ago, and the
                // banner looks identical without this.
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
        .accessibilityLabel("Alert. \(headline).")
    }
}

struct TemperatureHero: View {
    let monitor: TankMonitor
    @Environment(Preferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scales with Dynamic Type (§7.5). A fixed 72pt system font ignores the
    /// user's text size entirely, which is exactly what the brief rules out.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Theme.heroNumberSize

    var body: some View {
        // A ticking clock so the age stamp ages. Without it "2m ago" stays "2m
        // ago" until the next frame arrives — and the whole point of the stamp
        // is the case where frames have stopped.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(spacing: 4) {
                content(now: context.date)
            }
            .animation(reduceMotion ? nil : .snappy, value: monitor.probe)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch monitor.probe {
        case .waiting:
            // Loading state. Says what it is waiting for, not just "…".
            VStack(spacing: 8) {
                Text("—")
                    .font(.system(size: heroSize, weight: .light, design: .rounded))
                    .foregroundStyle(Theme.tertiaryText)
                Text("Waiting for the first reading")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Waiting for the first reading")

        case let .faulted(sensorId, at):
            // §7.2: a faulted sensor shows *fault*, never its last good number.
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: heroSize * 0.5))
                    .foregroundStyle(Theme.attention)
                Text("Sensor fault")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.attention)
                Text("\(sensorId) · \(Self.age(from: at, now: now))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sensor fault on \(sensorId). No reading available.")

        case let .reading(celsius, sensorId, at):
            let stale = monitor.isStale
            VStack(spacing: 4) {
                HStack(alignment: .top, spacing: 2) {
                    Text(TemperatureDisplay.value(celsius: celsius, as: preferences.temperatureUnit))
                        .font(.system(size: heroSize, weight: .light, design: .rounded))
                        // Dim rather than hide when stale: the number is still
                        // the last thing we know, but it must not read as
                        // current. tertiaryText clears AA (§7.5).
                        .foregroundStyle(stale ? Theme.tertiaryText : Theme.primaryText)
                        .contentTransition(.numericText())
                    Text(TemperatureDisplay.symbol(for: preferences.temperatureUnit))
                        .font(.title2)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, heroSize * 0.2)
                }
                // §7.2: a stale reading gains an age stamp. A fresh one does not
                // need one — "now" is the default reading of a live number.
                Text(stale ? "\(sensorId) · \(Self.age(from: at, now: now))" : sensorId)
                    .font(Theme.caption)
                    .foregroundStyle(stale ? Theme.attention : Theme.tertiaryText)

                Sparkline(values: monitor.temperatureHistory)
                    .frame(height: 44)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                stale
                    ? "Last reading \(TemperatureDisplay.spoken(celsius: celsius, as: preferences.temperatureUnit)), \(Self.age(from: at, now: now)), not current"
                    : "\(TemperatureDisplay.spoken(celsius: celsius, as: preferences.temperatureUnit))"
            )
        }
    }

    private static func age(from: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(from)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
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
struct SpectrumBar: View {
    let monitor: TankMonitor

    private var channels: [(id: String, frame: Components.Schemas.StateFrame)] {
        monitor.channels
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, frame: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        .padding(.horizontal, 24)
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

            // "Override state is never silent" — time-and-scheduling §4 and
            // design brief §3. If a channel is held, the row says so and says
            // when it ends.
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
        // §7.5: labels carry meaning, not widget names.
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
