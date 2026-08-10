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
    public private(set) var hubs: [Hub] = []
    public private(set) var isBrowsing = false

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_bellasreef._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
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

    public func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
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
