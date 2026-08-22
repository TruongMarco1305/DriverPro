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

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
            .init(status: 404),
        ])

        #expect(await session.exists(RemotePath("/srv")))
        #expect(await !session.exists(RemotePath("/gone")))
    }

    // MARK: - Changing the namespace

    @Test("Creating a directory is a MKCOL with no body, at a URL ending in a slash")
    func createDirectoryShape() async throws {
        let session = try await connected(then: [.init(status: 201)])
        try await session.createDirectory(RemotePath("/srv/new"))

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.method == "MKCOL")
        #expect(request.url.absoluteString == "https://cloud.example.com/srv/new/")
        #expect(request.body?.isEmpty ?? true, "MKCOL takes no body")
    }

    @Test("A rename sends an absolute Destination and refuses to overwrite")
    func moveShape() async throws {
        // Without `Overwrite: F` a rename onto an existing name silently replaces it, and the contract's
        // promise that renaming leaves nothing behind would hold for the wrong reason.
        let session = try await connected(then: [.init(status: 201)])
        try await session.move(RemotePath("/srv/before.txt"), to: RemotePath("/srv/after.txt"))

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.method == "MOVE")
        #expect(request.headers["Destination"] == "https://cloud.example.com/srv/after.txt",
                "the specification requires an absolute destination")
        #expect(request.headers["Overwrite"] == "F")
    }

    @Test("Deleting is one request, whatever is there")
    func deleteShape() async throws {
        // `DELETE` on a collection is recursive by RFC 4918 — one request removes a whole tree, which is
        // why `recursiveDelete` is advertised and why nothing walks the tree first.
        let session = try await connected(then: [.init(status: 204)])
        try await session.delete(RemotePath("/srv/tree"))

        #expect(StubURLProtocol.requests.last?.method == "DELETE")
        #expect(StubURLProtocol.requests.count == 2, "connect, then the delete — nothing enumerated")
    }

    // MARK: - Moving bytes

    @Test("A read from the start sends no Range header")
    func readWithoutOffset() async throws {
        let session = try await connected(then: [.init(status: 200, body: Data("hello".utf8))])

        var received = Data()
        for try await chunk in try await session.read(RemotePath("/srv/a.txt"), from: 0) {
            received.append(chunk)
        }

        #expect(received == Data("hello".utf8))
        #expect(StubURLProtocol.requests.last?.headers["Range"] == nil)
    }

    @Test("A read from an offset asks for the rest of the file")
    func readWithOffset() async throws {
        let session = try await connected(then: [.init(status: 206, body: Data("world".utf8))])

        var received = Data()
        for try await chunk in try await session.read(RemotePath("/srv/a.txt"), from: 6) {
            received.append(chunk)
        }

        #expect(received == Data("world".utf8))
        #expect(StubURLProtocol.requests.last?.headers["Range"] == "bytes=6-")
    }

    @Test("A server that rejects an upload before reading it is reported, not waited for", .timeLimit(.minutes(1)))
    func writeReportsAnEarlyRejection() async throws {
        // A server may answer before the body has been sent — a 401, a 403, a 507, or a proxy refusing
        // the encoding. That is what a strict server does rather than swallow a gigabyte it means to
        // reject, and the answer is the only thing that says what went wrong.
        //
        // Before the fix this hung: the response arrived, and the code then waited for a body pump
        // writing into a stream nobody was reading any more.
        let session = try await connected(then: [.init(status: 401)])

        // The server's reason, not a transport error about a stream: a 401 has to reach the user as
        // "the password was refused", or the retry that would fix it never happens.
        await #expect(throws: SessionError.authenticationFailed(
            reason: "The server rejected the user name or password."
        )) {
            try await session.write(RemotePath("/srv/big.bin"),
                                    contents: SessionContract.stream(Data(repeating: 0, count: 2_000_000),
                                                                     chunkSize: 16_384),
                                    size: 2_000_000, resumingAt: 0)
        }
    }

    @Test("An upload the server accepts without draining still succeeds", .timeLimit(.minutes(1)))
    func writeSucceedsWhenTheServerStopsReading() async throws {
        // The other half of the same mistake: a pump error must not fail an upload the server accepted.
        // A server that has what it needs may stop reading, which makes the pump report a closed stream.
        let session = try await connected(then: [.init(status: 201)])

        try await session.write(RemotePath("/srv/big.bin"),
                                contents: SessionContract.stream(Data(repeating: 0, count: 2_000_000),
                                                                 chunkSize: 16_384),
                                size: 2_000_000, resumingAt: 0)
    }

    @Test("An upload sends a PUT with the size it was given")
    func writeShape() async throws {
        // Without `Content-Length`, URLSession falls back to chunked transfer encoding, which some
        // servers and reverse proxies refuse outright.
        let session = try await connected(then: [.init(status: 201)])
        let payload = Data("hello".utf8)

        try await session.write(RemotePath("/srv/a.txt"),
                                contents: SessionContract.stream(payload),
                                size: Int64(payload.count), resumingAt: 0)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.method == "PUT")
        #expect(request.body == payload, "every chunk reaches the wire, in order")

        // `Content-Length` is a header URLSession reserves the right to manage, so this checks it is
        // still there once URLSession has handed the request over. What it cannot check is which
        // encoding the socket then uses — that is not observable from a URLProtocol.
        #expect(request.headers["Content-Length"] == String(payload.count))
    }

    @Test("An upload asked to resume refuses rather than starting over quietly")
    func writeRefusesAnOffset() async throws {
        let session = try await connected()

        await #expect(throws: SessionError.unsupported(.resumeUpload, operation: "resuming an upload")) {
            try await session.write(RemotePath("/srv/a.txt"),
                                    contents: SessionContract.stream(Data("x".utf8)),
                                    size: 1, resumingAt: 50)
        }
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
        #expect(WebDAVTransport.mapStatus(401, path: path, method: .get).needsCredentials)
        #expect(!WebDAVTransport.mapStatus(403, path: path, method: .get).needsCredentials)

        #expect(WebDAVTransport.mapStatus(403, path: path, method: .get) == .accessDenied(path))
        #expect(WebDAVTransport.mapStatus(404, path: path, method: .get) == .notFound(path))
        #expect(WebDAVTransport.mapStatus(410, path: path, method: .get) == .notFound(path))
        #expect(WebDAVTransport.mapStatus(507, path: path, method: .put) == .insufficientStorage)
    }

    @Test("405 on a MKCOL means it is already there, not that the verb is wrong")
    func methodNotAllowedIsAlreadyExists() {
        // "Method not allowed" is not something a user can act on; "there is already a folder called
        // that" is.
        #expect(WebDAVTransport.mapStatus(405, path: RemotePath("/srv"), method: .mkcol)
                == .alreadyExists(RemotePath("/srv")))
    }

    @Test("405 on a PROPFIND says the address does not speak WebDAV, not that it exists")
    func methodNotAllowedOnPropfindNamesTheRealProblem() {
        // Reported from the app: connecting to a Nextcloud without its DAV root said "/ already
        // exists." Nextcloud's web front end answers 405 to a PROPFIND, and 405 was mapped to
        // `alreadyExists` for every verb — so the one message the user got was both meaningless and
        // wrong. The fix they need is the WebDAV Path, so the error says so.
        let error = WebDAVTransport.mapStatus(405, path: .root, method: .propfind)

        guard case .protocolViolation(let reason) = error else {
            Issue.record("405 on a PROPFIND should not be \(error)")
            return
        }
        #expect(reason.contains("WebDAV Path"), "the message must name the field that fixes it")
        #expect(!reason.contains("already exists"))
    }

    @Test("412 means “already there” only for the verbs that ask for that")
    func preconditionFailedDependsOnTheVerb() {
        let path = RemotePath("/srv")

        // MKCOL and an overwrite-refusing MOVE say "only if it is not already there".
        #expect(WebDAVTransport.mapStatus(412, path: path, method: .mkcol) == .alreadyExists(path))
        #expect(WebDAVTransport.mapStatus(412, path: path, method: .move) == .alreadyExists(path))

        // A DELETE sets no such precondition, so 412 from one means the server evaluated a condition we
        // never wrote — which is worth saying rather than guessing at.
        guard case .protocolViolation = WebDAVTransport.mapStatus(412, path: path, method: .delete) else {
            Issue.record("412 on a DELETE is not evidence that anything exists")
            return
        }
    }

    @Test("409 means the parent is missing, which is the thing to say")
    func conflictNamesTheParent() {
        #expect(WebDAVTransport.mapStatus(409, path: RemotePath("/srv/deep/a.txt"), method: .put)
                == .notFound(RemotePath("/srv/deep")))
    }

    // MARK: - Browser behaviour we must not have

    @Test("The session never caches a response, and never carries a cookie")
    func configurationHasNoCacheAndNoCookies() {
        let hardened = WebDAVSession.withoutBrowserBehaviour(.ephemeral)

        // The cache is the one that bites. URLSession revalidates the *next request to a URL* with
        // `If-None-Match` regardless of its method, so a DELETE after a GET of the same file arrives
        // conditional and Nextcloud answers 412 rather than deleting. Found against a real server; see
        // `docs/decisions/016-webdav-is-not-a-browser.md`.
        #expect(hardened.urlCache == nil)
        #expect(hardened.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        #expect(hardened.httpShouldSetCookies == false)
        #expect(hardened.httpCookieAcceptPolicy == .never)
        #expect(hardened.httpCookieStorage == nil)
    }

    // MARK: - Redirects behind a TLS terminator

    @Test("A redirect that drops https for the same host and port keeps https")
    func schemeDowngradeIsRepaired() {
        // Apache behind Caddy answers `https://host:8443/folder` with
        // `Location: http://host:8443/folder/` — its own scheme, because it does not know TLS was ever
        // involved. That port speaks TLS only, so following it verbatim hangs up the connection and the
        // user is told the network was lost. Reported against the plain WebDAV server's TLS front.
        let original = URL(string: "https://cloud.example.com:8443/folder")!
        let redirect = URLRequest(url: URL(string: "http://cloud.example.com:8443/folder/")!)

        let repaired = WebDAVConnectionDelegate.keepingOurScheme(redirect, from: original)

        #expect(repaired.url?.absoluteString == "https://cloud.example.com:8443/folder/")
    }

    @Test("The repair works on default ports too, where neither URL states one")
    func schemeDowngradeIsRepairedOnDefaultPorts() {
        let original = URL(string: "https://cloud.example.com/folder")!
        let redirect = URLRequest(url: URL(string: "http://cloud.example.com/folder/")!)

        let repaired = WebDAVConnectionDelegate.keepingOurScheme(redirect, from: original)

        #expect(repaired.url?.absoluteString == "https://cloud.example.com/folder/")
    }

    @Test("A redirect to another host is left alone, downgrade or not")
    func otherHostsAreNotRewritten() {
        // The rewrite must never be able to send us somewhere new — only to keep the scheme we already
        // had. Somewhere new is exactly the case URLSession's own caution is for.
        let original = URL(string: "https://cloud.example.com/folder")!
        let elsewhere = URLRequest(url: URL(string: "http://attacker.example.net/folder/")!)

        let untouched = WebDAVConnectionDelegate.keepingOurScheme(elsewhere, from: original)

        #expect(untouched.url?.absoluteString == "http://attacker.example.net/folder/")
    }

    @Test("A plain http session is never silently upgraded")
    func plainHTTPIsNotUpgraded() {
        // Only a *downgrade* is repaired. A session that started on http stays there — upgrading it
        // would fail against a server with no TLS at all, which is the one the tests use.
        let original = URL(string: "http://localhost:8081/folder")!
        let redirect = URLRequest(url: URL(string: "http://localhost:8081/folder/")!)

        let untouched = WebDAVConnectionDelegate.keepingOurScheme(redirect, from: original)

        #expect(untouched.url?.absoluteString == "http://localhost:8081/folder/")
    }

    @Test("Credentials follow a redirect only when it is the same origin")
    func credentialsDoNotCrossOrigins() {
        let origin = URL(string: "https://cloud.example.com:8443/a")!

        #expect(WebDAVConnectionDelegate.isSameOrigin(origin, URL(string: "https://cloud.example.com:8443/b")))
        #expect(!WebDAVConnectionDelegate.isSameOrigin(origin, URL(string: "https://other.example.com:8443/b")))
        #expect(!WebDAVConnectionDelegate.isSameOrigin(origin, URL(string: "https://cloud.example.com:9999/b")))
        // The scheme counts: WebDAV authenticates with Basic, so following https onto http with the
        // header attached would put the password on the wire in near-clear.
        #expect(!WebDAVConnectionDelegate.isSameOrigin(origin, URL(string: "http://cloud.example.com:8443/b")))
        #expect(!WebDAVConnectionDelegate.isSameOrigin(origin, nil))
    }

    @Test("Hardening copies rather than modifies, so an injected stub survives it")
    func hardeningCopiesTheConfiguration() {
        let original = URLSessionConfiguration.ephemeral
        original.protocolClasses = [StubURLProtocol.self]

        let hardened = WebDAVSession.withoutBrowserBehaviour(original)

        // The stub has to come through, or every test in this file would be talking to the network.
        #expect(hardened.protocolClasses?.contains { $0 == StubURLProtocol.self } == true)
        // And the caller's object is left as it was, rather than changed under it.
        #expect(original.httpShouldSetCookies == true)
        #expect(original.urlCache != nil)
    }
}
