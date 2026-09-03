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
    ///
    /// `host`, when the caller has one — the pairing card knows
    /// `hub.baseURL.host` before it knows anything else about the hub — is
    /// folded into the handful of `URLError` cases where naming the address
    /// is the actionable part of the sentence. Callers that never had a host
    /// in scope (a threshold save, once already connected) omit it and get
    /// the address-shaped phrasing without a name in it.
    public static func describe(_ error: any Error, host: String? = nil) -> String {
        // swift-openapi-runtime's own error: unwrap it rather than showing
        // its `description`, which prints operationID, request, response and
        // body verbatim — precisely the raw dump this type exists to hide.
        if let clientError = error as? ClientError {
            if let status = clientError.response?.status.code {
                return "The hub answered with an error (code \(status))."
            }
            return describe(clientError.underlyingError, host: host)
        }
        // `HubClient.ClientError`'s cases already carry a short, hub-authored
        // sentence (a validation reason from the hub, or a fixed phrase) —
        // that is the specific, useful half of "errors are sentences", not
        // something to collapse into the generic case below.
        if let hubError = error as? HubClient.ClientError {
            return hubError.description
        }
        // `StreamClient.StreamError`'s cases are the same idiom as
        // `HubClient.ClientError`'s — a short, hand-authored sentence, not a
        // transport dump — so it gets the same direct pass-through rather
        // than falling to `localizedDescription` below, where Swift's
        // default `Error`-to-`NSError` bridge would replace it with the
        // generic "The operation couldn't be completed..." text.
        if let streamError = error as? StreamClient.StreamError {
            return streamError.description
        }
        // A body larger than the cap its caller allowed — in this app, a
        // history export past `HubClient`'s 32 MB CSV limit. Without this the
        // banner reads "OpenAPIRuntime.HTTPBody contains more than the maximum
        // allowed 33554432 bytes.", which names a library and a byte count and
        // no action, and which `looksLikeADump` does not catch because it is
        // grammatical English.
        if isOverBodyCap(error) {
            return "This export is larger than the app can hold. Try a shorter range."
        }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost:
                let where_ = host.map { "at \($0)" } ?? "there"
                return "Nothing answered \(where_). Check the address, and that the hub is "
                    + "powered on and on this network."
            case .cannotFindHost:
                let what = host.map { "\($0)" } ?? "that address"
                return "Could not find \(what) on this network. Check that it's typed correctly."
            case .dnsLookupFailed:
                let what = host.map { "\($0)" } ?? "that address"
                return "Could not look up \(what). Check that it's typed correctly."
            case .networkConnectionLost:
                return "The connection to the hub dropped partway through. Try again."
            case .timedOut:
                return "The hub did not answer in time. Check that this device is on the "
                    + "tank's network."
            case .notConnectedToInternet:
                return "This device has no network connection. Check Wi-Fi and try again."
            default:
                break
            }
        }
        // Anything else: the error's own words, but only when they already
        // read as one human sentence — the same "Domain=/UserInfo=" shape
        // that this type exists to keep off a screen can arrive wrapped in
        // ways the cases above don't unwrap (a POSIXError, a raw NSError).
        // Heuristic, not a parser: reject anything that smells like a
        // transport dump and fall back to the generic line.
        let described = error.localizedDescription
        if !described.isEmpty, !looksLikeADump(described) {
            return described
        }
        return "Something went wrong talking to the hub."
    }

    /// True for swift-openapi-runtime's over-the-cap error from
    /// `Data(collecting:upTo:)`.
    ///
    /// Matched on its text, which is not the usual way to identify an error
    /// and is the only way available here: the type is
    /// `HTTPBody.TooManyBytesError`, declared `private` inside the runtime, so
    /// it cannot be named in an `as?`. Its `description` is a fixed English
    /// sentence with only the byte count interpolated, so the prefix is a
    /// stable handle.
    ///
    /// `contains` rather than `hasPrefix` because the same error can arrive
    /// wrapped — `UniversalClient` boxes anything a middleware throws in its
    /// own `RuntimeError` before a call site sees it, and `String(describing:)`
    /// of that still carries this sentence inside. A false negative just falls
    /// through to the raw text this replaces, which is where it would have
    /// landed anyway.
    private static func isOverBodyCap(_ error: any Error) -> Bool {
        String(describing: error)
            .contains("OpenAPIRuntime.HTTPBody contains more than the maximum allowed")
    }

    /// True for text that reads like an `NSError` transport dump rather than
    /// a sentence a person wrote — the shape this whole type exists to keep
    /// off a screen. Not exhaustive by design: a false negative just falls
    /// through to `localizedDescription` verbatim, a false positive falls
    /// back to the generic line, and both are the safe direction to be
    /// wrong in.
    private static func looksLikeADump(_ text: String) -> Bool {
        text.contains("Domain=") || text.contains("UserInfo=") || text.contains("Code=")
    }
}
