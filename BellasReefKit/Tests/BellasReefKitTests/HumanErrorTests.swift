// Bella's Reef iOS — closed source.

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import BellasReefKit

/// PR #2 ledger: there were two error-presentation idioms in this codebase.
/// `HumanError` is the one that replaces both — cancellation the app caused
/// itself is silence, everything else is a sentence a person can read.
@Suite("HumanError")
struct HumanErrorTests {

    // MARK: isCancellation

    @Test("Swift's own cancellation is cancellation")
    func swiftCancellationIsCancellation() {
        #expect(HumanError.isCancellation(CancellationError()))
    }

    @Test("URLError.cancelled is cancellation")
    func urlErrorCancelledIsCancellation() {
        #expect(HumanError.isCancellation(URLError(.cancelled)))
    }

    @Test("NSURLErrorDomain -999, wrapped as an underlying error, is cancellation")
    func wrappedMinus999IsCancellation() {
        let ns = NSError(domain: NSURLErrorDomain, code: -999)
        let wrapped = NSError(domain: "whatever", code: 1, userInfo: [NSUnderlyingErrorKey: ns])
        #expect(HumanError.isCancellation(wrapped))
    }

    @Test("a timeout is not cancellation")
    func timeoutIsNotCancellation() {
        #expect(!HumanError.isCancellation(URLError(.timedOut)))
    }

    /// The case the brief flagged as unverified: swift-openapi-runtime wraps
    /// every transport failure — cancellation included — in its own
    /// `ClientError`, a plain struct that is not `NSError`-bridged with the
    /// underlying error reachable via `NSUnderlyingErrorKey`. Written first,
    /// as instructed, to find out whether the NSError walk alone would catch
    /// this: it does not, which is why `isCancellation` unwraps
    /// `ClientError.underlyingError` explicitly rather than relying on the
    /// NSError bridge to expose it.
    @Test("a cancellation wrapped in the OpenAPI client's own ClientError is cancellation")
    func wrappedClientErrorIsCancellation() {
        let wrapped = ClientError(
            operationID: "history",
            operationInput: "unused" as any Sendable,
            causeDescription: "cancelled",
            underlyingError: CancellationError()
        )
        #expect(HumanError.isCancellation(wrapped))
    }

    /// The shape URLSession actually throws when a task is cancelled
    /// mid-request — `URLError(.cancelled)`, not `CancellationError` — is
    /// what a real `.task` cancellation during `client.history(...)` wraps
    /// as. `wrappedClientErrorIsCancellation` above proves the *unwrap*
    /// works at all; this proves it works for the error shape URLSession's
    /// async APIs are documented to actually produce.
    @Test("a URLError(.cancelled) wrapped in ClientError is cancellation")
    func wrappedClientErrorWithURLErrorCancelledIsCancellation() {
        let wrapped = ClientError(
            operationID: "history",
            operationInput: "unused" as any Sendable,
            causeDescription: "cancelled",
            underlyingError: URLError(.cancelled)
        )
        #expect(HumanError.isCancellation(wrapped))
    }

    @Test("a real failure wrapped in ClientError is not cancellation")
    func wrappedClientErrorRealFailureIsNotCancellation() {
        let wrapped = ClientError(
            operationID: "history",
            operationInput: "unused" as any Sendable,
            causeDescription: "timed out",
            underlyingError: URLError(.timedOut)
        )
        #expect(!HumanError.isCancellation(wrapped))
    }

    // MARK: describe

    @Test("a timeout reads as one short sentence, not a domain/code dump")
    func descriptionIsOneSentenceNotADump() {
        let text = HumanError.describe(URLError(.timedOut))
        #expect(!text.contains("NSURLErrorDomain"))
        #expect(text.count < 120)
    }

    @Test("a ClientError with no response reads as the underlying failure, not the transport dump")
    func clientErrorWithoutResponseUnwraps() {
        let wrapped = ClientError(
            operationID: "history",
            operationInput: "unused" as any Sendable,
            causeDescription: "timed out",
            underlyingError: URLError(.timedOut)
        )
        let text = HumanError.describe(wrapped)
        #expect(!text.contains("operationID"))
        #expect(!text.contains("causeDescription"))
        #expect(text == "The hub did not answer in time. Check that this device is on the tank's network.")
    }

    @Test("a ClientError carrying a real HTTP response names the status, not the raw body")
    func clientErrorWithResponseNamesStatus() {
        let response = HTTPResponse(status: .init(code: 503))
        let wrapped = ClientError(
            operationID: "history",
            operationInput: "unused" as any Sendable,
            response: response,
            causeDescription: "unexpected status",
            underlyingError: RuntimeErrorStandIn.unexpected
        )
        let text = HumanError.describe(wrapped)
        #expect(text == "The hub answered with an error (code 503).")
    }

    // MARK: describe — the connect-screen bug (raw ClientError dump instead
    // of one sentence). `cannotConnectToHost` is the exact case a fresh
    // simulator hit typing an unreachable IP into "By address".

    @Test("cannotConnectToHost with a known host names it")
    func cannotConnectToHostWithHostNamesIt() {
        let text = HumanError.describe(URLError(.cannotConnectToHost), host: "192.168.1.250")
        #expect(text == "Nothing answered at 192.168.1.250. Check the address, and that the "
                + "hub is powered on and on this network.")
    }

    @Test("cannotConnectToHost with no host reads without one")
    func cannotConnectToHostWithoutHost() {
        let text = HumanError.describe(URLError(.cannotConnectToHost))
        #expect(text == "Nothing answered there. Check the address, and that the hub is "
                + "powered on and on this network.")
    }

    @Test("cannotFindHost names the host when known")
    func cannotFindHostNamesHost() {
        let text = HumanError.describe(URLError(.cannotFindHost), host: "reef-typo.local")
        #expect(text == "Could not find reef-typo.local on this network. Check that it's "
                + "typed correctly.")
    }

    @Test("dnsLookupFailed names the host when known")
    func dnsLookupFailedNamesHost() {
        let text = HumanError.describe(URLError(.dnsLookupFailed), host: "reef-typo.local")
        #expect(text == "Could not look up reef-typo.local. Check that it's typed correctly.")
    }

    @Test("networkConnectionLost reads as a dropped connection")
    func networkConnectionLostReadsAsDropped() {
        let text = HumanError.describe(URLError(.networkConnectionLost))
        #expect(text == "The connection to the hub dropped partway through. Try again.")
    }

    @Test("notConnectedToInternet reads as a local network problem")
    func notConnectedToInternetReadsAsLocal() {
        let text = HumanError.describe(URLError(.notConnectedToInternet))
        #expect(text == "This device has no network connection. Check Wi-Fi and try again.")
    }

    @Test("cannotConnectToHost wrapped in ClientError still gets the host, unwrapped")
    func wrappedCannotConnectToHostStillGetsHost() {
        let wrapped = ClientError(
            operationID: "info",
            operationInput: "unused" as any Sendable,
            causeDescription: "cannot connect to host",
            underlyingError: URLError(.cannotConnectToHost)
        )
        let text = HumanError.describe(wrapped, host: "192.168.1.250")
        #expect(text == "Nothing answered at 192.168.1.250. Check the address, and that the "
                + "hub is powered on and on this network.")
    }

    @Test("a raw NSError transport dump is rejected, not shown verbatim")
    func rawTransportDumpIsRejected() {
        // A domain neither `URLError` nor `HubClient.ClientError` bridges
        // from — this is the shape a `ClientError`'s `description` (not its
        // `underlyingError`) produces if it were ever shown directly, and
        // the exact bug on the connect screen: the transport trace,
        // verbatim, on a phone.
        let dump = NSError(
            domain: "some.other.transport",
            code: -1004,
            userInfo: [NSLocalizedDescriptionKey: "Domain=NSURLErrorDomain Code=-1004 "
                       + "\"Could not connect to the server.\" UserInfo={...}"]
        )
        let text = HumanError.describe(dump)
        #expect(!text.contains("Domain="))
        #expect(!text.contains("UserInfo="))
        #expect(text == "Something went wrong talking to the hub.")
    }

    @Test("a genuinely human localizedDescription passes through")
    func humanLocalizedDescriptionPassesThrough() {
        let text = HumanError.describe(RuntimeErrorStandIn.unexpected)
        #expect(!text.isEmpty)
        #expect(!text.contains("Domain="))
    }
}

/// A stand-in underlying error: `OpenAPIRuntime.RuntimeError` is internal to
/// that module and cannot be constructed here, but any error works — the
/// `response`-present branch of `describe` never inspects it.
private enum RuntimeErrorStandIn: Error {
    case unexpected
}
