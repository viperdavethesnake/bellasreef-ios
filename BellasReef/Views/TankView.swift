// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Home. One glance = is my tank okay (design brief §3).
struct TankView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                if let monitor = model.monitor {
                    VStack(spacing: 32) {
                        TemperatureHero(monitor: monitor)
                        SpectrumBar(monitor: monitor)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 24)
                } else {
                    ContentUnavailableView("Not connected", systemImage: "wifi.slash")
                }
            }
            .reefBackground()
            .navigationTitle("Tank")
            .safeAreaInset(edge: .top) {
                if let monitor = model.monitor { StatusLine(monitor: monitor) }
            }
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
        .background(.bar)
    }
}

struct TemperatureHero: View {
    let monitor: TankMonitor

    private var reading: String {
        guard let value = monitor.temperature?.value else { return "—" }
        return String(format: "%.1f", value)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 2) {
                Text(reading)
                    .font(Theme.heroNumber)
                    // Dim rather than hide when stale: the number is still the
                    // last thing we know, but it must not read as current.
                    .foregroundStyle(monitor.isStale ? Theme.tertiaryText : Theme.primaryText)
                    .contentTransition(.numericText())
                Text(monitor.temperature?.unit == "degC" ? "°C" : "")
                    .font(.title2)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 14)
            }
            Text(monitor.temperature?.sensorId ?? "waiting for a reading")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)

            Sparkline(values: monitor.temperatureHistory)
                .frame(height: 44)
                .padding(.horizontal, 40)
                .padding(.top, 8)
        }
        .animation(.snappy, value: monitor.temperature?.value)
    }
}

/// A plain line. Not a chart — History is where charts live.
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
                Text("No channels reporting yet")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
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
    }

    private static func remaining(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        if minutes >= 1 { return "\(minutes)m left" }
        return "under a minute left"
    }
}

struct SystemView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Hub") {
                    if case let .paired(hub) = model.phase {
                        LabeledContent("Name", value: hub.name)
                        LabeledContent("Address", value: hub.baseURL.absoluteString)
                    }
                }
                Section {
                    Button("Unpair this device", role: .destructive) {
                        Task { await model.unpair() }
                    }
                } footer: {
                    Text("Forgets the credential on this phone. The hub keeps its "
                         + "record, so pairing again needs approval from another "
                         + "device.")
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("System")
        }
    }
}
