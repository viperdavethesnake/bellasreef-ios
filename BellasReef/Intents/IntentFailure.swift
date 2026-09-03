// Bella's Reef iOS — closed source.

import AppIntents
import BellasReefKit
import Foundation

/// Everything an app intent can fail with, carrying the sentence a person
/// reads.
///
/// App Intents surfaces a thrown error to whoever ran the intent — Siri
/// speaks it, Shortcuts prints it in the run sheet — so the "errors are
/// sentences" rule applies here exactly as it does on a screen. Two
/// conformances, because those two surfaces read different properties:
/// `LocalizedError.errorDescription` backs the `localizedDescription` the
/// brief pins, and `CustomLocalizedStringResourceConvertible` is what App
/// Intents itself renders
/// (https://developer.apple.com/documentation/appintents/appintenterror).
///
/// Nothing here formats a raw error: the `.hub` case is handed text that has
/// already been through `HumanError.describe`, which is the one place allowed
/// to look at an error's own words.
enum IntentFailure: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    /// No credential on this device, so there is no hub to command.
    case notPaired
    /// The hub refused the hold, with the same wording the Lighting tab uses.
    case refused(HoldRefusal)
    /// Off the dial, or outside the durations the hub documents.
    case outOfRange(String)
    /// Anything else, already turned into a sentence by `HumanError.describe`.
    case hub(String)

    var message: String {
        switch self {
        case .notPaired:
            "This device isn't paired with a hub yet. Open Bella's Reef and connect first."
        case let .refused(refusal):
            refusal.message
        case let .outOfRange(detail):
            detail
        case let .hub(sentence):
            sentence
        }
    }

    var errorDescription: String? { message }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
