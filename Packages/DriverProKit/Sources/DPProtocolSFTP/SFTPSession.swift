//
//  SFTPSession.swift
//  DPProtocolSFTP
//
//  Target responsibility
//  ────────────────────
//  DPProtocolSFTP implements `Session` over SSH. It is the only target in the package permitted to
//  import Citadel or NIOSSH — that containment is what would let libssh2 replace them without anything
//  above this file noticing.
//
//  It may import: Foundation, NIO, Citadel, DPCore, DPCredentials.
//  It may NOT import: SwiftUI, AppKit, or any other DPProtocol* target.
//

import Citadel
// swift-crypto, arriving transitively via Citadel. `Curve25519` and `Insecure.RSA` live here — the
// latter is Citadel's own extension of Crypto's `Insecure` namespace.
import Crypto
import DPCore
import DPCredentials
import Foundation
import NIOCore

/// A live SFTP connection.
///
/// The first real implementation of ``Session``, and therefore the first genuine test of whether that
/// abstraction was honest. Where SFTP disagrees with the protocol, the disagreement is documented here
/// rather than papered over.
public actor SFTPSession: Session {

    // MARK: - Identity

    /// The bookmark this session was opened from.
    public nonisolated let host: RemoteHost

    /// What SFTP can do, established by reading Citadel's actual API rather than by optimism.
    ///
    /// Two absences are worth calling out, because they are the capability system earning its place on
    /// the very first backend:
    ///
    /// - **No ``SessionCapabilities/recursiveDelete``.** SFTP has `remove` for files and `rmdir` for
    ///   empty directories, and nothing that deletes a tree. Callers must walk it depth-first.
    /// - **No ``SessionCapabilities/serverSideCopy``.** SFTP v3 has no copy operation at all; duplicating
    ///   a file means downloading and re-uploading it.
    ///
    /// Also absent: `.quota`, `.versioning`, `.checksum` (all v6 or vendor extensions), and
    /// `.segmentedTransfer` (possible over multiple channels, but not attempted in M1).
    public nonisolated let capabilities: SessionCapabilities = [
        .rename,
        .emptyDirectories,
        .symbolicLinks,
        .posixPermissions,
        .timestamps,
        .ownership,
        .resumeDownload,
        .resumeUpload
    ]

    // MARK: - Configuration

    /// Where trusted host keys are read from and recorded.
    private let knownHosts: KnownHostsStore

    /// Bytes requested per SFTP read. 32 KB is the largest payload many servers accept in one packet,
    /// and going smaller costs a round trip per chunk on a high-latency link.
    private let chunkSize: UInt32

    // MARK: - Connection state
    //
    // These are the actor's protected state. Being inside an actor is what makes them safe to mutate
    // from several tasks without a lock.

    // `SSHClientHandle` rather than `SSHClient` because Citadel does not mark the latter `Sendable`.
    // See CitadelHandles.swift for why that wrapper exists and why its `@unchecked` is justified.
    private var client: SSHClientHandle?
    private var sftp: SFTPClient?

    /// Creates a session. No connection is made until ``connect(credentials:delegate:)`` is called.
    ///
    /// - Parameters:
    ///   - host: The bookmark to connect to.
    ///   - knownHosts: Host key store. Defaults to `~/.ssh/known_hosts`.
    ///   - chunkSize: Bytes per SFTP read. Defaults to 32 KB.
    public init(
        host: RemoteHost,
        knownHosts: KnownHostsStore = KnownHostsStore(),
        chunkSize: UInt32 = 32_768
    ) {
        self.host = host
        self.knownHosts = knownHosts
        self.chunkSize = chunkSize
    }

    // MARK: - Lifecycle

    /// Whether the SFTP subsystem is open and usable.
    public var isConnected: Bool { sftp != nil }

    /// Opens the SSH connection, verifies the host key, authenticates, and starts SFTP.
    ///
    /// The ordering is a security requirement, not a convenience: `HostKeyVerifier` runs during the
    /// handshake, so the server's identity is settled *before* any credential is transmitted.
    ///
    /// - Parameters:
    ///   - credentials: Credentials to try. Pass `nil` to have the session ask `delegate`.
    ///   - delegate: Where host key and credential questions go.
    /// - Throws: ``SessionError/hostKeyRejected``, ``SessionError/authenticationFailed(reason:)``, or
    ///   ``SessionError/unreachable(host:reason:)``.
    public func connect(credentials: Credentials?, delegate: any SessionDelegate) async throws {
        let resolved: Credentials
        if let credentials {
            resolved = credentials
        } else {
            guard let prompted = await delegate.session(
                host,
                needsCredentials: CredentialRequest(host: host, reason: .initial)
            ) else {
                throw SessionError.authenticationFailed(reason: "cancelled")
            }
            resolved = prompted
        }

        let verifier = HostKeyVerifier(host: host, knownHosts: knownHosts, delegate: delegate)

        do {
            let client = SSHClientHandle(
                try await SSHClient.connect(
                    host: host.hostname,
                    port: host.port,
                    authenticationMethod: try Self.authenticationMethod(for: resolved),
                    hostKeyValidator: .custom(verifier),
                    reconnect: .never
                )
            )
            self.client = client
            self.sftp = try await client.openSFTP()

            delegate.session(host, didLog: TranscriptMessage(
                direction: .local,
                text: "SFTP session opened as \(resolved.username)."
            ))
        } catch {
            // Tear down a half-open connection rather than leaving a dangling SSH channel.
            await disconnect()
            throw SFTPErrorMapping.mapConnectionError(error, hostname: host.hostname)
        }
    }

    /// Closes the SFTP subsystem and the SSH connection.
    ///
    /// Failures are ignored deliberately: there is nothing a caller can do about a failed hang-up, and a
    /// throwing teardown makes cleanup in error paths awkward.
    public func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    /// The directory to open on connecting: the bookmark's default path, or the SSH home directory.
    ///
    /// `getRealPath(".")` is how the home directory is discovered — SFTP has no other way to ask.
    ///
    /// - Returns: The starting directory.
    /// - Throws: ``SessionError/notConnected`` if called before connecting.
    public func defaultDirectory() async throws -> RemotePath {
        if let defaultPath = host.defaultPath { return defaultPath }

        let sftp = try requireSFTP()
        do {
            return RemotePath(try await sftp.getRealPath(atPath: "."))
        } catch {
            // A server that will not resolve "." is unusual but not fatal; the root always exists.
            return .root
        }
    }

    // MARK: - Reading the namespace

    /// Lists a directory's immediate contents.
    ///
    /// `.` and `..` are filtered out — they are an artefact of the wire protocol, not entries a user
    /// should see.
    ///
    /// - Parameter directory: The directory to list.
    /// - Returns: The entries, in server order.
    /// - Throws: ``SessionError/notFound(_:)``, ``SessionError/notADirectory(_:)``, or
    ///   ``SessionError/accessDenied(_:)``.
    public func list(_ directory: RemotePath) async throws -> [RemoteItem] {
        let sftp = try requireSFTP()

        do {
            // Citadel returns readdir responses in batches, so this is a list of lists.
            let batches = try await sftp.listDirectory(atPath: directory.pathString)

            return batches.flatMap(\.components).compactMap { component in
                let name = component.filename
                guard name != ".", name != ".." else { return nil }

                return SFTPAttributeMapping.item(
                    from: component.attributes,
                    at: directory.appending(name)
                )
            }
        } catch {
            throw SFTPErrorMapping.map(error, path: directory)
        }
    }

    /// Fetches metadata for one entry.
    ///
    /// Uses SFTP's `stat`, which follows symbolic links — so this reports the target's attributes, not
    /// the link's.
    ///
    /// - Parameter path: The entry to inspect.
    /// - Returns: The entry's metadata.
    /// - Throws: ``SessionError/notFound(_:)`` if nothing exists there.
    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        let sftp = try requireSFTP()
        do {
            let attributes = try await sftp.getAttributes(at: path.pathString)
            return SFTPAttributeMapping.item(from: attributes, at: path)
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }
    }

    // MARK: - Changing the namespace

    /// Creates a directory. The parent must already exist.
    ///
    /// - Parameter path: Where to create it.
    /// - Throws: ``SessionError/alreadyExists(_:)`` if something is already there.
    public func createDirectory(_ path: RemotePath) async throws {
        let sftp = try requireSFTP()
        do {
            try await sftp.createDirectory(atPath: path.pathString)
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }
    }

    /// Deletes a file, symbolic link, or empty directory.
    ///
    /// SFTP has separate operations for files and directories with no way to ask "delete whatever this
    /// is", so the entry is stat'ed first to choose between them. That costs a round trip, which is the
    /// honest price of the protocol not offering an alternative.
    ///
    /// Non-empty directories are refused — this backend does not advertise
    /// ``SessionCapabilities/recursiveDelete``, so callers must walk the tree themselves.
    ///
    /// - Parameter path: What to delete.
    /// - Throws: ``SessionError/directoryNotEmpty(_:)`` for a directory with contents.
    public func delete(_ path: RemotePath) async throws {
        let sftp = try requireSFTP()
        let item = try await stat(path)

        do {
            if item.isDirectory {
                try await sftp.rmdir(at: path.pathString)
            } else {
                try await sftp.remove(at: path.pathString)
            }
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }
    }

    /// Renames or moves an entry.
    ///
    /// - Parameters:
    ///   - source: What to move.
    ///   - destination: Where it should end up.
    /// - Throws: ``SessionError/alreadyExists(_:)`` if the destination is occupied.
    public func move(_ source: RemotePath, to destination: RemotePath) async throws {
        try require(.rename, for: "renaming")
        let sftp = try requireSFTP()

        do {
            try await sftp.rename(at: source.pathString, to: destination.pathString)
        } catch {
            throw SFTPErrorMapping.map(error, path: destination)
        }
    }

    // MARK: - Transferring bytes

    /// Streams a file's contents from `offset` to the end.
    ///
    /// The stream is produced by a task that reads chunks in a loop. Two details matter:
    ///
    /// - **Short reads are normal.** A server may return fewer bytes than asked for without being at
    ///   EOF, so the loop continues until a read comes back empty rather than trusting one call.
    /// - **Cancellation is honoured.** `onTermination` cancels the producing task, so abandoning the
    ///   `for try await` — because the user cancelled the transfer — stops the network work rather than
    ///   downloading the rest of the file into a stream nobody is reading.
    ///
    /// - Parameters:
    ///   - path: The file to read.
    ///   - offset: Byte offset to start at.
    /// - Returns: A stream of chunks.
    /// - Throws: ``SessionError/notFound(_:)`` if the file does not exist.
    public func read(
        _ path: RemotePath,
        from offset: Int64
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        if offset > 0 {
            try require(.resumeDownload, for: "resuming a download")
        }
        let sftp = try requireSFTP()

        let file: SFTPFileHandle
        do {
            file = SFTPFileHandle(try await sftp.openFile(filePath: path.pathString, flags: .read))
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }

        let chunkSize = self.chunkSize

        return AsyncThrowingStream { continuation in
            let task = Task {
                var position = UInt64(offset)
                do {
                    while true {
                        try Task.checkCancellation()

                        let buffer = try await file.read(from: position, length: chunkSize)
                        guard buffer.readableBytes > 0 else { break }

                        position += UInt64(buffer.readableBytes)
                        continuation.yield(Data(buffer.readableBytesView))
                    }
                    try? await file.close()
                    continuation.finish()
                } catch let error as SFTPError {
                    try? await file.close()
                    // Some servers signal end-of-file with a status rather than an empty read.
                    if case .errorStatus(let status) = error, status.errorCode == .eof {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: SFTPErrorMapping.map(error, path: path))
                    }
                } catch {
                    try? await file.close()
                    continuation.finish(throwing: SFTPErrorMapping.map(error, path: path))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes a file from a stream of chunks, returning only once every byte is committed.
    ///
    /// - Parameters:
    ///   - path: Where to write.
    ///   - contents: The bytes to write.
    ///   - size: Total size if known. Unused by SFTP, which needs no length up front — unlike S3.
    ///   - offset: Byte offset to resume at.
    /// - Throws: ``SessionError/insufficientStorage`` or ``SessionError/accessDenied(_:)``.
    public func write(
        _ path: RemotePath,
        contents: AsyncThrowingStream<Data, any Error>,
        size: Int64?,
        resumingAt offset: Int64
    ) async throws {
        if offset > 0 {
            try require(.resumeUpload, for: "resuming an upload")
        }
        let sftp = try requireSFTP()

        // Resuming must not truncate: the point is to keep the bytes already there. A fresh upload
        // must truncate, or writing a shorter file over a longer one leaves the old tail behind.
        let flags: SFTPOpenFileFlags = offset > 0
            ? [.write, .create]
            : [.write, .create, .truncate]

        let file: SFTPFileHandle
        do {
            file = SFTPFileHandle(try await sftp.openFile(filePath: path.pathString, flags: flags))
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }

        do {
            var position = UInt64(offset)
            for try await chunk in contents {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }

                try await file.write(ByteBuffer(bytes: chunk), at: position)
                position += UInt64(chunk.count)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw SFTPErrorMapping.map(error, path: path)
        }
    }

    // MARK: - Metadata

    /// Changes an entry's Unix permissions.
    ///
    /// - Parameters:
    ///   - permissions: The mode to set.
    ///   - path: The entry to change.
    /// - Throws: ``SessionError/accessDenied(_:)`` if the server refuses.
    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        try require(.posixPermissions, for: "changing permissions")
        let sftp = try requireSFTP()

        do {
            try await sftp.setAttributes(
                at: path.pathString,
                to: SFTPAttributeMapping.attributes(forPermissions: permissions)
            )
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }
    }

    /// Sets an entry's modification date, which is what preserves a file's date across a transfer.
    ///
    /// - Parameters:
    ///   - date: The timestamp to set.
    ///   - path: The entry to change.
    /// - Throws: ``SessionError/accessDenied(_:)`` if the server refuses.
    public func setModificationDate(_ date: Date, at path: RemotePath) async throws {
        try require(.timestamps, for: "changing the modification date")
        let sftp = try requireSFTP()

        do {
            try await sftp.setAttributes(
                at: path.pathString,
                to: SFTPAttributeMapping.attributes(forModificationDate: date)
            )
        } catch {
            throw SFTPErrorMapping.map(error, path: path)
        }
    }

    // MARK: - Helpers

    /// Returns the live SFTP client, or throws if the session is not connected.
    private func requireSFTP() throws -> SFTPClient {
        guard let sftp else { throw SessionError.notConnected }
        return sftp
    }

    /// Builds Citadel's authentication method from our protocol-neutral credentials.
    ///
    /// - Parameter credentials: What the user supplied.
    /// - Returns: The matching Citadel authentication method.
    /// - Throws: ``SessionError/authenticationFailed(reason:)`` if the key cannot be parsed or the
    ///   method is not supported over SSH.
    static func authenticationMethod(for credentials: Credentials) throws -> SSHAuthenticationMethod {
        switch credentials.method {
        case .password(let password):
            return .passwordBased(username: credentials.username, password: password)

        case .anonymous:
            // SSH has no anonymous mode. Servers that allow empty passwords still expect the exchange.
            return .passwordBased(username: credentials.username, password: "")

        case .privateKey(let data, let passphrase):
            return try privateKeyMethod(
                username: credentials.username,
                data: data,
                passphrase: passphrase
            )

        case .token:
            throw SessionError.authenticationFailed(reason: "SSH does not support token authentication")
        }
    }

    /// Parses an OpenSSH private key and builds the matching authentication method.
    ///
    /// Ed25519 is tried before RSA because it is the modern default; the key's own header decides which
    /// parser succeeds, so trying in order is how the algorithm is detected without parsing twice.
    private static func privateKeyMethod(
        username: String,
        data: Data,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let decryptionKey = passphrase.map { Data($0.utf8) }

        if let ed25519 = try? Curve25519.Signing.PrivateKey(sshEd25519: data, decryptionKey: decryptionKey) {
            return .ed25519(username: username, privateKey: ed25519)
        }
        if let rsa = try? Insecure.RSA.PrivateKey(sshRsa: data, decryptionKey: decryptionKey) {
            return .rsa(username: username, privateKey: rsa)
        }

        throw SessionError.authenticationFailed(
            reason: passphrase == nil
                ? "the private key could not be read — it may need a passphrase"
                : "the private key could not be read, or the passphrase is wrong"
        )
    }
}
