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
        #expect(text == "The hub did not answer. Check that this device is on the tank's network.")
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
}

/// A stand-in underlying error: `OpenAPIRuntime.RuntimeError` is internal to
/// that module and cannot be constructed here, but any error works — the
/// `response`-present branch of `describe` never inspects it.
private enum RuntimeErrorStandIn: Error {
    case unexpected
}
