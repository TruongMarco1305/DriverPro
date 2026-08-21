//
//  WebDAVSession.swift
//  DPProtocolWebDAV
//

import DPCore
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
    /// from a plain server — see ``WebDAVPaths``.
    public static let basePathKey = "webdav.basePath"

    /// The `properties` key that allows plain HTTP. Absent means HTTPS, which is what anyone should
    /// want; the test container is the reason it can be turned off at all.
    public static let allowsInsecureKey = "webdav.allowsInsecureHTTP"

    // MARK: - State

    /// The bookmark this session was opened from.
    public nonisolated let host: RemoteHost

    private let paths: WebDAVPaths
    private let urlSession: URLSession

    private var transport: WebDAVTransport?
    private var delegate: (any SessionDelegate)?

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
    ///   - configuration: The `URLSession` configuration. Injected so a test can install a stub.
    /// - Returns: `nil` if the bookmark does not describe a reachable URL.
    public init?(host: RemoteHost, configuration: URLSessionConfiguration = .ephemeral) {
        let isSecure = host.properties[Self.allowsInsecureKey] != "true"
        guard let paths = WebDAVPaths(
            host: host,
            basePath: host.properties[Self.basePathKey] ?? "",
            isSecure: isSecure
        ) else { return nil }

        self.host = host
        self.paths = paths
        self.urlSession = URLSession(configuration: configuration)
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

        let transport = WebDAVTransport(
            session: urlSession, username: supplied.username, password: password
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
        urlSession.invalidateAndCancel()
        transport = nil
        delegate = nil
    }

    // MARK: - Browsing

    /// Lists a directory.
    ///
    /// - Parameter directory: Which one.
    /// - Returns: Its immediate children, without the directory itself.
    /// - Throws: ``SessionError/notFound(_:)`` if it is not there.
    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let transport = try requireTransport()
        let (data, _) = try await transport.send(
            .propfind,
            to: paths.url(for: directory, isDirectory: true),
            about: directory,
            headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )

        // A Depth 1 response includes the collection itself, always first by convention but not by
        // rule. Dropping it by *path* rather than by position is what makes that convention irrelevant.
        return try MultiStatusParser.parse(data).compactMap { entry in
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

    // MARK: - Not built yet
    //
    // Slice 3a is browsing. These arrive in 3b, each already knowing which verb it will use. They throw
    // rather than being absent so the type conforms and the rest can be exercised — and so a caller that
    // reaches one gets a refusal rather than a crash.

    /// Not built yet — slice 3b, as `MKCOL`.
    /// - Parameter path: The directory to create.
    /// - Throws: Always, until 3b.
    public func createDirectory(_ path: RemotePath) async throws {
        throw SessionError.unsupported(capabilities, operation: "creating a directory")
    }

    /// Not built yet — slice 3b, as `DELETE`, which WebDAV defines as recursive on a collection.
    /// - Parameter path: What to remove.
    /// - Throws: Always, until 3b.
    public func delete(_ path: RemotePath) async throws {
        throw SessionError.unsupported(capabilities, operation: "deleting")
    }

    /// Not built yet — slice 3b, as `MOVE` with a `Destination` header, done server-side.
    /// - Parameters:
    ///   - source: What to move.
    ///   - destination: Where it goes.
    /// - Throws: Always, until 3b.
    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        throw SessionError.unsupported(capabilities, operation: "renaming")
    }

    /// Not built yet — slice 3b, as `GET` with a `Range` header for the offset.
    /// - Parameters:
    ///   - path: What to read.
    ///   - offset: Where to start.
    /// - Returns: Nothing yet.
    /// - Throws: Always, until 3b.
    public func read(
        _ path: RemotePath,
        from offset: Int64
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        throw SessionError.unsupported(capabilities, operation: "downloading")
    }

    /// Not built yet — slice 3b, as `PUT`. The offset will be ignored: WebDAV has no resumable upload,
    /// which is why ``capabilities`` omits ``SessionCapabilities/resumeUpload``.
    /// - Parameters:
    ///   - path: Where to write.
    ///   - contents: The bytes.
    ///   - size: How many, when known.
    ///   - offset: Where to resume from. Not supported here.
    /// - Throws: Always, until 3b.
    public func write(
        _ path: RemotePath,
        contents: AsyncThrowingStream<Data, any Error>,
        size: Int64?,
        resumingAt offset: Int64
    ) async throws {
        throw SessionError.unsupported(capabilities, operation: "uploading")
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
