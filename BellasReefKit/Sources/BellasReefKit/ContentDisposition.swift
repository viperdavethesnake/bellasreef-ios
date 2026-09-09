// Bella's Reef iOS — closed source.

import Foundation

/// Reads the filename out of a `Content-Disposition` header.
///
/// Not a general RFC 6266 parser. It handles the two forms a server might
/// plausibly send for this endpoint — `filename="x.csv"` and `filename=x.csv`
/// — and deliberately declines the RFC 5987 `filename*=UTF-8''…` form rather
/// than half-implementing a percent/charset decoder: returning `nil` there
/// falls back to `ExportFilename.build`, which is exact.
public enum ContentDisposition {

    /// The filename, or `nil` when the header is absent, names nothing, or
    /// names something that would not be a safe file name.
    public static func filename(from header: String?) -> String? {
        guard let header else { return nil }

        for parameter in header.split(separator: ";").dropFirst() {
            let halves = parameter.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            // Exact match, lowercased: `filename*` must not answer here, and
            // it does not, because the key is compared whole.
            guard halves[0].trimmingCharacters(in: .whitespaces).lowercased() == "filename" else {
                continue
            }

            var value = halves[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            // The value is about to become a path in the temporary directory
            // and it came off the network. Reducing it to a last path
            // component is what stops it naming anywhere else. This hub's
            // device ids are `[a-z0-9_-]{1,64}` and could not produce a
            // separator, so this guards a case that cannot happen from *this*
            // server — which is the only kind of guard worth having on a
            // filename.
            let name = (value as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            return name
        }
        return nil
    }
}
