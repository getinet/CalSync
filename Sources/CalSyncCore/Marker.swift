import Foundation

/// Identity for a mirrored "Busy" block.
///
/// A block is *self-describing*: it stores its own identity in the event's `url`
/// field, so every run rederives all state by reading both calendars. There is no
/// external state file, which makes the whole system idempotent and self-healing.
public enum Marker {
    public static let scheme = "x-calsync://"

    /// A source event whose title contains this marker is opted out of syncing.
    public static let excludeMarker = "🚫"

    /// ISO-8601 in UTC. Used *only* to build marker strings — never for comparison.
    /// `ISO8601FormatStyle` is a Sendable value type, unlike `ISO8601DateFormatter`,
    /// so it can safely be shared across concurrency domains.
    private static let isoStyle = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)

    public static func isoString(_ date: Date) -> String { isoStyle.format(date) }

    /// Single event  → `x-calsync://<uid>`            (time-independent: a moved event keeps its marker)
    /// Recurring one → `x-calsync://<uid>/<occStart>` (a moved occurrence gets a new marker)
    public static func encode(uid: String, occurrenceStart: Date?, isRecurring: Bool) -> String {
        // Percent-encode the uid so a slash inside it cannot be mistaken for the
        // separator. Without this, uid "a/b" and uid "a" + occurrence "b" collide.
        let encoded = uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uid
        if isRecurring, let occurrenceStart {
            return scheme + encoded + "/" + isoString(occurrenceStart)
        }
        return scheme + encoded
    }

    public struct Parsed: Equatable, Sendable {
        public let uid: String
        public let occurrenceStartISO: String?
    }

    /// Returns nil for anything that is not one of our markers — including malformed
    /// percent-encoding, which must not throw.
    public static func parse(_ url: String?) -> Parsed? {
        guard let url, url.hasPrefix(scheme) else { return nil }
        let rest = String(url.dropFirst(scheme.count))
        // Split on the LAST slash: the uid is percent-encoded (so contains no raw
        // slash), and the occurrence ISO string contains none either.
        guard let slash = rest.lastIndex(of: "/") else {
            guard let uid = String(rest).removingPercentEncoding else { return nil }
            return uid.isEmpty ? nil : Parsed(uid: uid, occurrenceStartISO: nil)
        }
        let uidPart = String(rest[rest.startIndex..<slash])
        let occPart = String(rest[rest.index(after: slash)...])
        guard let uid = uidPart.removingPercentEncoding, !uid.isEmpty else { return nil }
        return Parsed(uid: uid, occurrenceStartISO: occPart)
    }

    /// Loop backstop #1: an event carrying a CalSync marker is a block *we* wrote, so it
    /// must never be read back as a source event.
    public static func isCalSyncBlock(url: String?) -> Bool {
        parse(url) != nil
    }

    /// Loop backstop #2, for when the two calendars block each other directly (one
    /// side's destination is the other side's source).
    ///
    /// Backstop #1 depends on the event's URL surviving a round trip through the
    /// calendar server, and not every CalDAV implementation preserves it. If a marker
    /// were stripped, the block would look like an ordinary event, get mirrored back,
    /// lose *its* marker, and multiply without limit. Matching on the block title too
    /// makes that impossible.
    ///
    /// The cost is small and worth stating plainly: a real event titled exactly "Busy"
    /// is not mirrored.
    public static func looksLikeBlockTitle(_ title: String?, busyTitle: String) -> Bool {
        guard let title else { return false }
        let normalise = { (s: String) in
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let candidate = normalise(title)
        return !candidate.isEmpty && candidate == normalise(busyTitle)
    }

    public static func titleIsExcluded(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.contains(excludeMarker)
    }
}
