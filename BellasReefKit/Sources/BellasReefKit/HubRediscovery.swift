// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import OpenAPIRuntime

/// Following a hub whose address has moved.
///
/// UX review B7: discovery resolves the Bonjour service to the address it
/// actually reached — an IP, on purpose (`HubDiscovery.resolve`) — and the app
/// stores that. The hub is on DHCP. When the stored address stops answering,
/// the honest move is to browse again and follow the hub, not to sit on a
/// lease that has expired. This is the decision half; `AppModel` does the
/// browsing and the switch, `TankMonitor` says when.
public enum HubRediscovery {
    /// Whether an error means the hub's *address* stopped answering — as
    /// opposed to the hub answering with a refusal (auth), speaking a
    /// contract this build cannot read, or any other failure that a new
    /// address would not cure. Only these are worth a browse.
    public static func isUnreachable(_ error: any Error) -> Bool {
        if let wrapped = error as? OpenAPIRuntime.ClientError {
            return isUnreachable(wrapped.underlyingError)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
             .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Which discovered hub, if any, is ours at a new address.
    ///
    /// One hub at a different address is followed. Several: the one whose
    /// Bonjour name is our stored name or begins with it ("Bella's Reef on
    /// bellasreef" for a hub we know as "Bella's Reef"); if that is still
    /// ambiguous, stay — switching to the wrong hub is worse than staying
    /// disconnected from the right one, and the pairing screen is a tap away.
    public static func choose(candidates: [Hub], current: Hub) -> Hub? {
        let moved = candidates.filter { $0.baseURL != current.baseURL }
        if moved.count == 1 { return moved[0] }
        let named = moved.filter { $0.name == current.name || $0.name.hasPrefix(current.name) }
        return named.count == 1 ? named[0] : nil
    }
}
