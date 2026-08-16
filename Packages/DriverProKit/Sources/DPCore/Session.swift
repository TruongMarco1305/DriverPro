//
//  Session.swift
//  DPCore
//

import Foundation

/// One live connection to one remote file system.
///
/// This is the contract every backend implements and everything above the protocol layer programs
/// against. The browser does not know whether it is showing SFTP or S3; it holds a `Session`.
///
/// Getting this protocol's shape right is the entire point of milestone 1. It is written against SFTP
/// first, but each subsequent protocol is a test of whether the abstraction was honest — and WebDAV, S3,
/// and FTP are expected to push back on it.
///
/// ## Swift note — `protocol Session: Actor`
/// Conforming types must be actors. An `actor` is a reference type that protects its own mutable state:
/// the compiler guarantees only one task touches that state at a time, so a connection's buffers,
/// sequence numbers, and channel handles cannot be corrupted by two concurrent calls. That is why every
/// method here is implicitly `async` from a caller's point of view — reaching an actor from outside means
/// waiting your turn.
///
/// The trade-off is deliberate: operations on a *single* session serialise. Parallelism comes from
/// opening several sessions through a connection pool, which matches how these servers expect to be used
/// and keeps each session's protocol state comprehensible.
///
/// ## Swift note — `nonisolated`
/// ``capabilities`` is `nonisolated`: it is fixed for the lifetime of the connection, so reading it
/// touches no protected state and needs no `await`. This matters for the UI, which asks "should the
/// Rename menu item be enabled?" during a synchronous view update where awaiting is not possible.
public protocol Session: Actor {

    // MARK: - Identity

    /// The bookmark this session was opened from.
    nonisolated var host: RemoteHost { get }

    /// What this backend can do. Fixed once the session is created.
    ///
    /// Read this before offering an operation. See ``SessionCapabilities`` for why this is not optional
    /// politeness but a correctness requirement.
    nonisolated var capabilities: SessionCapabilities { get }

    // MARK: - Connection lifecycle

    /// Whether the connection is currently usable.
    var isConnected: Bool { get }

    /// Opens the connection: transport, host key verification, and authentication.
    ///
    /// Implementations must verify the server's identity through `delegate` *before* sending credentials.
    ///
    /// - Parameters:
    ///   - credentials: Credentials to try first. Pass `nil` to have the session ask `delegate`.
    ///   - delegate: Where to send questions that need a human.
    /// - Throws: ``SessionError/authenticationFailed(reason:)`` if the server refuses the credentials,
    ///   ``SessionError/hostKeyRejected`` if the user declines the host key, or
    ///   ``SessionError/unreachable(host:reason:)`` if the server cannot be contacted.
    func connect(credentials: Credentials?, delegate: any SessionDelegate) async throws

    /// Closes the connection, releasing its resources.
    ///
    /// Never throws: there is nothing a caller could usefully do about a failure to hang up, and a
    /// throwing teardown makes correct cleanup in `defer` blocks awkward.
    func disconnect() async

    /// The directory to show when the browser opens.
    ///
    /// Usually the SFTP home directory or the WebDAV root. Falls back to ``RemotePath/root``.
    ///
    /// - Returns: The starting directory.
    /// - Throws: ``SessionError/notConnected`` if called before connecting.
    func defaultDirectory() async throws -> RemotePath

    // MARK: - Reading the namespace

    /// Lists a directory's immediate contents.
    ///
    /// Does not recurse, and does not include `.` or `..`. Hidden entries *are* included — filtering them
    /// is a display decision, made higher up.
    ///
    /// - Parameter directory: The directory to list.
    /// - Returns: The entries, in whatever order the server gave them. Sort at the point of display.
    /// - Throws: ``SessionError/notFound(_:)`` if the directory does not exist,
    ///   ``SessionError/notADirectory(_:)`` if the path is a file, or
    ///   ``SessionError/accessDenied(_:)`` if it cannot be read.
    func list(_ directory: RemotePath) async throws -> [RemoteItem]

    /// Fetches metadata for a single entry.
    ///
    /// Some backends have no cheap way to do this — FTP in particular — and implement it by listing the
    /// parent directory and picking the entry out. Prefer ``list(_:)`` when you need several entries.
    ///
    /// - Parameter path: The entry to inspect.
    /// - Returns: The entry's metadata.
    /// - Throws: ``SessionError/notFound(_:)`` if nothing exists there.
    func stat(_ path: RemotePath) async throws -> RemoteItem

    /// Whether anything exists at a path.
    ///
    /// - Parameter path: The path to test.
    /// - Returns: `true` if an entry exists.
    func exists(_ path: RemotePath) async -> Bool

    // MARK: - Changing the namespace

    /// Creates a directory.
    ///
    /// The parent must already exist; create intermediate directories yourself if needed.
    ///
    /// On backends without ``SessionCapabilities/emptyDirectories`` this may be a local fiction that
    /// disappears on refresh unless a placeholder object is written.
    ///
    /// - Parameter path: Where to create it.
    /// - Throws: ``SessionError/alreadyExists(_:)`` if something is already there.
    func createDirectory(_ path: RemotePath) async throws

    /// Deletes a file, an empty directory, or a symbolic link.
    ///
    /// Deleting a non-empty directory requires ``SessionCapabilities/recursiveDelete``; without it,
    /// callers must walk the tree depth-first themselves.
    ///
    /// - Parameter path: What to delete.
    /// - Throws: ``SessionError/directoryNotEmpty(_:)`` if the directory has contents and the backend
    ///   cannot remove them in one operation.
    func delete(_ path: RemotePath) async throws

    /// Renames or moves an entry.
    ///
    /// Requires ``SessionCapabilities/rename``.
    ///
    /// - Parameters:
    ///   - source: What to move.
    ///   - destination: Where it should end up, including its new name.
    /// - Throws: ``SessionError/unsupported(_:operation:)`` if the backend has no rename, or
    ///   ``SessionError/alreadyExists(_:)`` if the destination is occupied.
    func move(_ source: RemotePath, to destination: RemotePath) async throws

    // MARK: - Transferring bytes

    /// Streams a file's contents.
    ///
    /// ## Swift note — `AsyncThrowingStream`
    /// The return type is a stream of chunks rather than one `Data`, because a `Data` would mean holding
    /// the whole file in memory — fine for a text file, fatal for a 40 GB disk image. An
    /// `AsyncThrowingStream` is consumed with `for try await`, applies backpressure so the network does
    /// not race ahead of the disk, and can fail partway through:
    ///
    /// ```swift
    /// for try await chunk in try await session.read(path, from: 0) {
    ///     try handle.write(contentsOf: chunk)
    /// }
    /// ```
    ///
    /// Cancelling the consuming task stops the transfer.
    ///
    /// - Parameters:
    ///   - path: The file to read.
    ///   - offset: Byte offset to start at. Non-zero requires ``SessionCapabilities/resumeDownload``.
    /// - Returns: A stream of the file's bytes from `offset` to the end.
    /// - Throws: ``SessionError/notFound(_:)`` if the file does not exist, or
    ///   ``SessionError/unsupported(_:operation:)`` for a non-zero offset the backend cannot honour.
    func read(_ path: RemotePath, from offset: Int64) async throws -> AsyncThrowingStream<Data, any Error>

    /// Writes a file from a stream of chunks.
    ///
    /// The call returns only once every byte is committed, so a normal return means the upload succeeded.
    ///
    /// - Parameters:
    ///   - path: Where to write. Overwritten if it exists.
    ///   - contents: The bytes to write.
    ///   - size: Total size in bytes if known. Some backends need this up front — S3 to choose between a
    ///     single `PutObject` and a multipart upload — and all of them can report better progress with it.
    ///   - offset: Byte offset to resume at. Non-zero requires ``SessionCapabilities/resumeUpload``.
    /// - Throws: ``SessionError/insufficientStorage`` if the server is full, or
    ///   ``SessionError/accessDenied(_:)`` if the location is not writable.
    func write(
        _ path: RemotePath,
        contents: AsyncThrowingStream<Data, any Error>,
        size: Int64?,
        resumingAt offset: Int64
    ) async throws

    // MARK: - Optional metadata operations

    /// Changes an entry's Unix permissions.
    ///
    /// Requires ``SessionCapabilities/posixPermissions``.
    ///
    /// - Parameters:
    ///   - permissions: The mode to set.
    ///   - path: The entry to change.
    /// - Throws: ``SessionError/unsupported(_:operation:)`` on backends with no permission model.
    func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws

    /// Sets an entry's modification date.
    ///
    /// Requires ``SessionCapabilities/timestamps``. This is what preserves a file's date across an upload.
    ///
    /// - Parameters:
    ///   - date: The timestamp to set.
    ///   - path: The entry to change.
    /// - Throws: ``SessionError/unsupported(_:operation:)`` if timestamps cannot be set.
    func setModificationDate(_ date: Date, at path: RemotePath) async throws
}

// MARK: - Shared behaviour

extension Session {

    /// Default `exists` implementation in terms of ``stat(_:)``.
    ///
    /// Swallows the error deliberately: callers of `exists` want a yes or no, and a failure to stat is a
    /// no for their purposes. Anything needing to know *why* should call ``stat(_:)`` directly.
    public func exists(_ path: RemotePath) async -> Bool {
        do {
            _ = try await stat(path)
            return true
        } catch {
            return false
        }
    }

    /// Default: the server's root.
    public func defaultDirectory() async throws -> RemotePath {
        host.defaultPath ?? .root
    }

    /// Throws unless the backend advertises every capability in `required`.
    ///
    /// A guard for the top of an optional operation, so backends fail with a precise, actionable error
    /// instead of a protocol-level one:
    ///
    /// ```swift
    /// func move(_ source: RemotePath, to destination: RemotePath) async throws {
    ///     try require(.rename, for: "renaming")
    ///     …
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - required: The capabilities the operation needs.
    ///   - operation: A user-facing gerund naming the operation, such as `"renaming"`.
    /// - Throws: ``SessionError/unsupported(_:operation:)`` listing only the missing capabilities.
    public nonisolated func require(
        _ required: SessionCapabilities,
        for operation: String
    ) throws {
        guard capabilities.isSuperset(of: required) else {
            throw SessionError.unsupported(required.subtracting(capabilities), operation: operation)
        }
    }
}
