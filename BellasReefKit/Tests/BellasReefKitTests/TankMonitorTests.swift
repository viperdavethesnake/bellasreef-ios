// Bella's Reef iOS — closed source.

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import BellasReefKit

/// Live-bench finding, 2026-09-01: David stopped the hub's `api` container
/// and the Tank tab's status line rendered `OpenAPIRuntime.ClientError`'s
/// own transport dump verbatim — "Client encountered an error invoking the
/// operation "mintToken"... Code=-1004 ..." — repeating every refresh.
///
/// `TankMonitor.run()`'s catch blocks fed `error.description` /
/// `.localizedDescription` straight into `.disconnected(...)`, bypassing
/// `HumanError.describe` — the one place an error becomes a sentence
/// (`HumanError.swift`: "Raw errors go to the log; people get a sentence").
/// `disconnectedReason` is the shared seam all three catch sites now call
/// through, so this is the smallest place to prove the fix: `statusLine`/
/// `connectionLine` both just wrap this string in "Disconnected — \(why)",
/// so a bad `why` here is a bad banner there.
@Suite("Disconnected reason")
struct DisconnectedReasonTests {
    @Test("a stopped hub's mint failure reads as the HumanError sentence, not the transport dump")
    func mintTokenFailureReadsAsASentence() {
        // The exact shape a stopped `api` container produces: swift-openapi-
        // runtime's generated client throws its own `ClientError` wrapping
        // the transport failure before `mintFresh()` ever sees a response.
        let wrapped = ClientError(
            operationID: "mintToken",
            operationInput: "unused" as any Sendable,
            causeDescription: "cannot connect to host",
            underlyingError: URLError(.cannotConnectToHost)
        )
        let text = disconnectedReason(wrapped)
        #expect(!text.contains("Domain="))
        #expect(!text.contains("UserInfo="))
        #expect(!text.contains("operation"))
        #expect(text == "Nothing answered there. Check the address, and that the hub is "
                + "powered on and on this network.")
    }

    @Test("the stream's own curated sentence still comes through, not the NSError bridge default")
    func streamErrorKeepsItsOwnSentence() {
        // `StreamClient.StreamError` already carries an authored sentence —
        // routing it through the same shared seam as everything else must
        // not downgrade it to Swift's generic bridged
        // "The operation couldn't be completed..." text.
        let text = disconnectedReason(StreamClient.StreamError.notConnected)
        #expect(text == "stream is not connected")
    }
}
