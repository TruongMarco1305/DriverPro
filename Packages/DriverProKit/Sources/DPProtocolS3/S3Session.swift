//
//  S3Session.swift
//  DPProtocolS3
//

import DPCore
import Foundation
import SotoCore
import SotoS3

/// A connection to an S3-compatible object store.
///
/// The third backend, and the one the abstraction was built to be tested by. WebDAV disagreed with SFTP
/// about *how* — different verbs, different metadata. S3 disagrees about *what exists*: there are no
/// directories, no rename, no permissions, and the root is not a directory but a list of buckets.
///
/// Like WebDAV there is no connection to open. "Connect" means *check that we can*, and `disconnect`
/// means release Soto's client — which is not optional, see ``S3Client``.
///
/// Slice 4a: browsing only. Writes and transfers arrive in 4b, `copy` in 4c, the provider dialects
/// in 4d.
public actor S3Session: Session {

    // MARK: - State

    /// The bookmark this session was opened from.
    public nonisolated let host: RemoteHost

    private var client: S3Client?
    private var delegate: (any SessionDelegate)?

    /// What this backend can do, which is a third distinct shape.
    ///
    /// Worth reading as a list of what object storage *is* rather than as configuration:
    ///
    /// - **No ``SessionCapabilities/rename``.** There is no such request. A move is `CopyObject` then
    ///   `DeleteObject`, which is two operations and can leave both copies or neither. The emulation
    ///   lives above this backend, not inside it — see ADR 018.
    /// - **``SessionCapabilities/emptyDirectories`` despite S3 having no directories**, because
    ///   `createDirectory` writes a zero-byte placeholder key and that makes the folder survive a
    ///   refresh, which is the whole of what the capability promises.
    /// - **``SessionCapabilities/recursiveDelete``**, meaning this backend removes the subtree itself —
    ///   a listing plus a batch delete per thousand keys. Not one request, but far better than
    ///   `DirectoryTree` walking at one round trip per object.
    /// - **No ``SessionCapabilities/checksum``.** The ETag is an MD5 only for single-part uploads; for a
    ///   multipart upload it is a composite of the parts' hashes and matches nothing you can compute
    ///   locally. A checksum that is right sometimes is worse than none.
    public nonisolated let capabilities: SessionCapabilities = [
        .serverSideCopy, .emptyDirectories, .recursiveDelete, .resumeDownload
    ]

    /// Creates a session for a bookmark.
    /// - Parameter host: Where to connect, and the settings that shape it.
    public init(host: RemoteHost) {
        self.host = host
    }

    // MARK: - Connecting

    /// Checks that the endpoint is there and the credentials are accepted.
    ///
    /// The probe is `ListBuckets`, which proves the endpoint resolves, the clock is close enough for the
    /// signature to verify, and the keys are good. Its one limitation is worth knowing: a key scoped to
    /// a single bucket may be refused here while being perfectly able to work inside that bucket. When
    /// that turns out to matter, the fix is to probe `HeadBucket` instead whenever the bookmark names a
    /// bucket in ``RemoteHost/defaultPath``.
    ///
    /// - Parameters:
    ///   - credentials: The access key id and secret. `nil` asks the delegate.
    ///   - delegate: Who to ask when something is needed.
    /// - Throws: ``SessionError/authenticationFailed(reason:)`` if the keys are refused, or
    ///   ``SessionError/unreachable(host:reason:)`` if the endpoint cannot be contacted.
    public func connect(credentials: Credentials?, delegate: any SessionDelegate) async throws {
        self.delegate = delegate

        var supplied = credentials
        if supplied == nil {
            supplied = await delegate.session(host, needsCredentials: CredentialRequest(host: host, reason: .initial))
        }
        guard let supplied, case .password(let secret) = supplied.method else {
            throw SessionError.authenticationFailed(
                reason: "S3 needs an access key ID and a secret access key."
            )
        }

        let client = S3Client(host: host, accessKeyID: supplied.username, secretAccessKey: secret)
        do {
            _ = try await client.s3.listBuckets()
        } catch {
            // The client is live from the moment it is constructed, so a failed probe still has to shut
            // it down — otherwise a mistyped password leaves a client that traps when it is collected.
            await client.shutdown()
            throw Self.explaining(S3ErrorMapping.map(error, path: .root), host: host)
        }
        self.client = client
    }

    /// Adds the endpoint to a connection failure that is probably about the endpoint.
    ///
    /// Hostname, port and region combine into one signed request, and when the combination is wrong the
    /// user is looking at three fields with no way to tell which. Naming what was tried turns a guess
    /// into a comparison. The same reasoning as `WebDAVSession.explaining`.
    private static func explaining(_ error: SessionError, host: RemoteHost) -> SessionError {
        switch error {
        case .transport(let reason):
            .unreachable(host: host.hostname, reason: "\(reason)\n\nTried: \(S3Client.endpoint(for: host))")
        default:
            error
        }
    }

    /// Whether the endpoint has been reached and accepted us.
    ///
    /// There is no socket to inspect, so this means "``connect(credentials:delegate:)`` succeeded".
    public var isConnected: Bool { client != nil }

    /// Releases Soto's client. Never throws; see ``S3Client/shutdown()``.
    public func disconnect() async {
        await client?.shutdown()
        client = nil
        delegate = nil
    }

    /// Where to start browsing: the bookmark's path, or the list of buckets.
    public func defaultDirectory() async throws -> RemotePath {
        host.defaultPath ?? .root
    }

    // MARK: - Browsing

    /// Lists a location's immediate children.
    ///
    /// Three different requests behind one method, which is the shape of this backend in miniature: the
    /// root is `ListBuckets`, and anything else is `ListObjectsV2` with a delimiter, where `Contents`
    /// are the files and `CommonPrefixes` are the folders.
    ///
    /// - Parameter directory: What to list.
    /// - Returns: The children, unsorted.
    /// - Throws: ``SessionError/notFound(_:)`` if nothing is there, or
    ///   ``SessionError/notADirectory(_:)`` if the path names an object.
    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let client = try requireClient()
        let location = S3Location(directory)

        guard let bucket = location.bucket, let prefix = location.childPrefix else {
            return try await listBuckets(client)
        }

        var items: [RemoteItem] = []
        var continuationToken: String?
        // Paginated rather than a single call: S3 caps a listing at 1000 keys and says so with
        // `isTruncated`. A directory of 2,500 objects that silently returned 1,000 would be a browser
        // quietly lying about what is on the server.
        repeat {
            let page: S3.ListObjectsV2Output
            do {
                page = try await client.s3.listObjectsV2(
                    bucket: bucket,
                    continuationToken: continuationToken,
                    // The delimiter is what turns a flat key space into a directory listing: everything
                    // sharing a prefix up to the next `/` collapses into one `CommonPrefix`.
                    delimiter: "/",
                    prefix: prefix.isEmpty ? nil : prefix
                )
            } catch {
                throw S3ErrorMapping.map(error, path: directory)
            }

            items += (page.contents ?? []).compactMap { $0.makeItem(inBucket: bucket) }
            items += (page.commonPrefixes ?? []).compactMap { $0.makeItem(inBucket: bucket) }

            let next = page.isTruncated == true ? page.nextContinuationToken : nil
            // A server that echoes the token it was given would spin here forever, filling memory with
            // the same page. Amazon does not; "S3-compatible" is a family of dialects, and a listing
            // that never returns is the worst way to discover a new member of it.
            if let next, next == continuationToken {
                throw SessionError.protocolViolation(
                    "The server repeated its continuation token while listing \(directory.pathString), "
                    + "so the listing cannot advance."
                )
            }
            continuationToken = next
        } while continuationToken != nil

        // An empty result is ambiguous in a way it never is on a real file system: a prefix with nothing
        // under it does not exist, so "empty directory" and "no such directory" are the same answer from
        // the server. Asking what is actually there separates them — and distinguishes both from a path
        // that names an object, which `SessionContract.listingAFileThrows` requires to fail.
        if items.isEmpty, case .object = location {
            let item = try await stat(directory)
            guard item.isDirectory else { throw SessionError.notADirectory(directory) }
        }
        return items
    }

    /// Lists the account's buckets, as directories.
    private func listBuckets(_ client: S3Client) async throws -> [RemoteItem] {
        do {
            return (try await client.s3.listBuckets().buckets ?? []).compactMap { $0.makeItem() }
        } catch {
            throw S3ErrorMapping.map(error, path: .root)
        }
    }

    /// Describes one entry.
    ///
    /// Costs up to three requests for a directory, and one for a file, because S3 has no `stat` and a
    /// directory has no existence to ask about. In order: the object itself, then its placeholder key,
    /// then whether anything at all lives under the prefix — the last being how a folder created by some
    /// other tool, which wrote no placeholder, is still found.
    ///
    /// - Parameter path: What to look at.
    /// - Returns: What the server says about it.
    /// - Throws: ``SessionError/notFound(_:)`` if nothing is there.
    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        let client = try requireClient()

        switch S3Location(path) {
        case .root:
            return RemoteItem(path: .root, kind: .directory)

        case .bucket(let name):
            guard let bucket = try await listBuckets(client).first(where: { $0.name == name }) else {
                throw SessionError.notFound(path)
            }
            return bucket

        case .object(let bucket, let key):
            // Each probe may find nothing and fall through to the next, but none of them may hide a
            // failure that is not an absence — see `S3ErrorMapping.missing`.
            if let head = try await S3ErrorMapping.missing(path, {
                try await client.s3.headObject(bucket: bucket, key: key)
            }) {
                return RemoteItem(
                    path: path,
                    kind: .file,
                    size: head.contentLength,
                    modifiedAt: head.lastModified,
                    extra: head.eTag.map {
                        ["s3.etag": $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))]
                    } ?? [:]
                )
            }

            if let placeholder = try await S3ErrorMapping.missing(path, {
                try await client.s3.headObject(bucket: bucket, key: "\(key)/")
            }) {
                return RemoteItem(path: path, kind: .directory, size: nil, modifiedAt: placeholder.lastModified)
            }

            let probe = try await S3ErrorMapping.missing(path, {
                try await client.s3.listObjectsV2(bucket: bucket, maxKeys: 1, prefix: "\(key)/")
            })
            guard (probe?.keyCount ?? 0) > 0 else { throw SessionError.notFound(path) }
            return RemoteItem(path: path, kind: .directory)
        }
    }

    /// Whether anything exists at a path.
    ///
    /// Overrides the protocol's default so that a transport failure reads as "no" rather than
    /// propagating, which is what `Session.exists` promises.
    ///
    /// - Parameter path: What to look for.
    public func exists(_ path: RemotePath) async -> Bool {
        (try? await stat(path)) != nil
    }

    // MARK: - Not built yet

    // Slice 4a is browsing. These arrive in 4b, each already knowing which request it will make. They
    // throw rather than being absent so the type conforms and the rest can be exercised — and so a
    // caller that reaches one gets a refusal rather than a crash.

    /// Not built yet — slice 4b, as a zero-byte placeholder key, or `CreateBucket` at the root.
    /// - Parameter path: The directory to create.
    /// - Throws: Always, until 4b.
    public func createDirectory(_ path: RemotePath) async throws {
        throw SessionError.unsupported(capabilities, operation: "creating a directory")
    }

    /// Not built yet — slice 4b, as `DeleteObject`, or a listing plus `DeleteObjects` for a prefix.
    /// - Parameter path: What to remove.
    /// - Throws: Always, until 4b.
    public func delete(_ path: RemotePath) async throws {
        throw SessionError.unsupported(capabilities, operation: "deleting")
    }

    /// Refused, and permanently: S3 has no rename.
    ///
    /// Not "unimplemented". `CopyObject` followed by `DeleteObject` is what other clients do, and it is
    /// not a rename — it is two operations that can leave both copies or neither. The emulation belongs
    /// above this backend, where the caller can be told what it is agreeing to. See ADR 018.
    ///
    /// - Parameters:
    ///   - source: What to move.
    ///   - destination: Where it would go.
    /// - Throws: ``SessionError/unsupported(_:operation:)``, always.
    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        try require(.rename, for: "renaming")
    }

    /// Not built yet — slice 4b, as `GetObject` with a `Range` header.
    /// - Parameters:
    ///   - path: The file to read.
    ///   - offset: Where to start.
    /// - Returns: Never.
    /// - Throws: Always, until 4b.
    public func read(
        _ path: RemotePath,
        from offset: Int64
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        throw SessionError.unsupported(capabilities, operation: "reading")
    }

    /// Not built yet — slice 4b, as `PutObject`, or the multipart family above the threshold.
    /// - Parameters:
    ///   - path: Where to write.
    ///   - contents: The bytes.
    ///   - size: How many, when known.
    ///   - offset: Where to resume, which S3 cannot do.
    /// - Throws: Always, until 4b.
    public func write(
        _ path: RemotePath,
        contents: AsyncThrowingStream<Data, any Error>,
        size: Int64?,
        resumingAt offset: Int64
    ) async throws {
        throw SessionError.unsupported(capabilities, operation: "writing")
    }

    // MARK: - What object storage does not have

    /// Refused: objects have no Unix permissions.
    ///
    /// S3 has an access-control model, but it is ACLs and bucket policies — not a mode, not an owner,
    /// and not something `POSIXPermissions` could carry without lying about it.
    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        try require(.posixPermissions, for: "changing permissions")
    }

    /// Refused: an object's last-modified date is the server's, and it is not settable.
    ///
    /// Other clients keep the original date in user metadata and show that instead. That is a real
    /// feature and a real decision, and it is not this slice's.
    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        try require(.timestamps, for: "setting the modification date")
    }

    // MARK: - Helpers

    /// The client, or the error that says why there is not one.
    private func requireClient() throws -> S3Client {
        guard let client else { throw SessionError.notConnected }
        return client
    }
}
