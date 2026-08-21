//
//  WebDAVSessionTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolWebDAV

/// A stubbed HTTP server, in process.
///
/// ## Swift note — `URLProtocol` as a seam
/// `URLSession` will hand every request to a `URLProtocol` subclass you register, which makes it the
/// place to intercept HTTP without a socket. The awkwardness is that `URLProtocol` is instantiated by
/// the system, so the stub's script cannot be passed in — it goes through a static, guarded by a lock.
///
/// The payoff is that request *shapes* — the verb, the `Depth` header, the URL — become ordinary
/// assertions rather than something only a live server can confirm, and they run in microseconds. It
/// does not replace `WebDAVIntegrationTests`: a stub proves the requests are shaped right, and only a
/// server proves they are understood. See `docs/swift-notes.md`, section 38.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    /// One canned answer.
    struct Response: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
    }

    /// What a request looked like, recorded for the test to inspect.
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [Response] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    /// Queues the answers a test expects to be asked for, in order, and forgets any earlier ones.
    static func script(_ responses: [Response]) {
        lock.lock()
        defer { lock.unlock() }
        answers = responses
        recorded = []
    }

    /// Every request that was sent, in order.
    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private static func next(for request: URLRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }

        // `httpBody` is nil by the time a request reaches a URLProtocol — URLSession has moved it to a
        // stream — so it is read back from there. Without this, "did we send the right XML?" is
        // unanswerable.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            body = collected
        }

        recorded.append(Recorded(
            method: request.httpMethod ?? "",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        ))
        return answers.isEmpty ? Response(status: 500) : answers.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.next(for: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status,
            httpVersion: "HTTP/1.1", headerFields: answer.headers
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("WebDAVSession", .serialized)
struct WebDAVSessionTests {

    private static let host = RemoteHost(
        protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443, username: "duck"
    )

    private func makeSession(host: RemoteHost = WebDAVSessionTests.host) throws -> WebDAVSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try #require(WebDAVSession(host: host, configuration: configuration))
    }

    private func connected(
        host: RemoteHost = WebDAVSessionTests.host,
        then answers: [StubURLProtocol.Response] = []
    ) async throws -> WebDAVSession {
        StubURLProtocol.script([.init(status: 207, body: MultiStatusFixture.apacheListing)] + answers)

        let session = try makeSession(host: host)
        try await session.connect(
            credentials: .password(username: "duck", password: "hunter2"),
            delegate: ScriptedDelegate()
        )
        return session
    }

    // MARK: - Connecting

    @Test("Connecting asks the server about the root, and nothing more")
    func connectProbesTheRoot() async throws {
        let session = try await connected()
        #expect(await session.isConnected)

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.method == "PROPFIND")
        #expect(request.url.absoluteString == "https://cloud.example.com/")
        // Depth 0: listing the whole top directory before anyone asked would be work nobody wanted.
        #expect(request.headers["Depth"] == "0")
    }

    @Test("Credentials are sent with the request rather than waiting to be challenged")
    func sendsBasicPreemptively() async throws {
        // WebDAV sends many small requests; paying a 401 round trip for each doubles every listing.
        _ = try await connected()

        let authorization = try #require(StubURLProtocol.requests.first?.headers["Authorization"])
        #expect(authorization == "Basic ZHVjazpodW50ZXIy")
    }

    @Test("A refused password fails the connection, and says which kind of refusal")
    func rejectedCredentials() async throws {
        StubURLProtocol.script([.init(status: 401)])
        let session = try makeSession()

        await #expect(throws: SessionError.self) {
            try await session.connect(
                credentials: .password(username: "duck", password: "wrong"),
                delegate: ScriptedDelegate()
            )
        }
        #expect(await !session.isConnected)
    }

    @Test("Nothing works before connecting")
    func operationsNeedAConnection() async throws {
        let session = try makeSession()
        await #expect(throws: SessionError.notConnected) {
            _ = try await session.list(.root)
        }
    }

    // MARK: - Listing

    @Test("A listing returns the children, and not the directory itself")
    func listDropsTheCollection() async throws {
        // A Depth 1 response always includes the collection that was asked about. Returning it would
        // show every folder containing itself.
        let session = try await connected(
            then: [.init(status: 207, body: MultiStatusFixture.apacheListing)]
        )
        let items = try await session.list(RemotePath("/srv"))

        #expect(items.map(\.name) == ["report.pdf", "photos"])
        #expect(items.map(\.isDirectory) == [false, true])
    }

    @Test("A listing asks with Depth 1, at a URL ending in a slash")
    func listRequestShape() async throws {
        let session = try await connected(
            then: [.init(status: 207, body: MultiStatusFixture.apacheListing)]
        )
        _ = try await session.list(RemotePath("/srv"))

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.method == "PROPFIND")
        #expect(request.headers["Depth"] == "1")
        // The slash matters: without it a server may redirect, and a redirect turns PROPFIND into GET.
        #expect(request.url.absoluteString == "https://cloud.example.com/srv/")
    }

    @Test("The request names the properties it wants rather than asking for all of them")
    func listAsksForNamedProperties() async throws {
        // `allprop` makes Nextcloud answer with dozens of its own properties per entry — a much larger
        // document to parse for information nothing reads.
        let session = try await connected(
            then: [.init(status: 207, body: MultiStatusFixture.apacheListing)]
        )
        _ = try await session.list(RemotePath("/srv"))

        let body = try #require(StubURLProtocol.requests.last?.body)
        let xml = String(decoding: body, as: UTF8.self)
        #expect(xml.contains("getcontentlength"))
        #expect(xml.contains("resourcetype"))
        #expect(!xml.contains("allprop"))
    }

    @Test("A listing under a DAV root maps hrefs back through the prefix")
    func listUnderBasePath() async throws {
        // The whole Nextcloud story in one test: the prefix is configuration, and paths above this
        // layer never see it.
        var host = Self.host
        host.properties[WebDAVSession.basePathKey] = "/remote.php/dav/files/duck"

        let session = try await connected(
            host: host,
            then: [.init(status: 207, body: MultiStatusFixture.nextcloudListing)]
        )
        let items = try await session.list(.root)

        #expect(items.map(\.path) == [RemotePath("/a file.txt")])
        #expect(StubURLProtocol.requests.last?.url.absoluteString
                == "https://cloud.example.com/remote.php/dav/files/duck/")
    }

    @Test("A missing directory is not found, by that name")
    func listMissingDirectory() async throws {
        let session = try await connected(then: [.init(status: 404)])

        await #expect(throws: SessionError.notFound(RemotePath("/nope"))) {
            _ = try await session.list(RemotePath("/nope"))
        }
    }

    // MARK: - Stat and exists

    @Test("Stat describes one entry")
    func statOneEntry() async throws {
        let single = Data("""
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/srv/report.pdf</D:href>
            <D:propstat><D:prop>
              <D:resourcetype/><D:getcontentlength>84213</D:getcontentlength>
            </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        </D:multistatus>
        """.utf8)

        let session = try await connected(then: [.init(status: 207, body: single)])
        let item = try await session.stat(RemotePath("/srv/report.pdf"))

        #expect(item.name == "report.pdf")
        #expect(item.size == 84_213)
        #expect(StubURLProtocol.requests.last?.headers["Depth"] == "0")
    }

    @Test("Exists answers yes or no rather than throwing")
    func existsAnswers() async throws {
        let session = try await connected(then: [
            .init(status: 207, body: MultiStatusFixture.apacheListing),
            .init(status: 404)
        ])

        #expect(await session.exists(RemotePath("/srv")))
        #expect(await !session.exists(RemotePath("/gone")))
    }

    // MARK: - Capabilities

    @Test("WebDAV's capabilities are its own, not SFTP's")
    func capabilitiesDiffer() throws {
        let session = try makeSession()

        // Cheaper than SFTP: the server does these itself.
        #expect(session.capabilities.contains(.rename))
        #expect(session.capabilities.contains(.serverSideCopy))
        #expect(session.capabilities.contains(.recursiveDelete))
        #expect(session.capabilities.contains(.resumeDownload))

        // Absent by protocol, not by omission.
        #expect(!session.capabilities.contains(.posixPermissions))
        #expect(!session.capabilities.contains(.timestamps))
        #expect(!session.capabilities.contains(.symbolicLinks))
        // The one that changes how transfers behave: there is no standard resumable PUT, so the queue
        // starts an interrupted upload again rather than appending to it.
        #expect(!session.capabilities.contains(.resumeUpload))
    }

    @Test("What WebDAV cannot do is refused cleanly, naming what is missing")
    func refusesUnsupportedOperations() async throws {
        let session = try await connected()

        await #expect(throws: SessionError.self) {
            try await session.setPermissions(POSIXPermissions(rawValue: 0o644), at: RemotePath("/a"))
        }
        await #expect(throws: SessionError.self) {
            try await session.setModificationDate(Date(), at: RemotePath("/a"))
        }
    }

    // MARK: - Status mapping

    @Test("HTTP statuses become errors a person can act on")
    func statusMapping() {
        let path = RemotePath("/a.txt")

        // 401 is "who are you" and 403 is "not you". Only the first is worth asking for a new password,
        // which is the difference `needsCredentials` carries.
        #expect(WebDAVTransport.mapStatus(401, path: path).needsCredentials)
        #expect(!WebDAVTransport.mapStatus(403, path: path).needsCredentials)

        #expect(WebDAVTransport.mapStatus(403, path: path) == .accessDenied(path))
        #expect(WebDAVTransport.mapStatus(404, path: path) == .notFound(path))
        #expect(WebDAVTransport.mapStatus(410, path: path) == .notFound(path))
        #expect(WebDAVTransport.mapStatus(507, path: path) == .insufficientStorage)
    }

    @Test("405 on a MKCOL means it is already there, not that the verb is wrong")
    func methodNotAllowedIsAlreadyExists() {
        // "Method not allowed" is not something a user can act on; "there is already a folder called
        // that" is.
        #expect(WebDAVTransport.mapStatus(405, path: RemotePath("/srv"))
                == .alreadyExists(RemotePath("/srv")))
    }

    @Test("409 means the parent is missing, which is the thing to say")
    func conflictNamesTheParent() {
        #expect(WebDAVTransport.mapStatus(409, path: RemotePath("/srv/deep/a.txt"))
                == .notFound(RemotePath("/srv/deep")))
    }
}
