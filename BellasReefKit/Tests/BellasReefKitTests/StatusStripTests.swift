// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// UX review B3, David's 2026-09-02 ruling: three states, teal/amber, no taps.
/// The state machine is here rather than in the view because the failure that
/// matters is a strip claiming "live" over a number nobody has refreshed —
/// that is a rule, and rules get tests.
@Suite("Status strip state")
@MainActor
struct StatusStripTests {
    private let now = Date(timeIntervalSince1970: 1_786_400_000)
    private let en = Locale(identifier: "en_US")

    /// 78.7 °F, the reading in the brief's copy.
    private let celsius = 25.9444

    private func reading(_ age: TimeInterval = 0) -> TankMonitor.Probe {
        .reading(celsius: celsius, sensorId: "ds18b20-a", at: now.addingTimeInterval(-age))
    }

    // MARK: Derivation

    @Test("a live socket over a current reading is the live state")
    func live() {
        let state = StatusStrip.state(
            connection: .live, probe: reading(), isStale: false, lastFrameAt: now
        )
        #expect(state == .live(reading: celsius))
    }

    @Test("the monitor's staleness verdict is the one that counts")
    func stale() {
        // Deliberately the same reading and the same socket as `live` above:
        // the only difference is the monitor's own per-probe verdict, which is
        // the point — the strip owns no threshold of its own.
        let state = StatusStrip.state(
            connection: .live, probe: reading(90), isStale: true, lastFrameAt: now
        )
        #expect(state == .stale)
    }

    @Test("a faulted probe on a live socket is amber, not a reading")
    func faulted() {
        let state = StatusStrip.state(
            connection: .live,
            probe: .faulted(sensorId: "ds18b20-a", at: now),
            isStale: false,
            lastFrameAt: now
        )
        #expect(state == .stale)
    }

    @Test("no probe has ever reported: the strip is hidden, whatever the socket")
    func hiddenWithoutAProbe() {
        for connection in Self.everyConnection {
            let state = StatusStrip.state(
                connection: connection, probe: .waiting, isStale: false, lastFrameAt: nil
            )
            #expect(state == .hidden, "\(connection) should hide, not speak")
        }
    }

    @Test("every socket state that is not live is unreachable, fresh reading or not")
    func unreachable() {
        let lastFrame = now.addingTimeInterval(-240)
        for connection in Self.everyConnection where connection != .live {
            let state = StatusStrip.state(
                connection: connection, probe: reading(), isStale: false, lastFrameAt: lastFrame
            )
            #expect(state == .unreachable(since: lastFrame), "\(connection) claimed a live reading")
        }
    }

    @Test("connecting does not get to claim live either")
    func connectingIsNotLive() {
        // A reconnect attempt is not a connection. The strip must never be the
        // reason a number that stopped arriving still looks current.
        let state = StatusStrip.state(
            connection: .connecting, probe: reading(), isStale: false, lastFrameAt: now
        )
        #expect(state == .unreachable(since: now))
    }

    @Test("a dead socket outranks a sensor fault")
    func unreachableOutranksFault() {
        let state = StatusStrip.state(
            connection: .disconnected("the hub closed the stream"),
            probe: .faulted(sensorId: "ds18b20-a", at: now),
            isStale: false,
            lastFrameAt: now
        )
        #expect(state == .unreachable(since: now))
    }

    @Test("the walk: live, stale, unreachable, live again")
    func transitions() {
        var state = StatusStrip.state(
            connection: .live, probe: reading(), isStale: false, lastFrameAt: now
        )
        #expect(state == .live(reading: celsius))

        state = StatusStrip.state(
            connection: .live, probe: reading(90), isStale: true, lastFrameAt: now
        )
        #expect(state == .stale)

        state = StatusStrip.state(
            connection: .disconnected("could not reach the hub"),
            probe: reading(300), isStale: true, lastFrameAt: now.addingTimeInterval(-240)
        )
        #expect(state == .unreachable(since: now.addingTimeInterval(-240)))

        state = StatusStrip.state(
            connection: .live, probe: reading(), isStale: false, lastFrameAt: now
        )
        #expect(state == .live(reading: celsius))
    }

    // MARK: Copy

    @Test("live reads as the reading and the word")
    func liveCopy() {
        let state = StatusStripState.live(reading: celsius)
        #expect(state.text(unit: .fahrenheit, locale: en, now: now) == "78.7 °F · live")
        #expect(state.text(unit: .celsius, locale: en, now: now) == "25.9 °C · live")
        #expect(state.compactText(unit: .fahrenheit, locale: en) == "78.7 °F")
    }

    @Test("stale borrows the Tank tab's own wording for the same condition")
    func staleCopy() {
        // Two phrasings of one state on two screens is how an operator learns
        // to distrust both. This is `TankMonitor.statusLine`'s sentence.
        #expect(StatusStripState.stale.text(unit: .fahrenheit, locale: en, now: now)
            == "No data for a minute")
        #expect(StatusStripState.stale.compactText(unit: .fahrenheit, locale: en) == "No data")
    }

    @Test("unreachable carries the age of the last frame")
    func unreachableCopy() {
        let state = StatusStripState.unreachable(since: now.addingTimeInterval(-260))
        #expect(state.text(unit: .fahrenheit, locale: en, now: now) == "Hub unreachable · 4m")
        #expect(state.compactText(unit: .fahrenheit, locale: en) == "Hub unreachable")
    }

    @Test("unreachable with no frame this session says so and invents no age")
    func unreachableWithoutAFrame() {
        let state = StatusStripState.unreachable(since: nil)
        #expect(state.text(unit: .fahrenheit, locale: en, now: now) == "Hub unreachable")
    }

    @Test("hidden says nothing at all")
    func hiddenCopy() {
        let state = StatusStripState.hidden
        #expect(state.text(unit: .fahrenheit, locale: en, now: now) == nil)
        #expect(state.compactText(unit: .fahrenheit, locale: en) == nil)
        #expect(state.tone == nil)
        #expect(state.symbolName == nil)
        #expect(state.spokenLabel(unit: .fahrenheit, locale: en, now: now) == nil)
    }

    @Test("the compact line never grows and never loses the state")
    func compactIsShorter() {
        // The largest accessibility size on the narrowest phone is the case the
        // fallback exists for; it may drop the number, never the meaning.
        let states: [StatusStripState] = [
            .live(reading: celsius), .stale, .unreachable(since: now.addingTimeInterval(-260)),
        ]
        for state in states {
            let full = state.text(unit: .fahrenheit, locale: en, now: now)!
            let compact = state.compactText(unit: .fahrenheit, locale: en)!
            #expect(compact.count <= full.count, "\(compact) is not shorter than \(full)")
            #expect(!compact.isEmpty)
        }
    }

    // MARK: Tone, symbol, VoiceOver

    @Test("teal for live, amber for both amber states, red for none of them")
    func tones() {
        // Red means safety and nothing else (Theme): a lost socket is not a
        // safety event and must never light the strip red.
        #expect(StatusStripState.live(reading: celsius).tone == .allClear)
        #expect(StatusStripState.stale.tone == .attention)
        #expect(StatusStripState.unreachable(since: now).tone == .attention)
    }

    @Test("a dot for live, a triangle for the rest")
    func symbols() {
        #expect(StatusStripState.live(reading: celsius).symbolName == "circle.fill")
        #expect(StatusStripState.stale.symbolName == "exclamationmark.triangle.fill")
        #expect(StatusStripState.unreachable(since: now).symbolName
            == "exclamationmark.triangle.fill")
    }

    @Test("VoiceOver hears the state in words, not the symbol")
    func spoken() {
        #expect(StatusStripState.live(reading: celsius).spokenLabel(unit: .fahrenheit, locale: en, now: now)
            == "Hub live. 78.7 degrees Fahrenheit")
        #expect(StatusStripState.stale.spokenLabel(unit: .fahrenheit, locale: en, now: now)
            == "No data for a minute.")
        #expect(StatusStripState.unreachable(since: now.addingTimeInterval(-260))
            .spokenLabel(unit: .fahrenheit, locale: en, now: now)
            == "Hub unreachable. Last data 4m ago.")
    }

    private static let everyConnection: [TankMonitor.Connection] = [
        .idle,
        .connecting,
        .live,
        .disconnected("could not reach the hub"),
        .contractMismatch("a frame this build cannot read"),
    ]
}

/// The adapter, against a real monitor rather than hand-built inputs. It is a
/// short function, but the probe it picks is the one the strip talks about,
/// and picking a different one from the Tank tab's hero is the bug that would
/// not look like a bug.
@Suite("Status strip reads the monitor")
@MainActor
struct StatusStripFromMonitorTests {
    private let hub = Hub(
        name: "hub", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
    )
    private let sensorId = "ds18b20-28-000000bfe244"

    private func monitor() throws -> TankMonitor {
        let client = HubClient(
            hub: hub,
            tokens: MemoryCredentials(token: "t"),
            transport: StubTransport { _, _, _ in (500, nil) }
        )
        return TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
    }

    /// The fixture's own `emitted_at`, so staleness is judged against the
    /// reading rather than against the clock this test happens to run on.
    private var observed: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: "2026-08-10T06:25:22.367842Z")!
    }

    @Test("no monitor at all: nothing to say")
    func noMonitor() {
        #expect(StatusStrip.state(monitor: nil, preferred: nil) == .hidden)
    }

    @Test("a monitor with no probe yet: still nothing to say")
    func noProbe() throws {
        let m = try monitor()
        #expect(StatusStrip.state(monitor: m, preferred: nil) == .hidden)
    }

    @Test("one reporting probe: live, and its own reading")
    func oneProbe() throws {
        let m = try monitor()
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.sensor))
        let state = StatusStrip.state(monitor: m, preferred: nil, now: observed)
        #expect(state == .live(reading: 23.812))
    }

    @Test("a chosen probe that is not reporting falls back to the one that is")
    func preferredMissing() throws {
        let m = try monitor()
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.sensor))
        // The Tank tab's hero rule. A chosen probe that has gone away must not
        // blank the strip while another probe is talking.
        let state = StatusStrip.state(monitor: m, preferred: "no-such-probe", now: observed)
        #expect(state == .live(reading: 23.812))
    }

    @Test("the chosen probe is the one asked about")
    func preferredWins() throws {
        let m = try monitor()
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.sensor))
        let state = StatusStrip.state(monitor: m, preferred: sensorId, now: observed)
        #expect(state == .live(reading: 23.812))
    }

    @Test("the monitor's own staleness threshold is what turns the strip amber")
    func goesStale() throws {
        let m = try monitor()
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.sensor))
        // 60 s is the monitor's floor with no declared cadence (`StalenessTests`).
        #expect(StatusStrip.state(monitor: m, preferred: nil, now: observed.addingTimeInterval(59))
            == .live(reading: 23.812))
        #expect(StatusStrip.state(monitor: m, preferred: nil, now: observed.addingTimeInterval(61))
            == .stale)
    }

    @Test("a faulted probe reads amber, never its last good number")
    func faultedProbe() throws {
        let m = try monitor()
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.sensor))
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.faulted))
        #expect(StatusStrip.state(monitor: m, preferred: nil, now: observed) == .stale)
    }
}
