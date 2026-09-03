// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import UniformTypeIdentifiers

/// Which shape a history export is asked for in.
///
/// Hand-written rather than passing the generated
/// `Operations.HistoryExport.Input.Query.FormatPayload` around the app,
/// because the two facts a screen needs from a format — its file extension
/// and its uniform type — are client concerns the spec has no business
/// carrying. `wire` is a `switch` over the generated enum on purpose: rename
/// or remove a case in the contract and this stops compiling, which is the
/// only part of the mirroring a compiler can check. A case *added* to the
/// spec is a MINOR bump and arrives as a re-pin, not silently.
public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case csv, json

    public var id: String { rawValue }

    /// What the menu says.
    public var label: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        }
    }

    public var fileExtension: String { rawValue }

    /// What the share sheet uses to decide which destinations can take it.
    public var utType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        }
    }

    var wire: Operations.HistoryExport.Input.Query.FormatPayload {
        switch self {
        case .csv: .csv
        case .json: .json
        }
    }
}

/// One export, in memory, ready to be written somewhere and handed on.
///
/// Bytes rather than a URL because the wrapper has no business choosing where
/// a file lives — that is the presenting view's decision, and the Kit half
/// stays testable without touching the filesystem.
public struct ExportedFile: Sendable, Equatable {
    public let data: Data
    /// The hub's own `Content-Disposition` name when it sent one, otherwise
    /// the identical name built locally. See `ExportFilename`.
    public let suggestedFilename: String
    /// What this file is, declared rather than inferred.
    ///
    /// The History tab's presenter — `UIActivityViewController` over a file
    /// URL — reads the type off the extension and never asks for this, so
    /// today it is carried, not consumed. It is on the struct because a
    /// caller that hands over bytes instead of a path (`ShareLink(item:
    /// preview:)`, `fileExporter`) has to state the type, and because
    /// "csv means `public.comma-separated-values-text`" is a fact about the
    /// format that belongs beside the format, not inside whichever view
    /// shares it next.
    public let utType: UTType

    public init(data: Data, suggestedFilename: String, utType: UTType) {
        self.data = data
        self.suggestedFilename = suggestedFilename
        self.utType = utType
    }
}
