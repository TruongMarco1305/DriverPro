//
//  CitadelHandles.swift
//  DPProtocolSFTP
//

import Citadel
import Foundation
import NIOCore

// MARK: - Why this file exists
//
// Citadel annotates `SFTPClient` as `Sendable` but leaves `SSHClient` and `SFTPFile` unmarked. All three
// are thin wrappers over the same thread-safe NIO channel machinery, so the omission looks like an
// oversight rather than a statement that they are unsafe — but the compiler cannot know that, and it is
// right not to guess.
//
// ## Swift note — the actor boundary and `sending`
//
// The error this file resolves is:
//
//     error: sending 'client' risks causing data races
//
// It appears when actor-isolated code calls an `async` method on a **non-Sendable** value. Calling an
// `async` function from an actor may resume on a different thread, so the value is "sent" across an
// isolation boundary — and the compiler only permits that for `Sendable` types.
//
// The key insight is that the boundary is crossed *once*, on the way in. Inside a `Sendable` wrapper
// every call is ordinary nonisolated code, where no boundary exists and non-Sendable values are free to
// move around. So wrapping confines the unchecked assertion to one place instead of spreading
// `@unchecked` across every call site.
//
// ## `@unchecked Sendable` is a promise, not a fix
//
// It tells the compiler to stop checking. The obligation then falls to us, and it is discharged here by
// two arguments:
//
//  1. Both types wrap a NIO `Channel` and communicate through `EventLoopPromise`, which are thread-safe
//     by design. Citadel marks the closely-related `SFTPClient` `Sendable` for exactly that reason.
//  2. DriverPro's own use is single-owner regardless: an `SFTPFile` is touched only by the one task
//     driving its transfer loop, and the `SSHClient` only by its owning `SFTPSession` actor.
//
// If Citadel later marks these `Sendable`, this file collapses to nothing. That is the intended outcome.

/// A `Sendable` handle to Citadel's `SSHClient`.
///
/// See the file comment for why the `@unchecked` conformance is justified.
final class SSHClientHandle: @unchecked Sendable {

    private let client: SSHClient

    /// Wraps a connected client.
    /// - Parameter client: The client to take ownership of.
    init(_ client: SSHClient) {
        self.client = client
    }

    /// Opens the SFTP subsystem on this connection.
    ///
    /// - Returns: The SFTP client, which *is* `Sendable` and so needs no wrapper.
    /// - Throws: Whatever Citadel throws if the subsystem cannot be started.
    func openSFTP() async throws -> SFTPClient {
        try await client.openSFTP()
    }

    /// Closes the SSH connection.
    /// - Throws: Whatever Citadel throws while shutting down.
    func close() async throws {
        try await client.close()
    }
}

/// A `Sendable` handle to Citadel's `SFTPFile`.
///
/// Needed because an open file is captured by the closure that produces a download's
/// `AsyncThrowingStream`, which the compiler treats as crossing an isolation boundary.
final class SFTPFileHandle: @unchecked Sendable {

    private let file: SFTPFile

    /// Wraps an open file.
    /// - Parameter file: The file to take ownership of.
    init(_ file: SFTPFile) {
        self.file = file
    }

    /// Reads up to `length` bytes starting at `offset`.
    ///
    /// May return fewer bytes than requested without being at end of file — callers must loop.
    ///
    /// - Parameters:
    ///   - offset: Byte offset to read from.
    ///   - length: Maximum number of bytes to return.
    /// - Returns: The bytes read. Empty at end of file.
    /// - Throws: Whatever Citadel throws on a failed read.
    func read(from offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try await file.read(from: offset, length: length)
    }

    /// Writes bytes at an offset.
    ///
    /// - Parameters:
    ///   - buffer: The bytes to write.
    ///   - offset: Byte offset to write at.
    /// - Throws: Whatever Citadel throws on a failed write.
    func write(_ buffer: ByteBuffer, at offset: UInt64) async throws {
        try await file.write(buffer, at: offset)
    }

    /// Closes the file handle.
    /// - Throws: Whatever Citadel throws while closing.
    func close() async throws {
        try await file.close()
    }
}
