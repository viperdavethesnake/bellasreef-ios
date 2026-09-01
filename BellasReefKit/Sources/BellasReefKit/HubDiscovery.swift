// Bella's Reef iOS — closed source.

import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "discovery")

/// A hub the app can talk to.
public struct Hub: Sendable, Hashable, Identifiable {
    public var id: String { baseURL.absoluteString }
    public let name: String
    public let baseURL: URL
    /// True when found by Bonjour rather than typed in.
    public let discovered: Bool

    public init(name: String, baseURL: URL, discovered: Bool) {
        self.name = name
        self.baseURL = baseURL
        self.discovered = discovered
    }

    /// Parse whatever the operator typed into a usable base URL.
    ///
    /// Accepts `192.168.1.20`, `bellasreef.local`, `host:8000`, and full URLs.
    /// Manual entry exists because Bonjour fails on guest networks, across
    /// VLANs, and over a VPN — and a controller you cannot reach because
    /// discovery is fussy is not much of a controller.
    public static func manual(_ raw: String, defaultPort: Int = 8000) -> Hub? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty
        else { return nil }

        if components.port == nil { components.port = defaultPort }
        guard let url = components.url else { return nil }
        return Hub(name: host, baseURL: url, discovered: false)
    }
}

/// Browses for `_bellasreef._tcp`.
///
/// The service type matters: a hostname A record alone cannot distinguish a
/// reef controller from anything else answering to `bellasreef.local`, and
/// carries no port. The hub registers the service via avahi (see the backend's
/// docs/host-setup.md).
@MainActor
@Observable
public final class HubDiscovery {

    /// What the browser is doing, so the screen can say it.
    ///
    /// `isBrowsing` alone could not distinguish "starting", "found nothing yet"
    /// and "discovery is dead" — and the last of those needs to send the
    /// operator to the manual field rather than let them keep waiting.
    public enum State: Equatable, Sendable {
        case idle
        case searching
        /// The browser failed. Recoverable, and retried automatically.
        case failed(String)
    }

    public private(set) var hubs: [Hub] = []
    public private(set) var isBrowsing = false
    public private(set) var state: State = .idle

    /// When the current browse began, for the empty-state timer.
    public private(set) var searchingSince: Date?

    private var browser: NWBrowser?
    private var retry: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// How long the screen waits before promoting the manual field.
    ///
    /// Bonjour on a healthy network answers in well under a second; ten seconds
    /// of nothing means it is not going to work here. Long enough not to nag
    /// during a normal find, short enough that nobody sits watching a spinner
    /// wondering whether it is broken.
    public static let emptyStateAfter: TimeInterval = 10

    public init() {}

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_bellasreef._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    self.state = .searching
                    self.searchingSince = Date()
                    self.consecutiveFailures = 0
                case let .failed(error):
                    // The bug this class shipped with: `isBrowsing = false` and
                    // nothing else. The NWBrowser stayed non-nil, so `start()`
                    // returned immediately at its `browser == nil` guard and the
                    // screen searched forever with a dead browser behind it.
                    //
                    // A cancelled NWBrowser cannot be restarted, so recovery is
                    // always cancel-and-recreate.
                    self.isBrowsing = false
                    // Never consumed today — `PairingFlow` matches bare
                    // `case .failed:` — but the gun is unloaded: this payload
                    // must not carry a raw error dump if a caller ever reads
                    // it.
                    self.state = .failed(HumanError.describe(error))
                    log.error("browser failed: \(String(describing: error))")
                    self.scheduleRestart()
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                await self?.refresh(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    /// Browse for a bounded time and return whatever answered.
    ///
    /// For rediscovery (`HubRediscovery`): a hub that has moved answers mDNS
    /// well inside a few seconds; one that has not answered by then is not
    /// going to, and the caller's socket is already retrying on its own.
    public static func browse(for seconds: TimeInterval) async -> [Hub] {
        let discovery = HubDiscovery()
        discovery.start()
        try? await Task.sleep(for: .seconds(seconds))
        let found = discovery.hubs
        discovery.stop()
        return found
    }

    public func stop() {
        retry?.cancel()
        retry = nil
        browser?.cancel()
        browser = nil
        isBrowsing = false
        state = .idle
        searchingSince = nil
    }

    /// Tear the browser down and build a new one.
    ///
    /// The only recovery there is: an NWBrowser that has failed or been
    /// cancelled cannot be restarted, so "retry" means "replace". This is what
    /// pull-to-refresh does, what a `.failed` state schedules, and what
    /// returning to the foreground triggers.
    ///
    /// Results are cleared first. Keeping the old list across a restart would
    /// show hubs that were found by a browser which has since died — plausible
    /// rows that may no longer exist, which is worse than an honest empty list
    /// for the second it takes to find them again.
    public func restart() {
        stop()
        hubs = []
        start()
    }

    /// Restart after backing off.
    ///
    /// Bounded backoff rather than an immediate retry: a browser that fails the
    /// instant it starts — no network permission, no interface — would
    /// otherwise spin as fast as the OS could refuse it, and the screen would
    /// flicker between searching and failed rather than settling on something
    /// an operator can read.
    private func scheduleRestart() {
        retry?.cancel()
        consecutiveFailures += 1
        let delay = min(pow(2.0, Double(consecutiveFailures - 1)), 30)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.state != .idle || self.browser != nil else { return }
                let failures = self.consecutiveFailures
                self.restart()
                self.consecutiveFailures = failures
            }
        }
    }

    /// Called when the app returns to the foreground.
    ///
    /// iOS tears network resources down in the background, and a browser that
    /// was alive when the app was backgrounded is frequently not alive when it
    /// comes back — without ever reporting `.failed`, so nothing above would
    /// notice. Restarting unconditionally is cheap and the alternative is a
    /// screen that silently stopped looking.
    public func refreshOnForeground() {
        guard browser != nil || state != .idle else { return }
        restart()
    }

    private func refresh(_ results: Set<NWBrowser.Result>) async {
        var found: [Hub] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard let url = await Self.resolve(result.endpoint) else { continue }
            found.append(Hub(name: name, baseURL: url, discovered: true))
        }
        hubs = found.sorted { $0.name < $1.name }
    }

    /// Turn a Bonjour service endpoint into an address we can actually call.
    ///
    /// A browse result carries the *instance name* — a human label like
    /// "Bella's Reef on bellasreef". It is not a hostname, and building
    /// `<name>.local` from it produces something unroutable the moment the
    /// operator names their hub with a space. The address and the port both live
    /// in the SRV record, so the only honest way to get them is to resolve.
    ///
    /// `NWConnection` is the resolver: it does the SRV and A/AAAA lookups, and
    /// once ready its path holds the endpoint it actually reached. That also
    /// means a hub which resolves but refuses connections never appears in the
    /// list, which is the correct outcome — a row you cannot tap through is
    /// worse than no row.
    nonisolated private static func resolve(_ endpoint: NWEndpoint) async -> URL? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let once = ResumeOnce(continuation)
            let queue = DispatchQueue(label: "com.bellasreef.resolve")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let resolved = connection.currentPath?.remoteEndpoint
                    let url = Self.url(for: resolved)
                    log.debug("resolved \(String(describing: resolved)) -> \(String(describing: url))")
                    connection.cancel()
                    once.finish(url)
                case .failed, .cancelled:
                    once.finish(nil)
                default:
                    break
                }
            }
            // A hub that answers mDNS but never completes a handshake would
            // otherwise leave the row — and this task — hanging forever.
            queue.asyncAfter(deadline: .now() + 5) {
                connection.cancel()
                once.finish(nil)
            }
            connection.start(queue: queue)
        }
    }

    nonisolated private static func url(for endpoint: NWEndpoint?) -> URL? {
        guard case let .hostPort(host, port) = endpoint else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.port = Int(port.rawValue)

        switch host {
        case let .ipv4(address):
            // Network hands the address back with the interface it was reached
            // on — `192.168.254.236%en0`. A URL host cannot carry that zone: the
            // `%` reads as a broken percent-escape and `URLComponents.url`
            // returns nil rather than complaining. A routable v4 literal does not
            // need the scope. This was the entire cause of the endless spinner.
            components.host = String("\(address)".prefix { $0 != "%" })
        case let .ipv6(address):
            // A link-local address carries a zone (`fe80::1%en0`). In a URL the
            // literal must be bracketed and the zone separator percent-encoded,
            // so this has to bypass the host setter's own escaping.
            let zoned = "\(address)".replacingOccurrences(of: "%", with: "%25")
            components.percentEncodedHost = "[\(zoned)]"
        case let .name(name, _):
            components.host = name
        @unknown default:
            return nil
        }

        return components.url
    }
}

/// Resumes a continuation exactly once, from whichever callback wins.
///
/// Both the connection's state handler and the timeout can fire, and resuming a
/// `CheckedContinuation` twice is a crash rather than a warning. `@unchecked` is
/// carried deliberately: the lock is the invariant the compiler cannot see.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<URL?, Never>

    init(_ continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func finish(_ url: URL?) {
        lock.lock()
        let isFirst = !done
        done = true
        lock.unlock()
        if isFirst { continuation.resume(returning: url) }
    }
}
