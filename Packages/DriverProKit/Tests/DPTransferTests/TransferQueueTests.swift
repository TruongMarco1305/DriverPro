//
//  TransferQueueTests.swift
//  DPTransferTests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPTransfer

@Suite("TransferQueue — downloads")
struct DownloadTests {

    @Test("A single file arrives with its bytes intact")
    func downloadsOneFile() async throws {
        let session = try await TransferFixture.makeSession()
        let payload = TransferFixture.bytes(5000)
        await session.seed(file: RemotePath("/srv/report.bin"), contents: payload)

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))

        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/report.bin")], destination: local)
        )).collect()

        let report = try #require(events.report)
        #expect(report.transferred == 1)
        #expect(report.failed == 0)
        #expect(report.isSuccess)

        let written = try Data(contentsOf: local.appending(path: "report.bin"))
        #expect(written == payload)
    }

    @Test("A nested tree is reproduced locally, structure and contents")
    func downloadsRecursively() async throws {
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/data/top.txt"), contents: Data("top".utf8))
        await session.seed(file: RemotePath("/srv/data/nested/deep.txt"), contents: Data("deep".utf8))
        await session.seed(file: RemotePath("/srv/data/nested/deeper/leaf.bin"),
                           contents: TransferFixture.bytes(300))
        await session.seed(directory: RemotePath("/srv/data/empty"))

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))

        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/data")], destination: local)
        )).collect()

        let report = try #require(events.report)
        #expect(report.transferred == 3)
        #expect(report.isSuccess)

        let root = local.appending(path: "data")
        #expect(try String(contentsOf: root.appending(path: "top.txt"), encoding: .utf8) == "top")
        #expect(try String(contentsOf: root.appending(path: "nested/deep.txt"), encoding: .utf8) == "deep")
        #expect(try Data(contentsOf: root.appending(path: "nested/deeper/leaf.bin")).count == 300)

        // An empty directory still has to be created, or the local copy is not a copy.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "empty").path,
                                               isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("A missing file fails that item and leaves the rest alone")
    func failureIsIsolated() async throws {
        // Select fifty files, have one deleted on the server, and the other forty-nine must still
        // arrive. One bad source cannot be allowed to abandon the whole selection.
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/present.txt"), contents: Data("here".utf8))

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))

        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(
                sources: [RemotePath("/srv/present.txt"), RemotePath("/srv/absent.txt")],
                destination: local
            )
        )).collect()

        let report = try #require(events.report)
        #expect(report.transferred == 1)
        #expect(report.failed == 1)
        #expect(!report.isSuccess)

        // The file that exists is on disk.
        #expect(try String(contentsOf: local.appending(path: "present.txt"), encoding: .utf8) == "here")

        // The failure names the path the user actually asked for, not a placeholder.
        let failure = try #require(events.outcomes.first { outcome in
            if case .failed = outcome.1 { return true }
            return false
        })
        #expect(failure.0.remote == RemotePath("/srv/absent.txt"))
        #expect(failure.1 == .failed(.notFound(RemotePath("/srv/absent.txt"))))
    }

    @Test("Enumeration failures are reported per source, not as one lump")
    func everyBadSourceIsReported() async throws {
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/ok.txt"), contents: Data("ok".utf8))

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))

        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(
                sources: [
                    RemotePath("/srv/ok.txt"),
                    RemotePath("/srv/gone-a.txt"),
                    RemotePath("/srv/gone-b.txt")
                ],
                destination: local
            )
        )).collect()

        let report = try #require(events.report)
        #expect(report.transferred == 1)
        #expect(report.failed == 2, "each unreachable source deserves its own outcome")

        let failedPaths = events.outcomes
            .filter { if case .failed = $0.1 { true } else { false } }
            .map(\.0.remote)
        #expect(Set(failedPaths) == [RemotePath("/srv/gone-a.txt"), RemotePath("/srv/gone-b.txt")])
    }
}

@Suite("TransferQueue — uploads")
struct UploadTests {

    @Test("A single file arrives on the server")
    func uploadsOneFile() async throws {
        let session = try await TransferFixture.makeSession()
        let local = try TransferFixture.makeTemporaryDirectory()
        let payload = TransferFixture.bytes(4096)
        let file = local.appending(path: "upload.bin")
        try payload.write(to: file)

        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .upload(sources: [file], destination: RemotePath("/srv"))
        )).collect()

        #expect(try #require(events.report).transferred == 1)
        #expect(try await session.stat(RemotePath("/srv/upload.bin")).size == 4096)
    }

    @Test("A local tree is reproduced on the server")
    func uploadsRecursively() async throws {
        let session = try await TransferFixture.makeSession()
        let local = try TransferFixture.makeTemporaryDirectory()
        let root = local.appending(path: "project")
        try FileManager.default.createDirectory(at: root.appending(path: "src/deep"),
                                                withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: root.appending(path: "README.md"))
        try Data("code".utf8).write(to: root.appending(path: "src/main.swift"))
        try TransferFixture.bytes(200).write(to: root.appending(path: "src/deep/data.bin"))

        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .upload(sources: [root], destination: RemotePath("/srv"))
        )).collect()

        #expect(try #require(events.report).transferred == 3)
        #expect(try await session.stat(RemotePath("/srv/project/README.md")).size == 6)
        #expect(try await session.stat(RemotePath("/srv/project/src/main.swift")).size == 4)
        #expect(try await session.stat(RemotePath("/srv/project/src/deep/data.bin")).size == 200)
    }

    @Test("Symbolic links are not followed, so a cycle cannot hang the walk")
    func doesNotFollowSymlinks() async throws {
        let session = try await TransferFixture.makeSession()
        let local = try TransferFixture.makeTemporaryDirectory()
        let root = local.appending(path: "linked")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("real".utf8).write(to: root.appending(path: "file.txt"))

        // A link pointing at its own parent. Following it would recurse until the stack or disk gave out.
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "loop"), withDestinationURL: root)

        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .upload(sources: [root], destination: RemotePath("/srv"))
        )).collect()

        #expect(try #require(events.report).transferred == 1)
        #expect(await session.exists(RemotePath("/srv/linked/file.txt")))
    }
}

@Suite("TransferQueue — policies")
struct OverwritePolicyTests {

    /// Seeds a remote file and an existing local file of different contents.
    private func makeCollision() async throws -> (MemorySession, URL) {
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/file.txt"), contents: Data("remote".utf8))

        let local = try TransferFixture.makeTemporaryDirectory()
        try Data("local".utf8).write(to: local.appending(path: "file.txt"))
        return (session, local)
    }

    private func download(_ policy: OverwritePolicy, session: MemorySession, to local: URL) async -> [TransferEvent] {
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        return await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/file.txt")], destination: local),
            overwritePolicy: policy
        )).collect()
    }

    @Test("skip leaves the existing file untouched")
    func skipPreservesLocal() async throws {
        let (session, local) = try await makeCollision()
        let events = await download(.skip, session: session, to: local)

        #expect(try #require(events.report).skipped == 1)
        #expect(try String(contentsOf: local.appending(path: "file.txt"), encoding: .utf8) == "local")
    }

    @Test("overwrite replaces it")
    func overwriteReplacesLocal() async throws {
        let (session, local) = try await makeCollision()
        let events = await download(.overwrite, session: session, to: local)

        #expect(try #require(events.report).transferred == 1)
        #expect(try String(contentsOf: local.appending(path: "file.txt"), encoding: .utf8) == "remote")
    }

    @Test("rename writes alongside, Finder-style")
    func renameKeepsBoth() async throws {
        let (session, local) = try await makeCollision()
        let events = await download(.rename, session: session, to: local)

        #expect(try #require(events.report).transferred == 1)
        #expect(try String(contentsOf: local.appending(path: "file.txt"), encoding: .utf8) == "local")
        #expect(try String(contentsOf: local.appending(path: "file 2.txt"), encoding: .utf8) == "remote")
    }

    @Test("resume continues from the existing size")
    func resumeContinues() async throws {
        let session = try await TransferFixture.makeSession()
        let payload = TransferFixture.bytes(2000)
        await session.seed(file: RemotePath("/srv/partial.bin"), contents: payload)

        let local = try TransferFixture.makeTemporaryDirectory()
        let destination = local.appending(path: "partial.bin")
        // A half-finished download from a previous run.
        try payload.prefix(800).write(to: destination)

        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/partial.bin")], destination: local),
            overwritePolicy: .resume
        )).collect()

        let report = try #require(events.report)
        #expect(report.transferred == 1)
        // Only the remaining bytes crossed the wire.
        #expect(report.bytes == 1200)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("resume falls back to a full transfer when the backend cannot seek")
    func resumeWithoutCapability() async throws {
        let session = try await TransferFixture.makeSession(
            capabilities: SessionCapabilities.posixFileSystem.subtracting(.resumeDownload))
        let payload = TransferFixture.bytes(500)
        await session.seed(file: RemotePath("/srv/partial.bin"), contents: payload)

        let local = try TransferFixture.makeTemporaryDirectory()
        let destination = local.appending(path: "partial.bin")
        try payload.prefix(100).write(to: destination)

        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/partial.bin")], destination: local),
            overwritePolicy: .resume
        )).collect()

        // Appending to a server that cannot seek would corrupt the file, so the whole thing is refetched.
        #expect(try #require(events.report).transferred == 1)
        #expect(try Data(contentsOf: destination) == payload)
    }
}

@Suite("TransferQueue — events and cancellation")
struct TransferEventTests {

    @Test("Events arrive in order: planned first, exactly one finished last")
    func eventOrdering() async throws {
        let session = try await TransferFixture.makeSession()
        for index in 0..<5 {
            await session.seed(file: RemotePath("/srv/f\(index).bin"), contents: TransferFixture.bytes(100))
        }

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv")], destination: local)
        )).collect()

        guard case .planned = events.first else {
            Issue.record("the first event should be .planned, got \(String(describing: events.first))")
            return
        }
        guard case .finished = events.last else {
            Issue.record("the last event should be .finished")
            return
        }

        let finishedCount = events.filter { if case .finished = $0 { true } else { false } }.count
        #expect(finishedCount == 1, "a UI counting terminal events must see exactly one")
    }

    @Test("Progress only ever increases")
    func progressIsMonotonic() async throws {
        let session = try await TransferFixture.makeSession()
        for index in 0..<4 {
            await session.seed(file: RemotePath("/srv/f\(index).bin"), contents: TransferFixture.bytes(2000))
        }

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv")], destination: local)
        )).collect()

        let bytes = events.progressBytes
        #expect(!bytes.isEmpty)
        // A progress bar that jumps backwards looks broken even when the transfer is fine.
        #expect(bytes == bytes.sorted(), "cumulative progress went backwards")
        #expect(bytes.last == 8000)
    }

    @Test("Every planned file reports exactly one outcome")
    func oneOutcomePerItem() async throws {
        let session = try await TransferFixture.makeSession()
        for index in 0..<6 {
            await session.seed(file: RemotePath("/srv/f\(index).bin"), contents: TransferFixture.bytes(50))
        }

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session))
        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv")], destination: local)
        )).collect()

        let outcomes = events.outcomes
        #expect(outcomes.count == 6)
        #expect(Set(outcomes.map(\.0.remote)).count == 6, "an item reported twice")
    }

    @Test("planned comes first even when nothing could be planned")
    func plannedIsAlwaysFirst() async throws {
        // A UI sizes its progress bar from `.planned`. If the event is skipped on the failure path, it
        // breaks exactly when it most needs to show something.
        let pool = SessionPool(factory: FailingSessionFactory(), delegate: ScriptedDelegate())
        let queue = TransferQueue(pool: pool)

        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/x.txt")],
                            destination: try TransferFixture.makeTemporaryDirectory())
        )).collect()

        guard case .planned(let items, _) = events.first else {
            Issue.record("the first event should be .planned, got \(String(describing: events.first))")
            return
        }
        #expect(items == 0)

        let finishedCount = events.filter { if case .finished = $0 { true } else { false } }.count
        #expect(finishedCount == 1)
    }

    @Test("A transfer that cannot connect records why, without inventing item failures")
    func connectionFailureIsTransferLevel() async throws {
        let pool = SessionPool(factory: FailingSessionFactory(), delegate: ScriptedDelegate())
        let queue = TransferQueue(pool: pool)

        let events = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/a.txt"), RemotePath("/srv/b.txt")],
                            destination: try TransferFixture.makeTemporaryDirectory())
        )).collect()

        let report = try #require(events.report)
        #expect(report.failure == .unknownProtocol(.sftp))
        #expect(!report.isSuccess)
        // Two sources, but the connection never happened — so no per-item verdicts were invented.
        #expect(report.failed == 0)
        #expect(events.outcomes.isEmpty)
    }

    @Test("Cancelling stops the run and reports it")
    func cancellationStops() async throws {
        let session = try await TransferFixture.makeSession()
        for index in 0..<40 {
            await session.seed(file: RemotePath("/srv/f\(index).bin"), contents: TransferFixture.bytes(20_000))
        }

        let local = try TransferFixture.makeTemporaryDirectory()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session), maxConcurrentFiles: 2)
        let transfer = Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv")], destination: local)
        )

        let stream = await queue.run(transfer)

        var events: [TransferEvent] = []
        for await event in stream {
            events.append(event)
            // Cancel as soon as real work has started.
            if case .itemFinished = event, events.outcomes.count == 2 {
                await queue.cancel(transfer.id)
            }
        }

        let report = try #require(events.report)
        #expect(report.wasCancelled)
        #expect(report.transferred < 40, "cancellation should have stopped it early")
    }
}
