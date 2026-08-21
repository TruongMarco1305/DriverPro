//
//  WebDAVSession.swift
//  DPProtocolWebDAV
//

import DPCore
import DPCredentials
import Foundation

/// A connection to a WebDAV server.
///
/// The second backend, and the reason `Session` exists: nothing above this file knows whether the bytes
/// come from SSH or HTTP. Where SFTP has a long-lived connection, WebDAV has none — every operation is
/// a request — so "connect" here means *check that we can*, and `disconnect` means stop reusing sockets.
///
/// Slice 3a: browsing only. Writes arrive in 3b, the certificate prompt in 3c.
public actor WebDAVSession: Session {

    // MARK: - Configuration

    /// The `properties` key holding the server's DAV root, such as `/remote.php/dav/files/duck`.
    ///
    /// On the bookmark rather than in code because it is the *only* thing that makes Nextcloud different
    /// from a plain server — see ``WebDAVPaths``. Defined in `DPCore` so the connection form can write
    /// it; this is the same constant, not a second spelling of it.
    public static let basePathKey = RemoteHost.webdavBasePathKey

    /// The `properties` key that allows plain HTTP. Absent means HTTPS, which is what anyone should
    /// want; the test container is the reason it can be turned off at all.
    public static let allowsInsecureKey = "webdav.allowsInsecureHTTP"

    // MARK: - State

    /// The bookmark this session was opened from.
    public nonisolated let host: RemoteHost

    private let paths: WebDAVPaths
    /// What the user has already accepted, consulted before anyone is asked again.
    private let trustedCertificates: TrustedCertificateStore
    /// Kept because every request path needs a session of its own: the transport's carries the redirect
    /// delegate, and a download or an upload needs one it can attach its own delegate or body stream to.
    private let configuration: URLSessionConfiguration

    private var transport: WebDAVTransport?
    private var delegate: (any SessionDelegate)?
    /// Built at connect time, because it needs the delegate to ask. Lives as long as the session, which
    /// is what makes "accept once" mean once per *connection* rather than once per request.
    private var trustDecider: TrustDecider?

    /// What this backend can do, which is a genuinely different set from SFTP's.
    ///
    /// Worth reading as a list of protocol differences rather than a configuration: `MOVE` and `COPY`
    /// are server-side, so renaming and copying cost one request rather than a download and an upload.
    /// `DELETE` on a collection is recursive by specification. And there is **no resumable upload** —
    /// no standard one — so `TransferQueue` falls back to starting a file again, which is exactly what
    /// the capability set is for.
    public nonisolated let capabilities: SessionCapabilities = [
        .rename, .serverSideCopy, .emptyDirectories, .recursiveDelete, .resumeDownload
    ]

    /// Creates a session for a bookmark.
    ///
    /// - Parameters:
    ///   - host: Where to connect, and the settings that shape it.
    ///   - trustedCertificates: Certificates the user has already accepted. Defaults to the shared file.
    ///   - configuration: The `URLSession` configuration. Injected so a test can install a stub.
    /// - Returns: `nil` if the bookmark does not describe a reachable URL.
    public init?(
        host: RemoteHost,
        trustedCertificates: TrustedCertificateStore = TrustedCertificateStore(),
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        let isSecure = host.properties[Self.allowsInsecureKey] != "true"
        guard let paths = WebDAVPaths(
            host: host,
            basePath: host.properties[Self.basePathKey] ?? "",
            isSecure: isSecure
        ) else { return nil }

        self.host = host
        self.paths = paths
        self.trustedCertificates = trustedCertificates
        self.configuration = configuration
    }

    // MARK: - Connecting

    /// Checks that the server is there and will have us.
    ///
    /// HTTP has no session to open, so this is a `PROPFIND` of the root: it proves the host resolves,
    /// the credentials are accepted, and the DAV root is where the bookmark says. Finding that out now
    /// rather than on the first listing is what lets the connection sheet report a failure the user can
    /// still fix.
    ///
    /// - Parameters:
    ///   - credentials: What to authenticate with. `nil` asks the delegate.
    ///   - delegate: Who to ask when something is needed.
    /// - Throws: ``SessionError/authenticationFailed(reason:)`` or ``SessionError/unreachable(host:reason:)``.
    public func connect(credentials: Credentials?, delegate: any SessionDelegate) async throws {
        self.delegate = delegate

        var supplied = credentials
        if supplied == nil {
            let request = CredentialRequest(host: host, reason: .initial)
            supplied = await delegate.session(host, needsCredentials: request)
        }
        guard let supplied, case .password(let password) = supplied.method else {
            throw SessionError.authenticationFailed(reason: "WebDAV needs a user name and password.")
        }

        // Built before the first request, so even the probe below can raise the certificate question —
        // finding out at connect time is what lets the sheet appear while the user is still connecting.
        let decider = TrustDecider(host: host, store: trustedCertificates, delegate: delegate)
        self.trustDecider = decider

        let transport = WebDAVTransport(
            configuration: configuration, username: supplied.username, password: password,
            trust: decider
        )
        // Depth 0: this asks only about the root itself. Depth 1 would list the whole top directory
        // before anyone had asked to see it.
        _ = try await transport.send(
            .propfind,
            to: paths.url(for: .root, isDirectory: true),
            about: .root,
            headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )
        self.transport = transport
    }

    /// Whether the server has been reached and accepted us.
    ///
    /// There is no socket to inspect — HTTP has no session — so this means "``connect(credentials:delegate:)``
    /// succeeded", which is the only sense in which a WebDAV connection is open at all.
    public var isConnected: Bool { transport != nil }

    /// Stops reusing connections. There is no session to close.
    public func disconnect() async {
        transport?.invalidate()
        transport = nil
        delegate = nil
        // With it goes every "accept once" answer, which is what makes them last exactly one connection.
        trustDecider = nil
    }

    // MARK: - Browsing

    /// Lists a directory.
    ///
    /// - Parameter directory: Which one.
    /// - Returns: Its immediate children, without the directory itself.
    /// - Throws: ``SessionError/notFound(_:)`` if it is not there.
    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let transport = try requireTransport()
        let data: Data

        do {
            (data, _) = try await transport.send(
                .propfind,
                to: paths.url(for: directory, isDirectory: true),
                about: directory,
                headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
                body: Self.propfindBody
            )
        } catch {
            // Apache answers 400 to a `PROPFIND` of `file/` — the trailing slash that keeps collections
            // from being redirected is a syntax error on something that is not one. "The server answered
            // 400" is not something a user can act on, so ask what it actually is before reporting it.
            if let item = try? await stat(directory), !item.isDirectory {
                throw SessionError.notADirectory(directory)
            }
            throw error
        }

        let entries = try MultiStatusParser.parse(data)

        // WebDAV answers PROPFIND on a *file* perfectly happily, with one entry. Without this check the
        // browser would show an empty folder where a file is — `SessionContract.listingAFileThrows`
        // demands otherwise, and it is right to.
        if let itself = entries.first(where: { paths.path(fromHref: $0.href) == directory }),
           !itself.isCollection {
            throw SessionError.notADirectory(directory)
        }

        // A Depth 1 response includes the collection itself, always first by convention but not by
        // rule. Dropping it by *path* rather than by position is what makes that convention irrelevant.
        return entries.compactMap { entry in
            guard let path = paths.path(fromHref: entry.href), path != directory else { return nil }
            return entry.makeItem(at: path)
        }
    }

    /// Describes one entry.
    ///
    /// - Parameter path: What to look at.
    /// - Returns: What the server says about it.
    /// - Throws: ``SessionError/notFound(_:)`` if it is not there.
    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        let transport = try requireTransport()
        let (data, _) = try await transport.send(
            .propfind,
            to: paths.url(for: path),
            about: path,
            headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )

        guard let entry = try MultiStatusParser.parse(data).first else {
            throw SessionError.notFound(path)
        }
        return entry.makeItem(at: path)
    }

    /// Whether something is there.
    ///
    /// Overrides the protocol's default, which calls ``stat(_:)`` and discards the answer: `PROPFIND`
    /// with `Depth: 0` is the same request, so there is nothing cheaper to reach for — but this way a
    /// transport failure reads as "no" rather than propagating, which is what the protocol promises.
    ///
    /// - Parameter path: What to look for.
    public func exists(_ path: RemotePath) async -> Bool {
        (try? await stat(path)) != nil
    }

    /// Where to start browsing.
    ///
    /// The bookmark's default path, or the DAV root. Unlike SFTP there is no home directory to ask
    /// about — the root *is* the account's space, because the base path already narrowed it.
    public func defaultDirectory() async throws -> RemotePath {
        host.defaultPath ?? .root
    }

    // MARK: - Changing the namespace

    /// Creates a directory.
    ///
    /// - Parameter path: Where to create it.
    /// - Throws: ``SessionError/alreadyExists(_:)`` if something is already there — which is what a 405
    ///   means for `MKCOL` — or ``SessionError/notFound(_:)`` naming the *parent* when it is missing,
    ///   which is what a 409 means.
    public func createDirectory(_ path: RemotePath) async throws {
        let transport = try requireTransport()
        try await transport.send(.mkcol, to: paths.url(for: path, isDirectory: true), about: path)
    }

    /// Removes an entry.
    ///
    /// A collection goes with everything inside it: RFC 4918 defines `DELETE` on a collection as
    /// recursive, which is why ``capabilities`` advertises ``SessionCapabilities/recursiveDelete`` and
    /// why `DirectoryTree.deleteTree` will not walk the tree for this backend.
    ///
    /// - Parameter path: What to remove.
    /// - Throws: ``SessionError/notFound(_:)`` if it is not there.
    public func delete(_ path: RemotePath) async throws {
        let transport = try requireTransport()
        try await transport.send(.delete, to: paths.url(for: path), about: path)
    }

    /// Moves an entry, server-side.
    ///
    /// One request, however large the file — the reason ``SessionCapabilities/rename`` is advertised
    /// here where SFTP has to be asked separately.
    ///
    /// - Parameters:
    ///   - source: What to move.
    ///   - destination: Where it goes.
    /// - Throws: ``SessionError/alreadyExists(_:)`` if something is already at the destination.
    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        let transport = try requireTransport()
        try await transport.send(
            .move,
            to: paths.url(for: source),
            about: source,
            headers: [
                // Absolute, per the specification — a relative destination is not allowed.
                "Destination": paths.url(for: destination).absoluteString,
                // Without this a rename onto an existing name silently replaces it, and the contract's
                // promise that renaming leaves nothing behind would be true for the wrong reason.
                "Overwrite": "F"
            ]
        )
    }

    // MARK: - Moving bytes

    /// Reads a file, streamed.
    ///
    /// - Parameters:
    ///   - path: What to read.
    ///   - offset: Where to start. Sent as a `Range` header.
    /// - Returns: The bytes, in chunks.
    /// - Throws: ``SessionError/notFound(_:)`` if it is not there, or
    ///   ``SessionError/protocolViolation(_:)`` if a resumed read was asked for and the server sent the
    ///   whole file instead.
    public func read(
        _ path: RemotePath,
        from offset: Int64
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        let transport = try requireTransport()
        var request = transport.request(.get, to: paths.url(for: path))

        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return WebDAVDownload.stream(
            request, path: path, expectsRange: offset > 0,
            configuration: configuration, authorization: transport.credentials, trust: trustDecider
        )
    }

    /// Writes a file, streamed.
    ///
    /// - Parameters:
    ///   - path: Where to write.
    ///   - contents: The bytes.
    ///   - size: How many, when known. Sent as `Content-Length`, which a test confirms reaches the
    ///     request rather than being stripped. Whether the *wire* then carries a length or chunked
    ///     transfer encoding is the URL loading system's decision and is not observable from here — so
    ///     if a server ever answers 411, that is the thing to go and measure.
    ///   - offset: Must be zero.
    /// - Throws: ``SessionError/unsupported(_:operation:)`` for a non-zero offset — there is no standard
    ///   resumable `PUT`, and starting from zero while pretending to resume would corrupt the file.
    public func write(
        _ path: RemotePath,
        contents: AsyncThrowingStream<Data, any Error>,
        size: Int64?,
        resumingAt offset: Int64
    ) async throws {
        guard offset == 0 else {
            try require(.resumeUpload, for: "resuming an upload")
            return
        }

        let transport = try requireTransport()
        var request = transport.request(.put, to: paths.url(for: path))
        if let size {
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        }

        try await WebDAVUpload.send(
            request, contents: contents, path: path,
            configuration: configuration, authorization: transport.credentials, trust: trustDecider
        )
    }

    // MARK: - What WebDAV does not have

    /// Refused: WebDAV has no permission model at all.
    ///
    /// Not "unimplemented" — there is nothing to implement. `SessionCapabilities` says so, the UI greys
    /// the command out, and this is the backstop for a caller that asked anyway. ``require(_:for:)``
    /// builds the error naming exactly what is missing.
    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        try require(.posixPermissions, for: "changing permissions")
    }

    /// Refused: there is no portable way to set a modification date over WebDAV.
    ///
    /// `getlastmodified` is defined as read-only by RFC 4918 — servers derive it from their own file
    /// system. Some offer a proprietary property; none of them agree, so DriverPro declines rather than
    /// working on one server and silently not on the next.
    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        try require(.timestamps, for: "setting the modification date")
    }

    // MARK: - Helpers

    /// The request body naming the properties worth asking for.
    ///
    /// Naming them rather than sending `<D:allprop/>`: Nextcloud answers `allprop` with dozens of its
    /// own properties per entry, which is a much larger document to parse for information nothing uses.
    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getlastmodified/>
        <D:getcontenttype/>
        <D:getetag/>
      </D:prop>
    </D:propfind>
    """.utf8)

    private func requireTransport() throws -> WebDAVTransport {
        guard let transport else { throw SessionError.notConnected }
        return transport
    }
}
