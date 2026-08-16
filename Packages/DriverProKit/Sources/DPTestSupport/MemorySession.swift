//
//  MemorySession.swift
//  DPTestSupport
//

import Foundation
import DPCore

/// A complete ``Session`` that lives entirely in memory.
///
/// This is not merely a stub. It is the *executable contract* for what a backend must do: if a rule can
/// be expressed here and tested, every real protocol implementation is expected to behave the same way.
/// It also lets the transfer engine be tested at full speed with no server, no network, and no flakiness.
///
/// ## Swift note — writing an `actor`
/// `MemorySession` is an `actor` because ``Session`` requires it. Note what that buys: `storage` is
/// ordinary mutable state, mutated freely by these methods, and the compiler still guarantees no two
/// tasks touch it at once. Without the actor this class would need a lock around every access, and
/// forgetting one would be a race that shows up as corruption months later.
///
/// `host` and `capabilities` are `nonisolated let` — immutable, so they are safe to read from anywhere
/// without `await`.
public actor MemorySession: Session {

    // MARK: - Contents

    /// What sits at a path.
    public enum Node: Sendable {
        /// A file holding these bytes.
        case file(Data)
        /// A directory.
        case directory
    }

    /// The bookmark this session reports. Not used for anything, since nothing is dialled.
    public nonisolated let host: RemoteHost
    /// What this session claims to support. Vary it to test capability gating.
    public nonisolated let capabilities: SessionCapabilities

    private var storage: [RemotePath: Node] = [.root: .directory]
    private var metadata: [RemotePath: (permissions: POSIXPermissions?, modifiedAt: Date?)] = [:]
    private var connected = false

    /// Number of bytes per chunk yielded by ``read(_:from:)``. Small by default so tests exercise the
    /// multi-chunk path without needing large fixtures.
    public var chunkSize = 8

    // MARK: - Setup

    /// Creates an in-memory session.
    ///
    /// - Parameters:
    ///   - host: The bookmark to report. Defaults to a throwaway one.
    ///   - capabilities: What this session claims to support. Vary this to test capability gating.
    public init(
        host: RemoteHost = RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22),
        capabilities: SessionCapabilities = .posixFileSystem
    ) {
        self.host = host
        self.capabilities = capabilities
    }

    /// Seeds a file, creating any missing parent directories.
    ///
    /// - Parameters:
    ///   - path: Where the file goes.
    ///   - contents: Its bytes.
    public func seed(file path: RemotePath, contents: Data) {
        createParents(of: path)
        storage[path] = .file(contents)
    }

    /// Seeds a directory, creating any missing parents.
    /// - Parameter path: The directory to create.
    public func seed(directory path: RemotePath) {
        createParents(of: path)
        storage[path] = .directory
    }

    private func createParents(of path: RemotePath) {
        for ancestor in path.ancestorsAndSelf.dropLast() {
            storage[ancestor] = .directory
        }
    }

    // MARK: - Lifecycle

    /// Whether ``connect(credentials:delegate:)`` has succeeded.
    public var isConnected: Bool { connected }

    /// Runs the same handshake ordering a real backend does: host key first, then credentials.
    ///
    /// - Parameters:
    ///   - credentials: Credentials to use, or `nil` to ask `delegate`.
    ///   - delegate: Answers the host key and credential questions.
    /// - Throws: ``SessionError/hostKeyRejected`` or ``SessionError/authenticationFailed(reason:)``.
    public func connect(credentials: Credentials?, delegate: any SessionDelegate) async throws {
        // Mirrors the real ordering: identity is verified before credentials are used.
        let challenge = HostKeyChallenge(
            hostname: host.hostname,
            port: host.port,
            keyType: "ssh-ed25519",
            fingerprint: "SHA256:memory",
            trust: .unknown
        )
        guard await delegate.session(host, needsHostKeyVerification: challenge) != .reject else {
            throw SessionError.hostKeyRejected
        }

        var credentials = credentials
        if credentials == nil {
            credentials = await delegate.session(
                host,
                needsCredentials: CredentialRequest(host: host, reason: .initial)
            )
        }
        guard credentials != nil else {
            throw SessionError.authenticationFailed(reason: "cancelled")
        }

        connected = true
    }

    /// Marks the session disconnected. See ``Session/disconnect()``.
    public func disconnect() async {
        connected = false
    }

    // MARK: - Reading the namespace

    /// Lists immediate children. See ``Session/list(_:)`` for the contract.
    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        try requireConnected()
        switch storage[directory] {
        case .none: throw SessionError.notFound(directory)
        case .file: throw SessionError.notADirectory(directory)
        case .directory: break
        }

        return storage.keys
            .filter { $0.parent == directory }
            .map { makeItem(at: $0) }
    }

    /// Returns one entry's metadata. See ``Session/stat(_:)``.
    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        try requireConnected()
        guard storage[path] != nil else { throw SessionError.notFound(path) }
        return makeItem(at: path)
    }

    private func makeItem(at path: RemotePath) -> RemoteItem {
        let meta = metadata[path]
        switch storage[path] {
        case .file(let data):
            return RemoteItem(
                path: path,
                kind: .file,
                size: Int64(data.count),
                modifiedAt: meta?.modifiedAt,
                permissions: meta?.permissions ?? .defaultFile
            )
        default:
            return RemoteItem(
                path: path,
                kind: .directory,
                modifiedAt: meta?.modifiedAt,
                permissions: meta?.permissions ?? .defaultDirectory
            )
        }
    }

    // MARK: - Changing the namespace

    /// Creates a directory, requiring its parent to exist. See ``Session/createDirectory(_:)``.
    public func createDirectory(_ path: RemotePath) async throws {
        try requireConnected()
        guard storage[path] == nil else { throw SessionError.alreadyExists(path) }
        if let parent = path.parent, storage[parent] == nil {
            throw SessionError.notFound(parent)
        }
        storage[path] = .directory
    }

    /// Deletes an entry, recursing only when ``SessionCapabilities/recursiveDelete`` is advertised.
    /// See ``Session/delete(_:)``.
    public func delete(_ path: RemotePath) async throws {
        try requireConnected()
        guard let node = storage[path] else { throw SessionError.notFound(path) }

        if case .directory = node {
            let children = storage.keys.filter { path.isAncestor(of: $0) }
            if !children.isEmpty {
                guard capabilities.contains(.recursiveDelete) else {
                    throw SessionError.directoryNotEmpty(path)
                }
                for child in children { storage[child] = nil }
            }
        }
        storage[path] = nil
        metadata[path] = nil
    }

    /// Moves an entry and its whole subtree. See ``Session/move(_:to:)``.
    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        try requireConnected()
        try require(.rename, for: "renaming")
        guard let node = storage[source] else { throw SessionError.notFound(source) }
        guard storage[destination] == nil else { throw SessionError.alreadyExists(destination) }

        // Move the subtree, not just the entry, so directories keep their contents.
        for descendant in storage.keys where source.isAncestor(of: descendant) {
            guard let tail = source.relativeComponents(to: descendant) else { continue }
            let moved = RemotePath(components: destination.components + tail)
            storage[moved] = storage[descendant]
            storage[descendant] = nil
        }
        storage[destination] = node
        storage[source] = nil
    }

    // MARK: - Transferring bytes

    /// Streams a file in ``chunkSize`` pieces. See ``Session/read(_:from:)``.
    public func read(_ path: RemotePath, from offset: Int64) async throws -> AsyncThrowingStream<Data, any Error> {
        try requireConnected()
        guard case .file(let data) = storage[path] else { throw SessionError.notFound(path) }
        if offset > 0 {
            try require(.resumeDownload, for: "resuming a download")
        }

        let payload = Data(data.dropFirst(Int(offset)))
        let chunkSize = self.chunkSize

        // The whole payload is already in hand, so the stream can be filled eagerly and finished. A real
        // backend instead yields from a network read loop and honours backpressure.
        return AsyncThrowingStream { continuation in
            var start = 0
            while start < payload.count {
                let end = min(start + chunkSize, payload.count)
                continuation.yield(payload.subdata(in: start..<end))
                start = end
            }
            continuation.finish()
        }
    }

    /// Accumulates a stream into memory. See ``Session/write(_:contents:size:resumingAt:)``.
    public func write(
        _ path: RemotePath,
        contents: AsyncThrowingStream<Data, any Error>,
        size: Int64?,
        resumingAt offset: Int64
    ) async throws {
        try requireConnected()
        if offset > 0 {
            try require(.resumeUpload, for: "resuming an upload")
        }
        if let parent = path.parent, storage[parent] == nil {
            throw SessionError.notFound(parent)
        }

        var accumulated: Data
        if offset > 0, case .file(let existing) = storage[path] {
            accumulated = existing.prefix(Int(offset))
        } else {
            accumulated = Data()
        }

        for try await chunk in contents {
            accumulated.append(chunk)
        }
        storage[path] = .file(accumulated)
    }

    // MARK: - Metadata

    /// Records a permission change. See ``Session/setPermissions(_:at:)``.
    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        try requireConnected()
        try require(.posixPermissions, for: "changing permissions")
        guard storage[path] != nil else { throw SessionError.notFound(path) }
        metadata[path, default: (nil, nil)].permissions = permissions
    }

    /// Records a timestamp change. See ``Session/setModificationDate(_:at:)``.
    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        try requireConnected()
        try require(.timestamps, for: "changing the modification date")
        guard storage[path] != nil else { throw SessionError.notFound(path) }
        metadata[path, default: (nil, nil)].modifiedAt = date
    }

    // MARK: - Helpers

    private func requireConnected() throws {
        guard connected else { throw SessionError.notConnected }
    }
}

// MARK: - Test delegate

/// A ``SessionDelegate`` that answers from a script instead of asking a human.
///
/// This is the other half of what makes the engine testable: `Session` implementations ask questions
/// through a delegate, so a test supplies canned answers and the whole connection flow runs with no UI
/// and no human.
public struct ScriptedDelegate: SessionDelegate {

    /// The answer to give for any host key challenge.
    public var hostKeyDecision: HostKeyDecision

    /// The credentials to supply when asked, or `nil` to simulate the user cancelling.
    public var credentials: Credentials?

    /// Creates a scripted delegate.
    ///
    /// - Parameters:
    ///   - hostKeyDecision: How to answer host key challenges. Defaults to accepting without recording.
    ///   - credentials: What to supply when credentials are requested.
    public init(
        hostKeyDecision: HostKeyDecision = .acceptOnce,
        credentials: Credentials? = .password(username: "test", password: "hunter2")
    ) {
        self.hostKeyDecision = hostKeyDecision
        self.credentials = credentials
    }

    /// Returns the scripted host key decision. See ``SessionDelegate``.
    public func session(
        _ host: RemoteHost,
        needsHostKeyVerification challenge: HostKeyChallenge
    ) async -> HostKeyDecision {
        hostKeyDecision
    }

    /// Returns the scripted credentials, or `nil` to simulate cancelling. See ``SessionDelegate``.
    public func session(_ host: RemoteHost, needsCredentials request: CredentialRequest) async -> Credentials? {
        credentials
    }
}
