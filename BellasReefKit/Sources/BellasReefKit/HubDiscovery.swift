// Bella's Reef iOS — closed source.

import Foundation
import Network

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
                self?.hubs = results.compactMap(Self.hub(from:))
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

    private static func hub(from result: NWBrowser.Result) -> Hub? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }

        // Bonjour gives the instance name and the TXT record; resolving to an
        // address happens when URLSession connects. `<name>.local` is the
        // hostname avahi publishes alongside the service.
        var port = 8000
        var apiPath = "/api/v1"
        if case let .bonjour(txt) = result.metadata {
            if let raw = txt.getEntry(for: "api"), case let .string(value) = raw {
                apiPath = value
            }
            if let raw = txt.getEntry(for: "port"), case let .string(value) = raw,
               let parsed = Int(value) {
                port = parsed
            }
        }
        _ = apiPath

        var components = URLComponents()
        components.scheme = "http"
        components.host = "\(name).local"
        components.port = port
        guard let url = components.url else { return nil }

        return Hub(name: name, baseURL: url, discovered: true)
    }
}
