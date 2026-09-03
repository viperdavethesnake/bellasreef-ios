// Bella's Reef iOS — closed source.

import Foundation

/// The name the hub would have given an export, built here.
///
/// A mirror of `history_export`'s own stem in
/// `services/api/bellasreef_api/app.py`:
///
/// ```python
/// stem = (
///     f"bellasreef-{device_id}"
///     f"-{start.astimezone(UTC).strftime('%Y%m%dT%H%MZ')}"
///     f"-{end.astimezone(UTC).strftime('%Y%m%dT%H%MZ')}"
/// )
/// ```
///
/// It exists because the 4.4.0 spec documents the `Content-Disposition`
/// header in prose but does not *declare* it, so a client cannot rely on the
/// generated types to carry it (see `ContentDisposition`). When the header is
/// there it wins; this is what the file is called when it is not, and the two
/// agree character for character today — which is the property
/// `ExportFilenameTests` pins.
public enum ExportFilename {

    public static func build(
        deviceId: String, start: Date, end: Date, format: ExportFormat
    ) -> String {
        "bellasreef-\(deviceId)-\(stamp(start))-\(stamp(end)).\(format.fileExtension)"
    }

    /// `%Y%m%dT%H%MZ`, in UTC.
    ///
    /// UTC because the backend converts before it formats, and the app's
    /// window is `now - duration ... now` in whatever zone the phone is in —
    /// a formatter left on the device's zone would name a different day for
    /// half of every evening.
    ///
    /// Built per call rather than shared: `DateFormatter` is a class with
    /// mutable state and is not `Sendable`, the same reason
    /// `FractionalSecondsDateTranscoder` builds its formatter per call. Two
    /// of these per export is not a hot path.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        // POSIX locale, or a device set to a non-Gregorian calendar formats
        // the year in it.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmm'Z'"
        return formatter.string(from: date)
    }
}
