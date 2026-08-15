// Bella's Reef iOS — closed source.

import Foundation
import OpenAPIRuntime

/// The one error-presentation idiom (ledger: there used to be two — a raw
/// `"\(error)"` dump in some places, `.localizedDescription` in others.
/// Neither tells an operator what to do, and the first one is a full
/// transport trace on a phone screen). Raw errors go to the log; people get
/// a sentence.
public enum HumanError {

    /// True for a cancellation the app itself caused: `CancellationError`,
    /// `URLError.cancelled`, or NSURLErrorDomain −999, however deep it is
    /// wrapped.
    ///
    /// swift-openapi-runtime wraps every transport-level failure — including
    /// a cancelled `URLSessionTask` — in its own `ClientError`, and that type
    /// is a plain struct, not `NSError`-bridged with the underlying error
    /// reachable via `NSUnderlyingErrorKey`. Bridging `ClientError` to
    /// `NSError` and walking `userInfo` finds nothing: it has to be unwrapped
    /// explicitly via `underlyingError` before the NSError walk has anything
    /// to look at. Confirmed by writing the wrapped-`ClientError` test first,
    /// as this was not going to be right by inspection alone.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let clientError = error as? ClientError {
            return isCancellation(clientError.underlyingError)
        }
        var next: (any Error)? = error
        while let current = next {
            let ns = current as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return true
            }
            next = ns.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return false
    }

    /// One short sentence for a screen. The full error belongs at the call
    /// site's log line, never here.
    public static func describe(_ error: any Error) -> String {
        // swift-openapi-runtime's own error: unwrap it rather than showing
        // its `description`, which prints operationID, request, response and
        // body verbatim — precisely the raw dump this type exists to hide.
        if let clientError = error as? ClientError {
            if let status = clientError.response?.status.code {
                return "The hub answered with an error (code \(status))."
            }
            return describe(clientError.underlyingError)
        }
        // `HubClient.ClientError`'s cases already carry a short, hub-authored
        // sentence (a validation reason from the hub, or a fixed phrase) —
        // that is the specific, useful half of "errors are sentences", not
        // something to collapse into the generic case below.
        if let hubError = error as? HubClient.ClientError {
            return hubError.description
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .timedOut, .dnsLookupFailed:
                return "The hub did not answer. Check that this device is on the tank's network."
            default:
                break
            }
        }
        return "Something went wrong talking to the hub."
    }
}
