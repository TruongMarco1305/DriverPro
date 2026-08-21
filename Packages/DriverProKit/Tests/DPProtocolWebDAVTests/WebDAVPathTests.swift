//
//  WebDAVPathTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import Foundation
import Testing
@testable import DPProtocolWebDAV

@Suite("WebDAV paths")
struct WebDAVPathTests {

    private func makePaths(basePath: String = "", isSecure: Bool = true) throws -> WebDAVPaths {
        let host = RemoteHost(protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443,
                              username: "duck")
        return try #require(WebDAVPaths(host: host, basePath: basePath, isSecure: isSecure))
    }

    // MARK: - Building URLs

    @Test("The root is the base path, or a bare slash when there is none")
    func rootURL() throws {
        #expect(try makePaths().url(for: .root, isDirectory: true).absoluteString
                == "https://cloud.example.com/")
        #expect(try makePaths(basePath: "/remote.php/dav/files/duck")
                    .url(for: .root, isDirectory: true).absoluteString
                == "https://cloud.example.com/remote.php/dav/files/duck/")
    }

    @Test("A base path is accepted in any spelling")
    func basePathSpellings() throws {
        // A user typing the DAV root into a form will not be careful about slashes, and neither will a
        // `.duck` file written by someone else.
        let expected = "https://cloud.example.com/dav/a.txt"
        for spelling in ["/dav", "dav", "/dav/", "  /dav/  "] {
            #expect(try makePaths(basePath: spelling).url(for: RemotePath("/a.txt")).absoluteString
                    == expected, "failed for “\(spelling)”")
        }
    }

    @Test("A directory URL ends in a slash, a file's does not")
    func trailingSlash() throws {
        // Not cosmetic: a server may redirect a collection request that lacks the slash, and a redirect
        // loses the method — PROPFIND becomes GET and the reply is a web page instead of XML.
        let paths = try makePaths()
        #expect(paths.url(for: RemotePath("/srv"), isDirectory: true).absoluteString
                == "https://cloud.example.com/srv/")
        #expect(paths.url(for: RemotePath("/srv/a.txt")).absoluteString
                == "https://cloud.example.com/srv/a.txt")
    }

    @Test("Awkward names are percent-encoded, one component at a time")
    func encodesAwkwardNames() throws {
        let paths = try makePaths()

        #expect(paths.url(for: RemotePath("/a file.txt")).absoluteString
                == "https://cloud.example.com/a%20file.txt")
        // A `#` unencoded would start a fragment and the server would never see the rest of the name.
        #expect(paths.url(for: RemotePath("/notes#1.md")).absoluteString
                == "https://cloud.example.com/notes%231.md")
        // A literal `%` has to become `%25`, or the server decodes something that was never sent.
        #expect(paths.url(for: RemotePath("/100%.txt")).absoluteString
                == "https://cloud.example.com/100%25.txt")
    }

    @Test("A non-ASCII name survives")
    func encodesNonASCII() throws {
        let url = try makePaths().url(for: RemotePath("/日本語.txt"))
        #expect(url.absoluteString.contains("%E6%97%A5%E6%9C%AC%E8%AA%9E"))
    }

    @Test("The port is carried, and http is available for test servers")
    func schemeAndPort() throws {
        let host = RemoteHost(protocolIdentifier: .webdav, hostname: "localhost", port: 8080)
        let paths = try #require(WebDAVPaths(host: host, isSecure: false))
        #expect(paths.url(for: RemotePath("/a.txt")).absoluteString == "http://localhost:8080/a.txt")
    }

    // MARK: - Reading hrefs back

    @Test("An href comes back as the path it names, absolute or relative")
    func hrefToPath() throws {
        let paths = try makePaths(basePath: "/dav")

        // Servers differ on this and both spellings are legal.
        #expect(paths.path(fromHref: "/dav/srv/a.txt") == RemotePath("/srv/a.txt"))
        #expect(paths.path(fromHref: "https://cloud.example.com/dav/srv/a.txt")
                == RemotePath("/srv/a.txt"))
    }

    @Test("An href is decoded, so the name that comes back is the name that went out")
    func hrefIsDecoded() throws {
        let paths = try makePaths()

        #expect(paths.path(fromHref: "/a%20file.txt") == RemotePath("/a file.txt"))
        #expect(paths.path(fromHref: "/notes%231.md") == RemotePath("/notes#1.md"))
        #expect(paths.path(fromHref: "/100%25.txt") == RemotePath("/100%.txt"))
    }

    @Test("A collection's trailing slash is dropped — kind carries that, not the path")
    func collectionHref() throws {
        #expect(try makePaths().path(fromHref: "/srv/") == RemotePath("/srv"))
    }

    @Test("An href outside the DAV root belongs to someone else")
    func foreignHref() throws {
        // A server that redirects, or a multi-status listing something outside the tree, must not
        // produce a path that looks local and is not.
        #expect(try makePaths(basePath: "/dav").path(fromHref: "/other/a.txt") == nil)
    }

    @Test("Every name survives the round trip out and back")
    func roundTrip() throws {
        // The property that matters: whatever a server names a file, DriverPro asks for it by the same
        // name it displays. HTTP makes this sharper than SFTP, because the encoding is lossy if wrong.
        let paths = try makePaths(basePath: "/dav")
        let names = ["a.txt", "a file.txt", "notes#1.md", "100%.txt", "日本語.txt", "a+b.txt",
                     "quote'.txt", "amp&and.txt", "semi;colon.txt"]

        for name in names {
            let original = RemotePath("/srv/\(name)")
            let url = paths.url(for: original)
            let href = url.path(percentEncoded: true)

            #expect(paths.path(fromHref: href) == original, "“\(name)” did not survive")
        }
    }
}
