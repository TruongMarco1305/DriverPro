//
//  MultiStatusParserTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import Foundation
import Testing
@testable import DPProtocolWebDAV

/// Multi-status documents in the shapes real servers send them.
///
/// Written out rather than bundled, so the test is also the documentation of what comes back — and so
/// the differences between servers are visible side by side rather than hidden in fixture files.
enum MultiStatusFixture {

    /// Apache `mod_dav`: the `D:` prefix, RFC 1123 dates, and a second `propstat` listing the properties
    /// it does *not* have.
    static let apacheListing = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/srv/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <D:getlastmodified>Tue, 19 Aug 2026 10:15:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        <D:propstat>
          <D:prop>
            <D:getcontentlength/>
            <D:getetag/>
          </D:prop>
          <D:status>HTTP/1.1 404 Not Found</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/srv/report.pdf</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength>84213</D:getcontentlength>
            <D:getlastmodified>Mon, 18 Aug 2026 09:00:00 GMT</D:getlastmodified>
            <D:getcontenttype>application/pdf</D:getcontenttype>
            <D:getetag>"abc123"</D:getetag>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/srv/photos/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """.utf8)

    /// Nextcloud: a lowercase `d:` prefix, its own namespace mixed in, and percent-encoded hrefs under
    /// a DAV root that is not `/`.
    static let nextcloudListing = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/duck/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/></d:resourcetype>
            <d:getlastmodified>Wed, 20 Aug 2026 12:00:00 GMT</d:getlastmodified>
            <oc:size>1048576</oc:size>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/duck/a%20file.txt</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength>12</d:getcontentlength>
            <d:getlastmodified>Wed, 20 Aug 2026 12:30:00 GMT</d:getlastmodified>
            <d:getetag>&quot;5f2b&quot;</d:getetag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """.utf8)

    /// Captured verbatim from Apache `mod_dav` — not written from the specification.
    ///
    /// The reason to capture rather than compose: Apache binds the **same namespace to three different
    /// prefixes in one document**. `D:response` and `lp1:resourcetype` and `g0:getcontentlength` are all
    /// `DAV:`. A parser matching element names by prefix would read this as an empty listing and pass
    /// every hand-written fixture while failing against the reference implementation.
    static let apacheCaptured = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
    <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/" xmlns:g0="DAV:">
    <D:href>/</D:href>
    <D:propstat>
    <D:prop>
    <lp1:resourcetype><D:collection/></lp1:resourcetype>
    <lp1:getlastmodified>Fri, 14 Dec 2018 15:10:12 GMT</lp1:getlastmodified>
    <lp1:getetag>"0-57cfcd3e29d00"</lp1:getetag>
    </D:prop>
    <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    <D:propstat>
    <D:prop>
    <g0:getcontentlength/>
    </D:prop>
    <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
    </D:response>
    </D:multistatus>
    """.utf8)

    /// A server that sends no namespace prefix at all, which is legal and which a prefix-matching
    /// parser would read as an empty listing.
    static let unprefixedListing = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <multistatus xmlns="DAV:">
      <response>
        <href>/a.txt</href>
        <propstat>
          <prop>
            <resourcetype/>
            <getcontentlength>7</getcontentlength>
          </prop>
          <status>HTTP/1.1 200 OK</status>
        </propstat>
      </response>
    </multistatus>
    """.utf8)
}

@Suite("MultiStatusParser")
struct MultiStatusParserTests {

    @Test("A directory, a file and a subdirectory come back in order")
    func parsesApacheListing() throws {
        let entries = try MultiStatusParser.parse(MultiStatusFixture.apacheListing)

        #expect(entries.count == 3)
        #expect(entries.map(\.href) == ["/srv/", "/srv/report.pdf", "/srv/photos/"])
        #expect(entries.map(\.isCollection) == [true, false, true])
    }

    @Test("A file's size, date, type and etag are read")
    func readsFileProperties() throws {
        let file = try #require(
            MultiStatusParser.parse(MultiStatusFixture.apacheListing)
                .first { $0.href == "/srv/report.pdf" }
        )

        #expect(file.size == 84_213)
        #expect(file.contentType == "application/pdf")
        #expect(file.etag == "\"abc123\"")
        // Built from components rather than an epoch: an RFC 1123 date is what the server sent, and a
        // hand-computed number is a second thing that can be wrong.
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 18
        components.hour = 9; components.minute = 0; components.second = 0
        components.timeZone = TimeZone(identifier: "GMT")

        #expect(file.modifiedAt == Calendar(identifier: .gregorian).date(from: components))
    }

    @Test("Properties in a 404 propstat are not read as present but empty")
    func ignoresNotFoundPropstat() throws {
        // Apache lists the properties it does *not* have in a second propstat. Reading those would
        // report every optional property as present, and a directory would claim a size of nothing.
        let directory = try #require(
            MultiStatusParser.parse(MultiStatusFixture.apacheListing).first
        )

        #expect(directory.isCollection)
        #expect(directory.size == nil, "a 404 propstat means the server has no such property")
        #expect(directory.etag == nil)
    }

    @Test("A collection with no properties at all still parses")
    func sparseCollection() throws {
        let photos = try #require(
            MultiStatusParser.parse(MultiStatusFixture.apacheListing).last
        )

        #expect(photos.isCollection)
        #expect(photos.size == nil)
        #expect(photos.modifiedAt == nil, "absent is absent — not 1970")
    }

    @Test("A lowercase prefix and a foreign namespace are read the same way")
    func parsesNextcloudListing() throws {
        // `shouldProcessNamespaces` is what makes this work: servers spell DAV as `D:`, `d:` or nothing,
        // and Nextcloud mixes two more namespaces into the same document.
        let entries = try MultiStatusParser.parse(MultiStatusFixture.nextcloudListing)

        #expect(entries.count == 2)
        #expect(entries[0].isCollection)
        #expect(entries[1].size == 12)
        #expect(entries[1].etag == "\"5f2b\"", "the entity is decoded, quotes and all")
    }

    @Test("A document with no prefix at all still parses")
    func parsesUnprefixedListing() throws {
        let entries = try MultiStatusParser.parse(MultiStatusFixture.unprefixedListing)

        #expect(entries.count == 1)
        #expect(entries[0].href == "/a.txt")
        #expect(entries[0].size == 7)
    }

    @Test("A response captured from Apache parses, prefixes and all")
    func parsesCapturedApacheResponse() throws {
        // The one fixture that is evidence rather than construction. `shouldProcessNamespaces` is what
        // makes it work: three prefixes, one namespace, and the parser reads local names.
        let entries = try MultiStatusParser.parse(MultiStatusFixture.apacheCaptured)

        let root = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(root.href == "/")
        #expect(root.isCollection, "read through the lp1: prefix")
        #expect(root.etag == "\"0-57cfcd3e29d00\"")
        #expect(root.modifiedAt != nil)
        #expect(root.size == nil, "the g0:getcontentlength was in a 404 propstat")
    }

    @Test("Something that is not XML says so, rather than returning nothing")
    func rejectsJunk() {
        // An empty listing and a broken server must not look the same: one is a directory with no
        // files in it, the other is a problem to report.
        #expect(throws: SessionError.self) {
            try MultiStatusParser.parse(Data("<html><body>404 Not Found</body>".utf8))
        }
    }

    // MARK: - Becoming items

    @Test("An entry becomes an item with what WebDAV has, and nothing invented")
    func makesItems() throws {
        let entries = try MultiStatusParser.parse(MultiStatusFixture.apacheListing)
        let file = try #require(entries.first { $0.href == "/srv/report.pdf" })

        let item = file.makeItem(at: RemotePath("/srv/report.pdf"))
        #expect(item.kind == .file)
        #expect(item.size == 84_213)
        #expect(item.extra["webdav.etag"] == "\"abc123\"")

        // WebDAV has no permissions, owner or group. Reporting plausible defaults would be inventing
        // data; `SessionCapabilities` says they are unavailable and the UI greys them out.
        #expect(item.permissions == nil)
        #expect(item.owner == nil)
        #expect(item.group == nil)
    }

    @Test("A collection becomes a directory, and a directory has no size")
    func collectionsBecomeDirectories() throws {
        let entries = try MultiStatusParser.parse(MultiStatusFixture.apacheListing)
        let item = try #require(entries.first).makeItem(at: RemotePath("/srv"))

        #expect(item.isDirectory)
        #expect(item.size == nil)
    }
}
