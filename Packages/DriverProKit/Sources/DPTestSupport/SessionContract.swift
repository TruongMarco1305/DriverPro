//
//  SessionContract.swift
//  DPTestSupport
//

import DPCore
import Foundation
import Testing

/// The behavioural rules **every** ``Session`` implementation must obey, written once.
///
/// This is the payoff for designing `Session` as a contract rather than as whatever SFTP happened to
/// need. `MemorySession` and `SFTPSession` are run through the identical checks, so:
///
/// - a real backend inherits a suite of behavioural tests for free, and
/// - any place SFTP quietly disagrees with the abstraction shows up as a **failure** rather than as a
///   difference nobody noticed.
///
/// When WebDAV and S3 arrive they are pointed at this same file. If one of them cannot satisfy a rule,
/// that is a finding about the abstraction — the rule either becomes capability-gated or it was never a
/// real rule to begin with.
///
/// ## Swift note — a test suite as a library
/// These live in a *library* target, not a test target, because two different test targets need them.
/// Importing `Testing` outside a test target is allowed: `#expect` works anywhere, and failures are
/// attributed to whichever test called in. `#filePath`/`#line` are forwarded so a failure points at the
/// caller rather than at this file.
public enum SessionContract {

    /// How a test provides a connected, seeded session.
    ///
    /// The contract cannot construct backends itself — one needs a server and the other does not — so it
    /// asks for a session that is already connected, with a writable directory it may do as it likes in.
    public struct Fixture: Sendable {
        /// A connected session.
        public let session: any Session
        /// A directory the contract may freely create, modify, and delete entries in.
        public let workingDirectory: RemotePath

        /// Creates a fixture.
        ///
        /// - Parameters:
        ///   - session: A session that is already connected.
        ///   - workingDirectory: An existing, writable, empty directory.
        public init(session: any Session, workingDirectory: RemotePath) {
            self.session = session
            self.workingDirectory = workingDirectory
        }
    }

    // MARK: - The rules

    /// Writing a file then reading it back yields exactly the bytes written.
    ///
    /// The most basic promise a file transfer program makes, and the one worth checking against every
    /// backend: a chunking bug that drops or duplicates a block shows up here and nowhere else.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func roundTripPreservesBytes(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let path = fixture.workingDirectory.appending("round-trip.bin")
        // Deliberately not a multiple of any likely chunk size, so a partial final chunk is exercised.
        let payload = Data((0..<5000).map { UInt8($0 % 251) })

        try await fixture.session.write(path, contents: stream(payload), size: Int64(payload.count), resumingAt: 0)
        let received = try await readAll(fixture.session, path)

        #expect(received == payload, "bytes read back differ from bytes written", sourceLocation: sourceLocation)
        #expect(received.count == payload.count, sourceLocation: sourceLocation)

        try await fixture.session.delete(path)
    }

    /// A written file is reported with the right size and kind.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func statReportsSizeAndKind(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let path = fixture.workingDirectory.appending("stat-me.txt")
        let payload = Data("hello world".utf8)

        try await fixture.session.write(path, contents: stream(payload), size: Int64(payload.count), resumingAt: 0)

        let item = try await fixture.session.stat(path)
        #expect(item.size == 11, sourceLocation: sourceLocation)
        #expect(item.kind == .file, sourceLocation: sourceLocation)
        #expect(!item.isDirectory, sourceLocation: sourceLocation)
        #expect(item.path == path, sourceLocation: sourceLocation)

        try await fixture.session.delete(path)
    }

    /// Listing returns immediate children only, without `.` or `..`.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func listReturnsImmediateChildren(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let root = fixture.workingDirectory.appending("listing")
        let nested = root.appending("nested")
        try await fixture.session.createDirectory(root)
        try await fixture.session.createDirectory(nested)

        let file = root.appending("a.txt")
        try await fixture.session.write(file, contents: stream(Data("a".utf8)), size: 1, resumingAt: 0)

        // A file one level deeper, which must NOT appear in the listing of `root`.
        let deep = nested.appending("b.txt")
        try await fixture.session.write(deep, contents: stream(Data("b".utf8)), size: 1, resumingAt: 0)

        let names = try await fixture.session.list(root).map(\.name).sorted()
        #expect(names == ["a.txt", "nested"], "listing should be immediate children only",
                sourceLocation: sourceLocation)
        #expect(!names.contains("."), "`.` is a wire-protocol artefact and must be filtered",
                sourceLocation: sourceLocation)
        #expect(!names.contains(".."), sourceLocation: sourceLocation)

        try await fixture.session.delete(deep)
        try await fixture.session.delete(nested)
        try await fixture.session.delete(file)
        try await fixture.session.delete(root)
    }

    /// Listing a file, rather than a directory, is an error and not an empty array.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func listingAFileThrows(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let path = fixture.workingDirectory.appending("not-a-directory.txt")
        try await fixture.session.write(path, contents: stream(Data("x".utf8)), size: 1, resumingAt: 0)

        await #expect(throws: (any Error).self, "listing a file must fail, not return []",
                      sourceLocation: sourceLocation) {
            _ = try await fixture.session.list(path)
        }

        try await fixture.session.delete(path)
    }

    /// Statting something that does not exist reports `notFound`.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func missingFileReportsNotFound(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let path = fixture.workingDirectory.appending("definitely-not-here-\(UUID().uuidString)")

        // The specific case matters: the transfer engine retries on transport errors but not on
        // notFound, so a backend reporting the wrong one produces pointless retries.
        await #expect(throws: SessionError.notFound(path), sourceLocation: sourceLocation) {
            _ = try await fixture.session.stat(path)
        }
        #expect(await !fixture.session.exists(path), sourceLocation: sourceLocation)
    }

    /// Creating a directory that already exists is refused.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func createDirectoryRefusesDuplicate(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let path = fixture.workingDirectory.appending("dup-dir")
        try await fixture.session.createDirectory(path)

        await #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
            try await fixture.session.createDirectory(path)
        }

        try await fixture.session.delete(path)
    }

    /// A resumed read starts at the requested offset.
    ///
    /// Skipped automatically when the backend does not advertise ``SessionCapabilities/resumeDownload``,
    /// which is the contract respecting capabilities rather than assuming them.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func resumeReadsFromOffset(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard fixture.session.capabilities.contains(.resumeDownload) else { return }

        let path = fixture.workingDirectory.appending("resume.txt")
        let payload = Data("hello world".utf8)
        try await fixture.session.write(path, contents: stream(payload), size: Int64(payload.count), resumingAt: 0)

        let tail = try await readAll(fixture.session, path, from: 6)
        #expect(String(decoding: tail, as: UTF8.self) == "world", sourceLocation: sourceLocation)

        try await fixture.session.delete(path)
    }

    /// Renaming moves an entry and leaves nothing behind.
    ///
    /// Skipped when the backend has no ``SessionCapabilities/rename`` — S3, when it lands.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func renameMovesEntry(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard fixture.session.capabilities.contains(.rename) else { return }

        let source = fixture.workingDirectory.appending("before.txt")
        let destination = fixture.workingDirectory.appending("after.txt")
        try await fixture.session.write(source, contents: stream(Data("x".utf8)), size: 1, resumingAt: 0)

        try await fixture.session.move(source, to: destination)

        #expect(await !fixture.session.exists(source), sourceLocation: sourceLocation)
        #expect(await fixture.session.exists(destination), sourceLocation: sourceLocation)

        try await fixture.session.delete(destination)
    }

    /// Permission changes are applied and readable back.
    ///
    /// Skipped when the backend has no ``SessionCapabilities/posixPermissions``.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func permissionsRoundTrip(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard fixture.session.capabilities.contains(.posixPermissions) else { return }

        let path = fixture.workingDirectory.appending("perms.txt")
        try await fixture.session.write(path, contents: stream(Data("x".utf8)), size: 1, resumingAt: 0)

        try await fixture.session.setPermissions(POSIXPermissions(rawValue: 0o600), at: path)
        let item = try await fixture.session.stat(path)
        #expect(item.permissions == POSIXPermissions(rawValue: 0o600), sourceLocation: sourceLocation)

        try await fixture.session.delete(path)
    }

    /// An operation the backend does not support throws `unsupported` rather than failing obscurely.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func unsupportedOperationsAreRefusedCleanly(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let capabilities = fixture.session.capabilities

        if !capabilities.contains(.rename) {
            let source = fixture.workingDirectory.appending("a")
            let destination = fixture.workingDirectory.appending("b")
            await #expect(throws: SessionError.unsupported(.rename, operation: "renaming"),
                          sourceLocation: sourceLocation) {
                try await fixture.session.move(source, to: destination)
            }
        }

        if !capabilities.contains(.posixPermissions) {
            await #expect(throws: SessionError.unsupported(.posixPermissions, operation: "changing permissions"),
                          sourceLocation: sourceLocation) {
                try await fixture.session.setPermissions(.defaultFile, at: fixture.workingDirectory.appending("a"))
            }
        }
    }

    /// Deletion actually removes the entry.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func deleteRemovesEntry(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let path = fixture.workingDirectory.appending("delete-me.txt")
        try await fixture.session.write(path, contents: stream(Data("x".utf8)), size: 1, resumingAt: 0)
        #expect(await fixture.session.exists(path), sourceLocation: sourceLocation)

        try await fixture.session.delete(path)
        #expect(await !fixture.session.exists(path), sourceLocation: sourceLocation)
    }

    // MARK: - Running everything

    /// Runs every rule in sequence.
    ///
    /// Sequential rather than concurrent on purpose: the rules share one working directory, and a real
    /// server is a shared resource whose interleaved failures would be hard to attribute.
    ///
    /// - Parameters:
    ///   - fixture: A connected session and a writable directory.
    ///   - sourceLocation: Forwarded so failures point at the calling test.
    public static func runAll(
        _ fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await roundTripPreservesBytes(fixture, sourceLocation: sourceLocation)
        try await statReportsSizeAndKind(fixture, sourceLocation: sourceLocation)
        try await listReturnsImmediateChildren(fixture, sourceLocation: sourceLocation)
        try await listingAFileThrows(fixture, sourceLocation: sourceLocation)
        try await missingFileReportsNotFound(fixture, sourceLocation: sourceLocation)
        try await createDirectoryRefusesDuplicate(fixture, sourceLocation: sourceLocation)
        try await resumeReadsFromOffset(fixture, sourceLocation: sourceLocation)
        try await renameMovesEntry(fixture, sourceLocation: sourceLocation)
        try await permissionsRoundTrip(fixture, sourceLocation: sourceLocation)
        try await unsupportedOperationsAreRefusedCleanly(fixture, sourceLocation: sourceLocation)
        try await deleteRemovesEntry(fixture, sourceLocation: sourceLocation)
    }

    // MARK: - Helpers

    /// Wraps a `Data` in the chunked stream shape `Session.write` expects.
    ///
    /// - Parameters:
    ///   - data: The bytes to send.
    ///   - chunkSize: Bytes per chunk. Small by default so multi-chunk handling is exercised.
    /// - Returns: A stream yielding the data in chunks.
    public static func stream(_ data: Data, chunkSize: Int = 512) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            var start = 0
            while start < data.count {
                let end = min(start + chunkSize, data.count)
                continuation.yield(data.subdata(in: start..<end))
                start = end
            }
            continuation.finish()
        }
    }

    /// Drains a file into one `Data`.
    ///
    /// Only for tests — the whole point of the streaming API is that production code must not do this.
    ///
    /// - Parameters:
    ///   - session: The session to read through.
    ///   - path: The file to read.
    ///   - offset: Byte offset to start at.
    /// - Returns: The file's contents from `offset`.
    public static func readAll(
        _ session: any Session,
        _ path: RemotePath,
        from offset: Int64 = 0
    ) async throws -> Data {
        var received = Data()
        for try await chunk in try await session.read(path, from: offset) {
            received.append(chunk)
        }
        return received
    }
}
