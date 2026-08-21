//
//  MultiStatusParser.swift
//  DPProtocolWebDAV
//

import DPCore
import Foundation

/// One entry from a `PROPFIND` response, before it becomes a ``RemoteItem``.
///
/// Kept as its own type because the parser's job ends at "what the XML said" — whether an entry is the
/// directory that was asked about or one of its children is a question about paths, not about XML.
struct MultiStatusEntry: Hashable, Sendable {

    /// The `<D:href>`, verbatim and still percent-encoded.
    var href: String = ""
    /// Whether `<D:resourcetype>` contained `<D:collection/>`.
    var isCollection = false
    /// `<D:getcontentlength>`, when the server sent one. Collections usually have none.
    var size: Int64?
    /// `<D:getlastmodified>`, parsed.
    var modifiedAt: Date?
    /// `<D:getcontenttype>`, kept for the extra metadata bag.
    var contentType: String?
    /// `<D:getetag>`, likewise — the closest WebDAV has to a version.
    var etag: String?
}

/// Reads a 207 Multi-Status document.
///
/// ## Swift note — `XMLParser` is a delegate, not a function
/// Foundation offers two ways to read XML on macOS. `XMLDocument` builds a tree and would be half this
/// code; `XMLParser` fires events as it goes. This uses the awkward one on purpose: a directory of ten
/// thousand entries is a single document, and M1's acceptance already requires that a large listing not
/// hang the browser. A tree of it would exist entirely in memory before the first row could be drawn.
///
/// The awkwardness is that `XMLParser` wants an `NSObject` delegate with mutable state, which is the
/// opposite of everything else in this package. It is confined here, behind one `static func`, and the
/// mutable state never leaves: `parse` returns values. See `docs/swift-notes.md`, section 37, for the
/// two traps this shape carries — prefixes, and text arriving in pieces.
enum MultiStatusParser {

    /// Parses a multi-status response body.
    ///
    /// - Parameter data: The XML the server sent.
    /// - Returns: One entry per `<D:response>`, in document order.
    /// - Throws: ``SessionError/protocolViolation(_:)`` if the document is not XML at all.
    static func parse(_ data: Data) throws -> [MultiStatusEntry] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = true      // servers spell the DAV namespace as D:, d:, or nothing

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            throw SessionError.protocolViolation("The server's response could not be read: \(reason)")
        }
        return collector.entries
    }

    /// Accumulates entries as the parser walks the document.
    ///
    /// `@unchecked Sendable` with a narrow justification: it is created, used and dropped inside
    /// ``parse(_:)``, `XMLParser.parse()` is synchronous, and no reference to it escapes that call. The
    /// compiler cannot see that; this comment is the argument it would need.
    private final class Collector: NSObject, XMLParserDelegate, @unchecked Sendable {

        private(set) var entries: [MultiStatusEntry] = []

        private var current: MultiStatusEntry?
        private var text = ""
        /// `<D:resourcetype>` is a container, so `<D:collection/>` inside it must not be confused with a
        /// `collection` element anywhere else.
        private var isInResourceType = false
        /// Only `<D:propstat>` blocks with a 2xx status describe properties that exist; a 404 propstat
        /// lists the ones the server does *not* have, and reading those would report every optional
        /// property as present but empty.
        private var propstatStatus: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            text = ""

            switch elementName.lowercased() {
            case "response":
                current = MultiStatusEntry()
            case "propstat":
                propstatStatus = nil
            case "resourcetype":
                isInResourceType = true
            case "collection" where isInResourceType:
                current?.isCollection = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""

            switch elementName.lowercased() {
            case "href":
                // Only the response's own href, not one inside a nested property.
                if current?.href.isEmpty == true { current?.href = value }
            case "status":
                propstatStatus = value
            case "resourcetype":
                isInResourceType = false
            case "getcontentlength" where isFound:
                current?.size = Int64(value)
            case "getlastmodified" where isFound:
                current?.modifiedAt = date(from: value)
            case "getcontenttype" where isFound:
                current?.contentType = value.isEmpty ? nil : value
            case "getetag" where isFound:
                current?.etag = value.isEmpty ? nil : value
            case "response":
                if let current, !current.href.isEmpty { entries.append(current) }
                current = nil
            default:
                break
            }
        }

        /// Whether the properties being read belong to a `propstat` the server said it has.
        ///
        /// Absent status means the server did not send one, which is technically a violation and in
        /// practice means "these exist" — refusing them would lose entries to a formatting quibble.
        private var isFound: Bool {
            guard let propstatStatus else { return true }
            return propstatStatus.contains(" 200 ") || propstatStatus.contains(" 2")
        }

        /// `getlastmodified` is RFC 1123, in English, regardless of anyone's locale.
        ///
        /// An instance property rather than a `static`, for two reasons that happen to agree.
        /// `DateFormatter` is not `Sendable`, so Swift 6 refuses to let one be shared; and building it
        /// is expensive enough that a per-*entry* formatter would be felt on a large listing. One per
        /// parse is both safe and cheap.
        private let rfc1123: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        /// ISO 8601, which some servers send instead despite the specification saying otherwise.
        private let iso8601 = ISO8601DateFormatter()

        private func date(from value: String) -> Date? {
            rfc1123.date(from: value) ?? iso8601.date(from: value)
        }
    }
}

extension MultiStatusEntry {

    /// Turns an entry into a listing row.
    ///
    /// - Parameter path: Where it lives, already mapped back from the `href`.
    /// - Returns: The item, with the metadata WebDAV actually provides and nothing invented.
    func makeItem(at path: RemotePath) -> RemoteItem {
        var extra: [String: String] = [:]
        if let etag { extra["webdav.etag"] = etag }
        if let contentType { extra["webdav.contentType"] = contentType }

        // No permissions, no owner, no group: WebDAV has none of them, and reporting a plausible-looking
        // default would be inventing data. `SessionCapabilities` says so, and the UI greys out what it
        // cannot offer rather than showing blanks that look like a bug.
        return RemoteItem(
            path: path,
            kind: isCollection ? .directory : .file,
            size: size,
            modifiedAt: modifiedAt,
            extra: extra
        )
    }
}
