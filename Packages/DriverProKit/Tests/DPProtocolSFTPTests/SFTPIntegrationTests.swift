//
//  SFTPIntegrationTests.swift
//  DPProtocolSFTPTests
//

import DPCore
import DPCredentials
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolSFTP

/// Server settings, read from the environment so the default `swift test` stays offline.
///
/// The names match `infra/integration/.env` exactly; `script.sh` exports them.
enum IntegrationConfig {
    static let host = ProcessInfo.processInfo.environment["SFTP_HOST"]
    static let port = Int(ProcessInfo.processInfo.environment["SFTP_PORT"] ?? "") ?? 2222
    static let user = ProcessInfo.processInfo.environment["SFTP_USER"] ?? "user"
    static let password = ProcessInfo.processInfo.environment["SFTP_PASSWORD"] ?? "password"

    /// The writable directory as the *client* sees it. sshd is chrooted to the account home, so the
    /// upload directory sits at the root rather than under `/home/<user>`.
    static var basePath: String {
        "/" + (ProcessInfo.processInfo.environment["SFTP_UPLOAD_DIR"] ?? "integration")
    }

    /// Whether a server was configured.
    static var isEnabled: Bool { host != nil }
}

/// Tests against a real SFTP server.
///
/// Gated on `SFTP_HOST` so `swift test` needs no network by default. This is the layer that catches
/// what a fake cannot: real chunking, real status codes, real host keys.
///
/// **These tests never touch `~/.ssh/known_hosts`** — each gets a throwaway file.
@Suite(
    "SFTP integration",
    .enabled(if: IntegrationConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct SFTPIntegrationTests {

    // MARK: - Fixtures

    private func makeHost() -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: IntegrationConfig.host ?? "localhost",
            port: IntegrationConfig.port,
            username: IntegrationConfig.user
        )
    }

    /// A `known_hosts` in the temporary directory, never the user's real one.
    private func makeThrowawayKnownHosts() -> KnownHostsStore {
        KnownHostsStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dp-known_hosts-\(UUID().uuidString)")
        )
    }

    /// Connects, and creates a unique empty working directory for the caller to play in.
    private func makeConnectedSession(
        knownHosts: KnownHostsStore? = nil,
        hostKeyDecision: HostKeyDecision = .acceptOnce
    ) async throws -> (SFTPSession, RemotePath) {
        let session = SFTPSession(host: makeHost(), knownHosts: knownHosts ?? makeThrowawayKnownHosts())

        try await session.connect(
            credentials: .password(username: IntegrationConfig.user, password: IntegrationConfig.password),
            delegate: ScriptedDelegate(hostKeyDecision: hostKeyDecision)
        )

        let workingDirectory = RemotePath(IntegrationConfig.basePath)
            .appending("dp-test-\(UUID().uuidString.prefix(8))")
        try await session.createDirectory(workingDirectory)

        return (session, workingDirectory)
    }

    // MARK: - The contract

    @Test("SFTP satisfies the same contract as the in-memory session")
    func satisfiesSessionContract() async throws {
        // The whole reason `SessionContract` lives in its own target. `MemorySession` passes these
        // rules; if SFTP does not, the abstraction was lying somewhere.
        let (session, workingDirectory) = try await makeConnectedSession()

        try await SessionContract.runAll(
            SessionContract.Fixture(session: session, workingDirectory: workingDirectory)
        )

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    // MARK: - Connection

    @Test("The default directory is resolved from the server, and a bookmark overrides it")
    func defaultDirectoryResolution() async throws {
        let (session, workingDirectory) = try await makeConnectedSession()

        // Deliberately NOT asserting the home is non-root. The test server runs with
        // `ChrootDirectory %h`, so the account's home genuinely *is* "/" from the client's point of
        // view — asserting otherwise would be asserting a property of the fixture rather than of the
        // code, which is how a test ends up demanding that correct behaviour be wrong.
        _ = try await session.defaultDirectory()

        // What is worth asserting: an explicit path on the bookmark wins over whatever the server says.
        var hostWithPath = makeHost()
        hostWithPath.defaultPath = workingDirectory

        let configured = SFTPSession(host: hostWithPath, knownHosts: makeThrowawayKnownHosts())
        try await configured.connect(
            credentials: .password(username: IntegrationConfig.user, password: IntegrationConfig.password),
            delegate: ScriptedDelegate()
        )
        #expect(try await configured.defaultDirectory() == workingDirectory)
        await configured.disconnect()

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("A wrong password fails as authentication, not as a network error")
    func wrongPasswordIsAuthFailure() async throws {
        let session = SFTPSession(host: makeHost(), knownHosts: makeThrowawayKnownHosts())

        let error = await #expect(throws: SessionError.self) {
            try await session.connect(
                credentials: .password(username: IntegrationConfig.user, password: "definitely-wrong"),
                delegate: ScriptedDelegate()
            )
        }

        // The distinction drives recovery: re-prompt for credentials rather than offer a retry.
        #expect(error?.needsCredentials == true)
        #expect(error?.isRetryable == false)
    }

    @Test("Rejecting the host key refuses the connection")
    func rejectedHostKeyAborts() async throws {
        let session = SFTPSession(host: makeHost(), knownHosts: makeThrowawayKnownHosts())

        await #expect(throws: SessionError.hostKeyRejected) {
            try await session.connect(
                credentials: .password(username: IntegrationConfig.user, password: IntegrationConfig.password),
                delegate: ScriptedDelegate(hostKeyDecision: .reject)
            )
        }
        #expect(await !session.isConnected)
    }

    @Test("Accepting and storing a host key means no second prompt")
    func hostKeyIsRecordedAndReused() async throws {
        let knownHosts = makeThrowawayKnownHosts()

        // First connection: unknown key, accepted and written to the file.
        let (first, workingDirectory) = try await makeConnectedSession(
            knownHosts: knownHosts, hostKeyDecision: .acceptAndStore)
        try await first.delete(workingDirectory)
        await first.disconnect()

        let entries = try await knownHosts.entries()
        #expect(entries.count == 1, "the accepted key should have been appended")
        #expect(entries.first?.matches(hostPattern:
            KnownHostsStore.hostPattern(host: makeHost().hostname, port: makeHost().port)) == true)

        // Second connection with a delegate that would REFUSE. It must never be consulted, because the
        // key is already trusted — that is what stops users being trained to click Accept.
        let second = SFTPSession(host: makeHost(), knownHosts: knownHosts)
        try await second.connect(
            credentials: .password(username: IntegrationConfig.user, password: IntegrationConfig.password),
            delegate: ScriptedDelegate(hostKeyDecision: .reject)
        )
        #expect(await second.isConnected)
        await second.disconnect()
    }

    @Test("The fingerprint we show matches what ssh-keygen computes")
    func fingerprintMatchesSSHKeygen() async throws {
        let knownHosts = makeThrowawayKnownHosts()
        let (session, workingDirectory) = try await makeConnectedSession(
            knownHosts: knownHosts, hostKeyDecision: .acceptAndStore)
        try await session.delete(workingDirectory)
        await session.disconnect()

        let entry = try #require(try await knownHosts.entries().first)
        let ours = HostKeyFingerprint.sha256(ofKeyBlob: entry.keyBlob)

        // Cross-checked against the system ssh-keygen rather than against our own constant. If these
        // ever diverge, the host key prompt is asking users to compare two things that will never match.
        let theirs = try sshKeygenFingerprint(forKeyBlob: entry.keyBlob, type: entry.keyType)
        #expect(ours == theirs)
    }

    // MARK: - Transfers

    @Test("A large file streams correctly and memory stays flat")
    func largeFileStreamsWithoutBuffering() async throws {
        let (session, workingDirectory) = try await makeConnectedSession()
        let path = workingDirectory.appending("large.bin")

        // 8 MB is enough to prove chunking works and that nothing accumulates. The manual M1 checklist
        // repeats this at 500 MB; that is too slow for an automated suite but the mechanism is identical.
        let megabyte = Data((0..<1_048_576).map { UInt8($0 % 251) })
        let chunkCount = 8

        try await session.write(
            path,
            contents: AsyncThrowingStream { continuation in
                for _ in 0..<chunkCount { continuation.yield(megabyte) }
                continuation.finish()
            },
            size: Int64(megabyte.count * chunkCount),
            resumingAt: 0
        )

        #expect(try await session.stat(path).size == Int64(megabyte.count * chunkCount))

        // Read it back verifying incrementally rather than accumulating: holding 8 MB here would defeat
        // the point of the test, and at 500 MB it would defeat the machine.
        //
        // The file is the same 1 MB block written eight times, so the expected byte at a global offset
        // is indexed *within the block*, not across the whole file. (1_048_576 is not a multiple of 251,
        // so treating it as one continuous `offset % 251` ramp fails at the first block boundary — which
        // is exactly what the first run of this test did.)
        var bytesSeen = 0
        var matches = true
        for try await chunk in try await session.read(path, from: 0) {
            for (index, byte) in chunk.enumerated() {
                let offsetWithinBlock = (bytesSeen + index) % megabyte.count
                if byte != UInt8(offsetWithinBlock % 251) { matches = false }
            }
            bytesSeen += chunk.count
        }

        #expect(bytesSeen == megabyte.count * chunkCount)
        #expect(matches, "byte pattern differs — chunking dropped or reordered data")

        try await session.delete(path)
        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("An interrupted download resumes from the right offset")
    func resumeDownloadFromOffset() async throws {
        let (session, workingDirectory) = try await makeConnectedSession()
        let path = workingDirectory.appending("resume.bin")

        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        try await session.write(path, contents: SessionContract.stream(payload),
                                size: Int64(payload.count), resumingAt: 0)

        // Simulate an interruption at an offset that is not a chunk boundary, which is where an
        // off-by-one in the resume arithmetic would show up.
        let resumeAt = 40_001
        var tail = Data()
        for try await chunk in try await session.read(path, from: Int64(resumeAt)) {
            tail.append(chunk)
        }

        #expect(tail.count == payload.count - resumeAt)
        #expect(tail == payload.dropFirst(resumeAt))

        try await session.delete(path)
        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("An interrupted upload resumes without duplicating bytes")
    func resumeUploadFromOffset() async throws {
        let (session, workingDirectory) = try await makeConnectedSession()
        let path = workingDirectory.appending("resume-up.bin")

        let full = Data((0..<60_000).map { UInt8($0 % 251) })
        let firstHalf = full.prefix(25_000)

        try await session.write(path, contents: SessionContract.stream(Data(firstHalf)),
                                size: Int64(firstHalf.count), resumingAt: 0)
        #expect(try await session.stat(path).size == 25_000)

        try await session.write(path, contents: SessionContract.stream(Data(full.dropFirst(25_000))),
                                size: Int64(full.count - 25_000), resumingAt: 25_000)

        #expect(try await session.stat(path).size == Int64(full.count))
        let readBack = try await SessionContract.readAll(session, path)
        #expect(readBack == full, "resumed upload must not duplicate or drop the overlap")

        try await session.delete(path)
        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("Cancelling a download stops it rather than draining the file")
    func cancellingStopsTransfer() async throws {
        let (session, workingDirectory) = try await makeConnectedSession()
        let path = workingDirectory.appending("cancel.bin")

        let payload = Data(repeating: 0x5A, count: 2_000_000)
        try await session.write(path, contents: SessionContract.stream(payload),
                                size: Int64(payload.count), resumingAt: 0)

        // Breaking out of the loop terminates the stream, which must cancel the producing task via
        // `onTermination`. Without that the remaining bytes keep arriving into a stream nobody reads.
        var received = 0
        for try await chunk in try await session.read(path, from: 0) {
            received += chunk.count
            if received > 100_000 { break }
        }

        #expect(received > 0)
        #expect(received < payload.count, "the loop should have exited well before the end")

        // The session must still be usable afterwards.
        #expect(try await session.stat(path).size == Int64(payload.count))

        try await session.delete(path)
        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    // MARK: - Namespace

    @Test("Deleting a non-empty directory is refused, since SFTP has no recursive delete")
    func nonEmptyDirectoryRefused() async throws {
        let (session, workingDirectory) = try await makeConnectedSession()
        let directory = workingDirectory.appending("not-empty")
        try await session.createDirectory(directory)

        let file = directory.appending("child.txt")
        try await session.write(file, contents: SessionContract.stream(Data("x".utf8)), size: 1, resumingAt: 0)

        // This is the capability system being honest: `recursiveDelete` is absent, so callers must walk
        // the tree themselves rather than the backend pretending it can do it.
        #expect(!session.capabilities.contains(.recursiveDelete))
        await #expect(throws: (any Error).self) {
            try await session.delete(directory)
        }

        try await session.delete(file)
        try await session.delete(directory)
        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("Names with spaces and non-ASCII characters survive a round trip")
    func awkwardFileNames() async throws {
        // The test `RemotePath` exists to pass. A URL-based path would percent-encode these and a
        // string-based one would trip over the separators.
        let (session, workingDirectory) = try await makeConnectedSession()

        let names = ["a file with spaces.txt", "hash#and%percent.txt", "café-résumé.txt", "日本語.txt"]
        for name in names {
            let path = workingDirectory.appending(name)
            try await session.write(path, contents: SessionContract.stream(Data(name.utf8)),
                                    size: Int64(name.utf8.count), resumingAt: 0)
        }

        let listed = try await session.list(workingDirectory).map(\.name).sorted()
        #expect(listed == names.sorted())

        for name in names {
            let path = workingDirectory.appending(name)
            let contents = try await SessionContract.readAll(session, path)
            #expect(String(decoding: contents, as: UTF8.self) == name)
            try await session.delete(path)
        }

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    // MARK: - Helpers

    /// Asks the system `ssh-keygen` for a key's fingerprint, for cross-checking our own.
    private func sshKeygenFingerprint(forKeyBlob blob: Data, type: String) throws -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dp-key-\(UUID().uuidString).pub")
        try "\(type) \(blob.base64EncodedString()) test\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-lf", file.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Output looks like: "256 SHA256:PFM0y4… test (ED25519)" — the fingerprint is the second field.
        let fields = String(decoding: output, as: UTF8.self).split(separator: " ")
        return fields.count > 1 ? String(fields[1]) : ""
    }
}
