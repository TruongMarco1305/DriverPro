//
//  SessionContractTests.swift
//  DPCoreTests
//

import Foundation
import Testing
import DPCore
import DPTestSupport

@Suite("SessionCapabilities")
struct SessionCapabilitiesTests {

    @Test("Every capability occupies a distinct bit")
    func bitsAreDistinct() {
        // A copy-pasted `1 << 4` in two places would silently make two capabilities the same flag, and
        // the symptom would be a menu item that enables itself for the wrong protocol. Catch it here.
        let all: [SessionCapabilities] = [
            .rename, .serverSideCopy, .emptyDirectories, .recursiveDelete, .symbolicLinks,
            .posixPermissions, .timestamps, .ownership, .versioning, .quota,
            .resumeDownload, .resumeUpload, .segmentedTransfer, .checksum
        ]
        #expect(Set(all.map(\.rawValue)).count == all.count)

        let union = all.reduce(into: SessionCapabilities()) { $0.formUnion($1) }
        #expect(union.rawValue.nonzeroBitCount == all.count)
    }

    @Test("Set algebra behaves as expected")
    func setAlgebra() {
        let posix = SessionCapabilities.posixFileSystem
        #expect(posix.contains(.rename))
        #expect(posix.contains(.posixPermissions))
        #expect(!posix.contains(.versioning))
        #expect(!posix.contains(.serverSideCopy))

        // An S3-shaped capability set: no rename, no permissions, but server-side copy and versioning.
        let s3: SessionCapabilities = [.serverSideCopy, .versioning, .resumeDownload, .segmentedTransfer]
        #expect(!s3.contains(.rename))
        #expect(s3.subtracting(posix) == [.serverSideCopy, .versioning, .segmentedTransfer])
    }

    @Test("description names the flags that are set")
    func readableDescription() {
        // The point is that a failing assertion says which capability was missing, not "rawValue: 3169".
        let capabilities: SessionCapabilities = [.rename, .versioning]
        #expect(capabilities.description == "[rename, versioning]")
        #expect(SessionCapabilities.none.description == "[]")
    }
}

/// Rules every backend must obey, exercised against ``MemorySession``.
///
/// When a real protocol target lands, these expectations are the ones it has to satisfy too.
@Suite("Session contract")
struct SessionContractTests {

    /// A connected session seeded with a small tree.
    ///
    /// ## Swift note — `async` fixtures
    /// A helper rather than a stored property, because setting one up needs `await` and stored property
    /// initialisers cannot suspend. Swift Testing creates a fresh suite instance per test, so there is no
    /// state shared between tests regardless.
    private func makeSession(
        capabilities: SessionCapabilities = .posixFileSystem
    ) async throws -> MemorySession {
        let session = MemorySession(capabilities: capabilities)
        try await session.connect(credentials: nil, delegate: ScriptedDelegate())
        await session.seed(directory: RemotePath("/srv/data"))
        await session.seed(file: RemotePath("/srv/data/readme.txt"), contents: Data("hello world".utf8))
        await session.seed(file: RemotePath("/srv/data/nested/deep.bin"), contents: Data(repeating: 0xAB, count: 20))
        return session
    }

    // MARK: - Connection

    @Test("Operations before connecting fail rather than pretending to work")
    func requiresConnection() async {
        let session = MemorySession()
        await #expect(throws: SessionError.notConnected) {
            _ = try await session.list(.root)
        }
    }

    @Test("Rejecting the host key aborts the connection")
    func hostKeyRejectionAborts() async {
        let session = MemorySession()
        let delegate = ScriptedDelegate(hostKeyDecision: .reject)

        await #expect(throws: SessionError.hostKeyRejected) {
            try await session.connect(credentials: nil, delegate: delegate)
        }
        #expect(await !session.isConnected)
    }

    @Test("Cancelling the credential prompt fails authentication")
    func cancelledCredentialsFail() async {
        let session = MemorySession()
        let delegate = ScriptedDelegate(hostKeyDecision: .acceptOnce, credentials: nil)

        await #expect(throws: SessionError.authenticationFailed(reason: "cancelled")) {
            try await session.connect(credentials: nil, delegate: delegate)
        }
    }

    // MARK: - Listing

    @Test("list returns immediate children only")
    func listsImmediateChildren() async throws {
        let session = try await makeSession()
        let names = try await session.list(RemotePath("/srv/data")).map(\.name).sorted()
        #expect(names == ["nested", "readme.txt"])
    }

    @Test("list reports sizes and kinds")
    func listReportsMetadata() async throws {
        let session = try await makeSession()
        let items = try await session.list(RemotePath("/srv/data"))

        let file = try #require(items.first { $0.name == "readme.txt" })
        #expect(file.kind == .file)
        #expect(file.size == 11)
        #expect(!file.isDirectory)

        let directory = try #require(items.first { $0.name == "nested" })
        #expect(directory.kind == .directory)
        #expect(directory.isDirectory)
    }

    @Test("Listing something that is not a directory is an error, not an empty array")
    func listingAFileThrows() async throws {
        let session = try await makeSession()
        await #expect(throws: SessionError.notADirectory(RemotePath("/srv/data/readme.txt"))) {
            _ = try await session.list(RemotePath("/srv/data/readme.txt"))
        }
    }

    @Test("Listing a missing directory reports notFound")
    func listingMissingThrows() async throws {
        let session = try await makeSession()
        await #expect(throws: SessionError.notFound(RemotePath("/nope"))) {
            _ = try await session.list(RemotePath("/nope"))
        }
    }

    // MARK: - Reading and writing

    @Test("read streams the whole file across several chunks")
    func readStreamsInChunks() async throws {
        let session = try await makeSession()

        var received = Data()
        var chunkCount = 0
        for try await chunk in try await session.read(RemotePath("/srv/data/readme.txt"), from: 0) {
            received.append(chunk)
            chunkCount += 1
        }

        #expect(String(decoding: received, as: UTF8.self) == "hello world")
        // 11 bytes at the 8-byte default chunk size: proof the consumer must accumulate, not assume one chunk.
        #expect(chunkCount == 2)
    }

    @Test("read honours a resume offset")
    func readFromOffset() async throws {
        let session = try await makeSession()

        var received = Data()
        for try await chunk in try await session.read(RemotePath("/srv/data/readme.txt"), from: 6) {
            received.append(chunk)
        }
        #expect(String(decoding: received, as: UTF8.self) == "world")
    }

    @Test("A round trip through write and read preserves the bytes")
    func writeThenRead() async throws {
        let session = try await makeSession()
        let destination = RemotePath("/srv/data/upload.bin")
        let payload = Data((0..<200).map { UInt8($0 % 251) })

        try await session.write(
            destination,
            contents: Self.stream(of: payload, chunkSize: 32),
            size: Int64(payload.count),
            resumingAt: 0
        )

        #expect(try await session.stat(destination).size == 200)

        var received = Data()
        for try await chunk in try await session.read(destination, from: 0) {
            received.append(chunk)
        }
        #expect(received == payload)
    }

    @Test("Writing into a missing directory fails instead of creating it implicitly")
    func writeRequiresParent() async throws {
        let session = try await makeSession()
        await #expect(throws: SessionError.notFound(RemotePath("/srv/missing"))) {
            try await session.write(
                RemotePath("/srv/missing/file.txt"),
                contents: Self.stream(of: Data("x".utf8), chunkSize: 8),
                size: 1,
                resumingAt: 0
            )
        }
    }

    // MARK: - Capability gating

    @Test("A backend without rename refuses the operation and names what is missing")
    func renameRequiresCapability() async throws {
        // An S3-shaped session: no rename bit.
        let session = try await makeSession(capabilities: [.serverSideCopy, .resumeDownload])

        await #expect(throws: SessionError.unsupported(.rename, operation: "renaming")) {
            try await session.move(RemotePath("/srv/data/readme.txt"), to: RemotePath("/srv/data/other.txt"))
        }
    }

    @Test("unsupported reports only the capabilities actually missing")
    func unsupportedNamesMissingOnly() async throws {
        let session = try await makeSession(capabilities: [.rename])

        // Asking for two capabilities when only one is absent must not blame both.
        let error = await #expect(throws: SessionError.self) {
            try await session.setPermissions(.defaultFile, at: RemotePath("/srv/data/readme.txt"))
        }
        #expect(error == .unsupported(.posixPermissions, operation: "changing permissions"))
    }

    @Test("Resuming a download is refused when the backend cannot seek")
    func resumeRequiresCapability() async throws {
        let session = try await makeSession(capabilities: [])
        await #expect(throws: SessionError.unsupported(.resumeDownload, operation: "resuming a download")) {
            _ = try await session.read(RemotePath("/srv/data/readme.txt"), from: 4)
        }
    }

    @Test("A capable backend allows the same operations")
    func capableBackendSucceeds() async throws {
        let session = try await makeSession()
        let source = RemotePath("/srv/data/readme.txt")
        let destination = RemotePath("/srv/data/renamed.txt")

        try await session.move(source, to: destination)
        #expect(await !session.exists(source))
        #expect(await session.exists(destination))
    }

    @Test("Moving a directory carries its contents with it")
    func moveCarriesSubtree() async throws {
        let session = try await makeSession()
        try await session.move(RemotePath("/srv/data/nested"), to: RemotePath("/srv/moved"))

        #expect(await session.exists(RemotePath("/srv/moved/deep.bin")))
        #expect(await !session.exists(RemotePath("/srv/data/nested/deep.bin")))
    }

    // MARK: - Deletion

    @Test("Deleting a non-empty directory needs recursiveDelete")
    func deleteNonEmptyRequiresCapability() async throws {
        let session = try await makeSession(capabilities: SessionCapabilities.posixFileSystem.subtracting(.recursiveDelete))

        await #expect(throws: SessionError.directoryNotEmpty(RemotePath("/srv/data"))) {
            try await session.delete(RemotePath("/srv/data"))
        }
    }

    @Test("With recursiveDelete the whole subtree goes")
    func recursiveDeleteRemovesSubtree() async throws {
        let session = try await makeSession()
        try await session.delete(RemotePath("/srv/data"))

        #expect(await !session.exists(RemotePath("/srv/data")))
        #expect(await !session.exists(RemotePath("/srv/data/nested/deep.bin")))
    }

    @Test("createDirectory refuses to overwrite and requires its parent")
    func createDirectoryPreconditions() async throws {
        let session = try await makeSession()

        await #expect(throws: SessionError.alreadyExists(RemotePath("/srv/data"))) {
            try await session.createDirectory(RemotePath("/srv/data"))
        }
        await #expect(throws: SessionError.notFound(RemotePath("/srv/absent"))) {
            try await session.createDirectory(RemotePath("/srv/absent/child"))
        }
    }

    // MARK: - Error classification

    @Test("Transient failures are retryable and permanent ones are not")
    func retryClassification() {
        #expect(SessionError.timedOut.isRetryable)
        #expect(SessionError.unreachable(host: "h", reason: "down").isRetryable)
        #expect(SessionError.transport("reset").isRetryable)

        #expect(!SessionError.authenticationFailed(reason: "bad password").isRetryable)
        #expect(!SessionError.hostKeyRejected.isRetryable)
        #expect(!SessionError.notFound(.root).isRetryable)
        #expect(!SessionError.cancelled.isRetryable)

        #expect(SessionError.authenticationFailed(reason: "x").needsCredentials)
        #expect(!SessionError.timedOut.needsCredentials)
    }

    @Test("Errors carry a message a user could act on")
    func errorMessages() {
        #expect(SessionError.notFound(RemotePath("/a/b.txt")).errorDescription?.contains("b.txt") == true)
        #expect(SessionError.hostKeyRejected.recoverySuggestion != nil)
        #expect(SessionError.cancelled.recoverySuggestion == nil)
    }

    // MARK: - Helpers

    /// Wraps a `Data` in the chunked stream shape that ``Session/write(_:contents:size:resumingAt:)`` expects.
    private static func stream(of data: Data, chunkSize: Int) -> AsyncThrowingStream<Data, any Error> {
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
}

/// The shared behavioural contract, run against ``MemorySession``.
///
/// The same rules run against `SFTPSession` in `DPProtocolSFTPTests`. Keeping the assertions in
/// `DPTestSupport` rather than duplicating them is what makes "the in-memory fake and the real backend
/// behave identically" a checkable claim instead of a hope.
@Suite("Session contract — MemorySession")
struct MemorySessionContractTests {

    /// A connected session with an empty working directory.
    private func makeFixture() async throws -> SessionContract.Fixture {
        let session = MemorySession(capabilities: .posixFileSystem)
        try await session.connect(credentials: nil, delegate: ScriptedDelegate())

        let workingDirectory = RemotePath("/contract")
        await session.seed(directory: workingDirectory)

        return SessionContract.Fixture(session: session, workingDirectory: workingDirectory)
    }

    @Test("Every contract rule holds")
    func satisfiesContract() async throws {
        try await SessionContract.runAll(makeFixture())
    }

    @Test("A backend without rename or permissions refuses them cleanly")
    func capabilityGatedRulesHold() async throws {
        // An S3-shaped capability set, to prove the contract's own capability gating works: the rename
        // and permission rules must skip, and the "refused cleanly" rule must fire.
        let session = MemorySession(capabilities: [.resumeDownload])
        try await session.connect(credentials: nil, delegate: ScriptedDelegate())
        await session.seed(directory: RemotePath("/contract"))

        let fixture = SessionContract.Fixture(session: session, workingDirectory: RemotePath("/contract"))
        try await SessionContract.unsupportedOperationsAreRefusedCleanly(fixture)
        try await SessionContract.roundTripPreservesBytes(fixture)
    }
}
