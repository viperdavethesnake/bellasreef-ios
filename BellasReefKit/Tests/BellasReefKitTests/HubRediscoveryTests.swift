// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import OpenAPIRuntime
import Testing

@testable import BellasReefKit

/// UX review B7: the app stores the address discovery resolved to — an IP,
/// deliberately (HubDiscovery.resolve) — and the hub is on DHCP. When that
/// address stops answering, browse again and follow the hub, rather than
/// stay pointed at a lease that has moved.
@Suite("Hub rediscovery")
struct HubRediscoveryTests {
    private func hub(_ name: String, _ url: String) -> Hub {
        Hub(name: name, baseURL: URL(string: url)!, discovered: true)
    }

    @Test("a transport failure is unreachable; an auth, contract or hub refusal is not")
    func classify() {
        #expect(HubRediscovery.isUnreachable(URLError(.cannotConnectToHost)))
        #expect(HubRediscovery.isUnreachable(URLError(.timedOut)))
        #expect(HubRediscovery.isUnreachable(URLError(.cannotFindHost)))
        #expect(HubRediscovery.isUnreachable(URLError(.networkConnectionLost)))
        // OpenAPIRuntime wraps the transport's error; the wrapper must not hide it.
        let wrapped = OpenAPIRuntime.ClientError(
            operationID: "info", operationInput: "", causeDescription: "transport",
            underlyingError: URLError(.cannotConnectToHost)
        )
        #expect(HubRediscovery.isUnreachable(wrapped))
        #expect(!HubRediscovery.isUnreachable(HubClient.ClientError.unauthorized))
        #expect(!HubRediscovery.isUnreachable(HubClient.ClientError.rejected("no")))
        #expect(!HubRediscovery.isUnreachable(URLError(.badServerResponse)))
        #expect(!HubRediscovery.isUnreachable(StreamClient.StreamError.undecodableFrame("x")))
    }

    @Test("one hub found at a new address: follow it")
    func oneCandidate() {
        let current = hub("Bella's Reef", "http://192.168.33.126:8000")
        let found = [hub("Bella's Reef on bellasreef", "http://192.168.33.140:8000")]
        #expect(HubRediscovery.choose(candidates: found, current: current)?.baseURL.host == "192.168.33.140")
    }

    @Test("the same address again is not a move")
    func sameAddress() {
        let current = hub("Bella's Reef", "http://192.168.33.126:8000")
        let found = [hub("Bella's Reef on bellasreef", "http://192.168.33.126:8000")]
        #expect(HubRediscovery.choose(candidates: found, current: current) == nil)
    }

    @Test("several hubs: the one whose name matches ours, by prefix; ambiguity means stay")
    func several() {
        let current = hub("Bella's Reef", "http://192.168.33.126:8000")
        let found = [
            hub("Bella's Reef on bellasreef", "http://192.168.33.140:8000"),
            hub("Frag tank on fragpi", "http://192.168.33.150:8000"),
        ]
        #expect(HubRediscovery.choose(candidates: found, current: current)?.baseURL.host == "192.168.33.140")
        let ambiguous = [
            hub("Bella's Reef on bellasreef", "http://192.168.33.140:8000"),
            hub("Bella's Reef on spare", "http://192.168.33.150:8000"),
        ]
        #expect(HubRediscovery.choose(candidates: ambiguous, current: current) == nil)
    }

    @Test("nothing found: stay")
    func none() {
        let current = hub("Bella's Reef", "http://192.168.33.126:8000")
        #expect(HubRediscovery.choose(candidates: [], current: current) == nil)
    }
}
