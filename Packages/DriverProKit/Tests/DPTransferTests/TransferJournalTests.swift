//
//  TransferJournalTests.swift
//  DPTransferTests
//

import DPCore
import DPDatabase
import Foundation
import Testing
@testable import DPTransfer

@Suite("Transfer coding")
struct TransferCodingTests {

    private let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 2222,
                                  username: "duck", nickname: "Work")

    private func roundTrip(_ transfer: Transfer) throws -> Transfer {
        try JSONDecoder().decode(Transfer.self, from: JSONEncoder().encode(transfer))
    }

    @Test("A download survives JSON with its paths and destination")
    func downloadRoundTrips() throws {
        let transfer = Transfer(
            host: host,
            work: .download(sources: [RemotePath("/srv/a.txt"), RemotePath("/srv/deep/dir")],
                            destination: URL(fileURLWithPath: "/tmp/out")),
            overwritePolicy: .resume
        )
        let decoded = try roundTrip(transfer)

        #expect(decoded.id == transfer.id)
        #expect(decoded.host == host)
        #expect(decoded.overwritePolicy == .resume)
        #expect(decoded.isDownload)

        guard case .download(let sources, let destination) = decoded.work else {
            Issue.record("direction was not preserved")
            return
        }
        #expect(sources.map(\.pathString) == ["/srv/a.txt", "/srv/deep/dir"])
        #expect(destination.path == "/tmp/out")
    }

    @Test("An upload survives JSON, and stays an upload")
    func uploadRoundTrips() throws {
        // The direction is an enum precisely so it cannot be lost or contradicted; that has to hold
        // through storage too, or a restored transfer could send a file it was meant to fetch.
        let transfer = Transfer(
            host: host,
            work: .upload(sources: [URL(fileURLWithPath: "/tmp/a.txt")],
                          destination: RemotePath("/srv/in")),
            overwritePolicy: .skip
        )
        let decoded = try roundTrip(transfer)

        #expect(!decoded.isDownload)
        #expect(decoded.overwritePolicy == .skip)

        guard case .upload(let sources, let destination) = decoded.work else {
            Issue.record("an upload decoded as something else")
            return
        }
        #expect(sources.map(\.path) == ["/tmp/a.txt"])
        #expect(destination == RemotePath("/srv/in"))
    }
}

@Suite("SQLiteTransferJournal")
struct TransferJournalTests {

    private let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                                  username: "duck")

    private func makeJournal() throws -> (SQLiteTransferJournal, Database) {
        let database = try Database(.memory, migrations: SQLiteTransferJournal.migrations)
        return (SQLiteTransferJournal(database: database), database)
    }

    private func makeTransfer() -> Transfer {
        Transfer(host: host,
                 work: .download(sources: [RemotePath("/srv/a.txt")],
                                 destination: URL(fileURLWithPath: "/tmp")),
                 overwritePolicy: .resume)
    }

    @Test("A recorded transfer comes back")
    func recordsAndReads() async throws {
        let (journal, _) = try makeJournal()
        let transfer = makeTransfer()
        try await journal.record(transfer, title: "a.txt")

        let unfinished = try await journal.unfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.id == transfer.id)
        #expect(unfinished.first?.title == "a.txt")
        #expect(unfinished.first?.transfer.host == host)
    }

    @Test("Forgetting removes it, and forgetting twice is not an error")
    func forgetting() async throws {
        let (journal, _) = try makeJournal()
        let transfer = makeTransfer()
        try await journal.record(transfer, title: "a.txt")

        try await journal.forget(transfer.id)
        #expect(try await journal.unfinished().isEmpty)

        try await journal.forget(transfer.id)
        try await journal.forget(UUID())
    }

    @Test("Recording the same transfer again updates it rather than duplicating it")
    func recordingIsIdempotent() async throws {
        // Resuming re-runs the transfer under the id it already had; two rows would restore it twice.
        let (journal, _) = try makeJournal()
        let transfer = makeTransfer()

        try await journal.record(transfer, title: "first")
        try await journal.record(transfer, title: "second")

        let unfinished = try await journal.unfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.title == "second")
    }

    @Test("Counters are kept, so a restored row can say how far it got")
    func countersUpdate() async throws {
        let (journal, _) = try makeJournal()
        let transfer = makeTransfer()
        try await journal.record(transfer, title: "a.txt")

        try await journal.updateCounters(
            for: transfer.id,
            report: TransferReport(transferred: 3, skipped: 1, failed: 2, bytes: 4_096)
        )

        let report = try #require(try await journal.unfinished().first?.report)
        #expect(report.transferred == 3)
        #expect(report.skipped == 1)
        #expect(report.failed == 2)
        #expect(report.bytes == 4_096)
    }

    @Test("Updating an unknown transfer is ignored, not an error")
    func updatingUnknownIsFine() async throws {
        let (journal, _) = try makeJournal()
        try await journal.updateCounters(for: UUID(), report: TransferReport(transferred: 1))
        #expect(try await journal.unfinished().isEmpty)
    }

    @Test("A row that will not decode is skipped, not fatal")
    func corruptRowIsSkipped() async throws {
        // A transfer written by an older build must not make the rest unrestorable.
        let (journal, database) = try makeJournal()
        try await journal.record(makeTransfer(), title: "good")

        let now = Date()
        try await database.execute(
            """
            INSERT INTO transfer (id, host_id, title, payload, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [SQLValue(UUID()), SQLValue(UUID()), SQLValue("broken"), SQLValue("{not json"),
             SQLValue(now), SQLValue(now)]
        )

        let unfinished = try await journal.unfinished()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.title == "good")
    }

    @Test("Restored transfers come back oldest first")
    func orderedOldestFirst() async throws {
        // The order they were queued in is the order to offer them in.
        let (journal, _) = try makeJournal()
        try await journal.record(makeTransfer(), title: "first")
        try await Task.sleep(for: .milliseconds(10))
        try await journal.record(makeTransfer(), title: "second")

        #expect(try await journal.unfinished().map(\.title) == ["first", "second"])
    }
}

@Suite("TransferQueue — journalling")
struct QueueJournallingTests {

    /// Records every call, so the *order* of record-then-forget can be asserted.
    private actor RecordingJournal: TransferJournal {
        enum Call: Equatable { case record(UUID), counters(UUID), forget(UUID) }

        private(set) var calls: [Call] = []
        private(set) var live: Set<UUID> = []

        func record(_ transfer: Transfer, title: String) async throws {
            calls.append(.record(transfer.id))
            live.insert(transfer.id)
        }

        func updateCounters(for id: UUID, report: TransferReport) async throws {
            calls.append(.counters(id))
        }

        func forget(_ id: UUID) async throws {
            calls.append(.forget(id))
            live.remove(id)
        }

        func unfinished() async throws -> [StoredTransfer] { [] }
    }

    @Test("A completed transfer leaves nothing behind")
    func completedIsForgotten() async throws {
        // The rule: a record exists if and only if the transfer is unfinished.
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/a.bin"), contents: TransferFixture.bytes(500))

        let journal = RecordingJournal()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session), journal: journal)
        let transfer = Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/a.bin")],
                            destination: try TransferFixture.makeTemporaryDirectory())
        )

        _ = await queue.run(transfer, title: "a.bin").collect()

        #expect(await journal.live.isEmpty)
        let calls = await journal.calls
        #expect(calls.first == .record(transfer.id), "recorded before any work starts")
        #expect(calls.last == .forget(transfer.id), "and forgotten once it ends")
    }

    @Test("A transfer that failed outright is forgotten too, not left to be restored forever")
    func failedIsForgotten() async throws {
        let journal = RecordingJournal()
        let queue = TransferQueue(pool: TransferFixture.makeFailingPool(), journal: journal)
        let transfer = Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/a.bin")],
                            destination: try TransferFixture.makeTemporaryDirectory())
        )

        let events = await queue.run(transfer, title: "a.bin").collect()

        #expect(events.report?.failure != nil)
        #expect(await journal.live.isEmpty, "a transfer that cannot start is finished, not pending")
    }

    @Test("Counters are written per finished file, not per chunk")
    func countersPerFile() async throws {
        // A write every few kilobytes would cost more than the transfer itself.
        let session = try await TransferFixture.makeSession()
        for index in 0..<3 {
            await session.seed(file: RemotePath("/srv/many/\(index).bin"),
                               contents: TransferFixture.bytes(40_000))
        }

        let journal = RecordingJournal()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session), journal: journal)

        _ = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/many")],
                            destination: try TransferFixture.makeTemporaryDirectory())
        ), title: "many").collect()

        let updates = await journal.calls.filter { if case .counters = $0 { return true } else { return false } }
        #expect(updates.count == 3, "one per file, whatever the file's size")
    }

    @Test("An unjournalled run is never recorded, so a quit during one restores nothing")
    func unjournalledIsNeverRecorded() async throws {
        // A Quick Look copy lands in a temp folder that quit deletes. Recording it would mean the next
        // launch offering to resume a download into a folder that no longer exists.
        //
        // `completedIsForgotten` above is what pins the opposite default: without the flag, a run is
        // recorded before any work starts.
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/a.bin"), contents: TransferFixture.bytes(500))

        let journal = RecordingJournal()
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session), journal: journal)
        let destination = try TransferFixture.makeTemporaryDirectory()
        let transfer = Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/a.bin")], destination: destination)
        )

        let events = await queue.run(transfer, title: "a.bin", journalled: false).collect()

        // Asserted first: a run that failed early would leave the journal empty too, and prove nothing.
        #expect(events.report?.isSuccess == true)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "a.bin").path))

        #expect(await journal.live.isEmpty)
        let records = await journal.calls.filter { $0 == .record(transfer.id) }
        #expect(records.isEmpty, "never written, rather than written and then cleaned up")
    }

    @Test("A journalled run against the real store leaves the table empty")
    func endToEndThroughSQLite() async throws {
        let session = try await TransferFixture.makeSession()
        await session.seed(file: RemotePath("/srv/a.bin"), contents: TransferFixture.bytes(200))

        let database = try Database(.memory, migrations: SQLiteTransferJournal.migrations)
        let journal = SQLiteTransferJournal(database: database)
        let queue = TransferQueue(pool: TransferFixture.makePool(session: session), journal: journal)

        _ = await queue.run(Transfer(
            host: TransferFixture.host,
            work: .download(sources: [RemotePath("/srv/a.bin")],
                            destination: try TransferFixture.makeTemporaryDirectory())
        ), title: "a.bin").collect()

        #expect(try await journal.unfinished().isEmpty)
    }
}
