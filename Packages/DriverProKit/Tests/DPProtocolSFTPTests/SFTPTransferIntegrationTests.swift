//
//  SFTPTransferIntegrationTests.swift
//  DPProtocolSFTPTests
//

import DPCore
import DPCredentials
import DPDatabase
import DPTestSupport
import DPTransfer
import Foundation
import Testing
@testable import DPProtocolSFTP

/// The transfer engine driving real SFTP.
///
/// The queue is covered thoroughly against `MemorySession`; these tests check the parts a fake cannot —
/// real connection pooling, real chunking, and a tree that genuinely crosses the network.
@Suite(
    "SFTP transfers",
    .enabled(if: IntegrationConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct SFTPTransferIntegrationTests {

    private func makeHost() -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: IntegrationConfig.host ?? "localhost",
            port: IntegrationConfig.port,
            username: IntegrationConfig.user
        )
    }

    /// A pool that builds real SFTP sessions, each with a throwaway `known_hosts`.
    private func makePool(maxConnectionsPerHost: Int = 3) -> SessionPool {
        let knownHosts = KnownHostsStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "dp-known_hosts-\(UUID().uuidString)")
        )
        // The composition root in miniature: the only place that knows SFTP exists.
        let factory = ClosureSessionFactory([
            .sftp: { host in SFTPSession(host: host, knownHosts: knownHosts) },
        ])
        return SessionPool(
            factory: factory,
            delegate: ScriptedDelegate(
                credentials: .password(username: IntegrationConfig.user,
                                       password: IntegrationConfig.password)
            ),
            maxConnectionsPerHost: maxConnectionsPerHost
        )
    }

    private func makeLocalDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-sftp-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remoteWorkingDirectory() -> RemotePath {
        RemotePath(IntegrationConfig.basePath).appending("queue-\(UUID().uuidString.prefix(8))")
    }

    @Test("A local tree uploads and downloads again byte-for-byte")
    func treeRoundTrip() async throws {
        let pool = makePool()
        let queue = TransferQueue(pool: pool, maxConcurrentFiles: 3)
        let host = makeHost()
        let remoteRoot = remoteWorkingDirectory()

        // Build a tree worth walking: several levels, mixed sizes, an empty directory.
        let source = try makeLocalDirectory()
        let project = source.appending(path: "project")
        try FileManager.default.createDirectory(at: project.appending(path: "src/deep"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appending(path: "empty"),
                                                withIntermediateDirectories: true)

        let payloads: [String: Data] = [
            "README.md": Data("hello".utf8),
            "src/main.swift": Data(repeating: 0x41, count: 3000),
            "src/deep/blob.bin": Data((0..<200_000).map { UInt8($0 % 251) }),
        ]
        for (relative, data) in payloads {
            try data.write(to: project.appending(path: relative))
        }

        try await pool.withSession(for: host) { session in
            try await session.createDirectory(remoteRoot)
        }

        // Upload.
        let uploadEvents = await queue.run(Transfer(
            host: host,
            work: .upload(sources: [project], destination: remoteRoot)
        )).collect()
        let uploadReport = try #require(uploadEvents.report)
        #expect(uploadReport.transferred == payloads.count)
        #expect(uploadReport.isSuccess)

        // Download it back to a different place.
        let destination = try makeLocalDirectory()
        let downloadEvents = await queue.run(Transfer(
            host: host,
            work: .download(sources: [remoteRoot.appending("project")], destination: destination)
        )).collect()
        let downloadReport = try #require(downloadEvents.report)
        #expect(downloadReport.transferred == payloads.count)
        #expect(downloadReport.isSuccess)

        // Every byte survived both crossings.
        for (relative, expected) in payloads {
            let url = destination.appending(path: "project/\(relative)")
            #expect(try Data(contentsOf: url) == expected, "\(relative) differs after the round trip")
        }

        // An empty directory is part of the tree and must be recreated.
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "project/empty").path))

        try await pool.withSession(for: host) { session in
            try await session.deleteTree(remoteRoot)
        }
        await pool.disconnectAll()
    }

    @Test("The pool reuses connections rather than reconnecting per file")
    func poolReusesConnections() async throws {
        let pool = makePool(maxConnectionsPerHost: 2)
        let queue = TransferQueue(pool: pool, maxConcurrentFiles: 2)
        let host = makeHost()
        let remoteRoot = remoteWorkingDirectory()

        let source = try makeLocalDirectory()
        let folder = source.appending(path: "many")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<12 {
            try Data("file \(index)".utf8).write(to: folder.appending(path: "f\(index).txt"))
        }

        try await pool.withSession(for: host) { session in
            try await session.createDirectory(remoteRoot)
        }

        let events = await queue.run(Transfer(
            host: host,
            work: .upload(sources: [folder], destination: remoteRoot)
        )).collect()

        #expect(try #require(events.report).transferred == 12)
        // Twelve files, at most two connections. Without pooling this would be twelve SSH handshakes.
        #expect(await pool.connectionCount(for: host) <= 2)

        try await pool.withSession(for: host) { session in
            try await session.deleteTree(remoteRoot)
        }
        await pool.disconnectAll()
    }

    @Test("deleteTree removes a tree the server cannot delete in one call")
    func deleteTreeWalksDepthFirst() async throws {
        // SFTP has no recursiveDelete, so this exercises the capability-driven fallback against a real
        // server rather than against the fake that was written alongside it.
        let pool = makePool()
        let host = makeHost()
        let root = remoteWorkingDirectory()

        try await pool.withSession(for: host) { session in
            #expect(!session.capabilities.contains(.recursiveDelete))

            try await session.createDirectory(root)
            try await session.createDirectory(root.appending("a"))
            try await session.createDirectory(root.appending("a").appending("b"))
            try await session.write(root.appending("a").appending("b").appending("leaf.txt"),
                                    contents: SessionContract.stream(Data("leaf".utf8)),
                                    size: 4, resumingAt: 0)

            try await session.deleteTree(root)
            #expect(await !session.exists(root))
        }
        await pool.disconnectAll()
    }
}

/// Losing the app mid-transfer, and picking it up again.
///
/// The one thing neither a fake nor a unit test can prove: that a file interrupted part-way through a
/// real download finishes byte-for-byte when the transfer is restored and resumed. A quit is simulated
/// by cancelling the transfer and leaving the journal row behind, which is the state a dead process
/// leaves on disk.
@Suite(
    "SFTP transfers — interrupted and resumed",
    .enabled(if: IntegrationConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct SFTPResumeIntegrationTests {

    private func makeHost() -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: IntegrationConfig.host ?? "localhost",
            port: IntegrationConfig.port,
            username: IntegrationConfig.user
        )
    }

    private func makePool() -> SessionPool {
        let knownHosts = KnownHostsStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "dp-known_hosts-\(UUID().uuidString)")
        )
        return SessionPool(
            factory: ClosureSessionFactory([
                .sftp: { host in SFTPSession(host: host, knownHosts: knownHosts) },
            ]),
            delegate: ScriptedDelegate(
                credentials: .password(username: IntegrationConfig.user,
                                       password: IntegrationConfig.password)
            ),
            maxConnectionsPerHost: 2
        )
    }

    @Test("An interrupted download resumes to a byte-perfect file")
    func interruptedDownloadResumes() async throws {
        let database = try Database(.memory, migrations: SQLiteTransferJournal.migrations)
        let journal = SQLiteTransferJournal(database: database)
        let pool = makePool()
        let queue = TransferQueue(pool: pool, maxConcurrentFiles: 1, journal: journal)
        let host = makeHost()

        // Big enough that cancelling lands mid-file rather than between files.
        let payload = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 % 251) })
        let remoteRoot = RemotePath(IntegrationConfig.basePath)
            .appending("resume-\(UUID().uuidString.prefix(8))")
        let remoteFile = remoteRoot.appending("big.bin")

        let local = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        try await pool.withSession(for: host) { session in
            try await session.createDirectory(remoteRoot)
            try await session.write(remoteFile,
                                    contents: SessionContract.stream(payload, chunkSize: 64 * 1024),
                                    size: Int64(payload.count), resumingAt: 0)
        }

        let transfer = Transfer(
            host: host,
            work: .download(sources: [remoteFile], destination: local),
            overwritePolicy: .resume
        )

        // Start it, then pull the rug out part-way through.
        let stream = await queue.run(transfer, title: "big.bin")
        var seen: Int64 = 0
        for await event in stream {
            if case .progress(let bytes, _) = event, bytes > Int64(payload.count) / 3 {
                await queue.cancel(transfer.id)
                seen = bytes
                break
            }
        }
        #expect(seen > 0, "the transfer never got going, so nothing was interrupted")

        let partial = local.appending(path: "big.bin")
        let partialSize = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        #expect(partialSize > 0)
        #expect(partialSize < payload.count, "the file should be incomplete at this point")

        // A quit leaves the record behind; cancelling deliberately does not, so put it back.
        try await journal.record(transfer, title: "big.bin")

        let restored = try #require(try await journal.unfinished().first)
        #expect(restored.title == "big.bin")

        let finished = await queue.run(restored.transfer, title: restored.title).collect()
        let report = try #require(finished.report)
        #expect(report.isSuccess)

        let written = try Data(contentsOf: partial)
        #expect(written.count == payload.count, "resumed to the right length")
        #expect(written == payload, "and to the right bytes — no truncation, no doubled prefix")
        #expect(try await journal.unfinished().isEmpty, "finished means forgotten")

        try? FileManager.default.removeItem(at: local)
        try? await pool.withSession(for: host) { session in
            try await session.deleteTree(remoteRoot)
        }
    }
}
