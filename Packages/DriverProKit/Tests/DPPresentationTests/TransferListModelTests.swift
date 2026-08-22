//
//  TransferListModelTests.swift
//  DPPresentationTests
//

import DPCore
import DPServices
import DPTransfer
import Foundation
import Testing
@testable import DPPresentation

@Suite("ProgressThrottle")
struct ProgressThrottleTests {

    private let start = Date(timeIntervalSince1970: 1_000)

    // `shouldEmit` is mutating, and `#expect` captures its expression in a closure where the value is
    // immutable — so each result is computed first and then asserted.

    @Test("The first update always goes through")
    func firstAlwaysEmits() {
        var throttle = ProgressThrottle(interval: 0.1)
        let first = throttle.shouldEmit(now: start)
        #expect(first)
    }

    @Test("Updates inside the interval are dropped")
    func dropsWithinInterval() {
        var throttle = ProgressThrottle(interval: 0.1)
        _ = throttle.shouldEmit(now: start)

        let tooSoon = throttle.shouldEmit(now: start.addingTimeInterval(0.01))
        let stillTooSoon = throttle.shouldEmit(now: start.addingTimeInterval(0.05))
        let farEnough = throttle.shouldEmit(now: start.addingTimeInterval(0.1))

        #expect(!tooSoon)
        #expect(!stillTooSoon)
        #expect(farEnough)
    }

    @Test("A burst of a thousand events produces a handful of updates")
    func coalescesABurst() {
        // The point of the throttle. A fast transfer emits thousands of events per second, and writing
        // observable state for each would rebuild the window far more than anyone can see.
        var throttle = ProgressThrottle(interval: 0.1)
        var emitted = 0

        for step in 0..<1000 where throttle.shouldEmit(now: start.addingTimeInterval(Double(step) * 0.001)) {
            emitted += 1
        }

        #expect(emitted <= 12, "1,000 events over one second should redraw about ten times, got \(emitted)")
        #expect(emitted >= 8)
    }

    @Test("A terminal update is never dropped")
    func terminalAlwaysEmits() {
        // Otherwise the final byte count could be swallowed and the bar would stop short of the end.
        var throttle = ProgressThrottle(interval: 10)
        _ = throttle.shouldEmit(now: start)

        let throttled = throttle.shouldEmit(now: start.addingTimeInterval(0.01))
        let terminal = throttle.shouldEmit(now: start.addingTimeInterval(0.02), isTerminal: true)

        #expect(!throttled)
        #expect(terminal)
    }
}

@Suite("TransferListModel")
@MainActor
struct TransferListModelTests {

    private static let host = RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22,
                                         username: "duck")

    private func makeModel() async throws -> TransferListModel {
        let (services, _) = try await ServicesFixture.makeServices(
            for: Self.host, prompt: SilentPrompt()
        )
        return TransferListModel(services: services)
    }

    private func makeItem(_ name: String, size: Int64 = 100) -> TransferItem {
        TransferItem(
            remote: RemotePath("/srv/\(name)"),
            local: URL(fileURLWithPath: "/tmp/\(name)"),
            isDirectory: false,
            size: size
        )
    }

    /// Feeds a fixed script of events and finishes.
    private func stream(_ events: [TransferEvent]) -> AsyncStream<TransferEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    /// Waits until the consuming task has drained the stream.
    private func waitForFinish(_ model: TransferListModel, id: UUID) async throws {
        try await waitUntil { model.report(of: id) != nil }
    }

    /// Waits for a condition, since events are applied by a background task rather than on return.
    ///
    /// Polls rather than sleeping a fixed time: the condition is what the test means, and a fixed sleep
    /// is either flaky or slow.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A file gets its own row, which ends done")
    func producesOneFinishedRow() async throws {
        let model = try await makeModel()
        let id = UUID()
        let item = makeItem("a.txt")

        model.consume(stream([
            .planned(items: 1, bytes: 100),
            .itemStarted(item),
            .itemProgress(item, bytes: 100),
            .itemFinished(item, .transferred(bytes: 100)),
            .finished(TransferReport(transferred: 1, bytes: 100)),
        ]), id: id, title: "a.txt", isDownload: true, connection: "Work")

        try await waitForFinish(model, id: id)

        #expect(model.rows.count == 1, "the placeholder is replaced by the file, not added to")
        let row = try #require(model.rows.first)
        #expect(row.title == "a.txt")
        #expect(row.connection == "Work", "a row says which connection it belongs to")
        #expect(row.transferredBytes == 100)
        #expect(row.fractionCompleted == 1)
        #expect(row.state == .done)
        #expect(model.report(of: id)?.isSuccess == true)
    }

    @Test("Every file in a transfer gets a row of its own")
    func oneRowPerFile() async throws {
        // The panel lists files, not jobs: a dragged folder of three shows three bars.
        let model = try await makeModel()
        let id = UUID()
        let items = ["a.txt", "b.txt", "c.txt"].map { makeItem($0, size: 100) }

        var events: [TransferEvent] = [.planned(items: 3, bytes: 300)]
        for item in items {
            events += [.itemStarted(item), .itemProgress(item, bytes: 100),
                       .itemFinished(item, .transferred(bytes: 100))]
        }
        events.append(.finished(TransferReport(transferred: 3, bytes: 300)))

        model.consume(stream(events), id: id, title: "3 items", isDownload: true)
        try await waitForFinish(model, id: id)

        #expect(model.rows.count == 3)
        #expect(Set(model.rows.map(\.title)) == ["a.txt", "b.txt", "c.txt"])
        #expect(model.rows.allSatisfy { $0.state == .done })
        #expect(model.rows.allSatisfy { $0.transferID == id }, "all belong to the one transfer")
    }

    @Test("Files moving at once each track their own bytes")
    func concurrentFilesTrackSeparately() async throws {
        // The reason `itemProgress` exists: a transfer-wide total cannot be attributed to one file
        // when four are in flight.
        let model = try await makeModel()
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()
        let first = makeItem("first.bin", size: 1_000)
        let second = makeItem("second.bin", size: 400)

        // No throttle: this test is about which bytes land on which row, not about how often rows are
        // written. Coalescing has its own tests with a clock they control — depending on it here made
        // this one fail whenever a parallel run delayed the consuming task past the interval.
        model.consume(stream, id: UUID(), title: "two", isDownload: true, throttleInterval: 0)
        continuation.yield(.itemStarted(first))
        continuation.yield(.itemStarted(second))
        continuation.yield(.itemProgress(first, bytes: 250))
        continuation.yield(.itemProgress(second, bytes: 400))
        try await waitUntil { model.rows.allSatisfy { $0.transferredBytes > 0 } }

        let firstRow = try #require(model.rows.first { $0.title == "first.bin" })
        let secondRow = try #require(model.rows.first { $0.title == "second.bin" })
        #expect(firstRow.fractionCompleted == 0.25)
        #expect(secondRow.fractionCompleted == 1.0)
        continuation.finish()
    }

    @Test("A file with no known size shows no fraction until it is done")
    func fractionIsSafe() async throws {
        let model = try await makeModel()
        let id = UUID()
        let item = TransferItem(remote: RemotePath("/srv/unsized"),
                                local: URL(fileURLWithPath: "/tmp/unsized"),
                                isDirectory: false, size: nil)

        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()
        model.consume(stream, id: id, title: "unsized", isDownload: true)
        continuation.yield(.itemStarted(item))
        continuation.yield(.itemProgress(item, bytes: 50))
        try await waitUntil { model.rows.first?.transferredBytes == 50 }

        // A bar with no total would be a guess; the UI shows an indeterminate one instead.
        #expect(model.rows.first?.fractionCompleted == nil)

        continuation.yield(.itemFinished(item, .transferred(bytes: 50)))
        continuation.yield(.finished(TransferReport(transferred: 1, bytes: 50)))
        continuation.finish()
        try await waitForFinish(model, id: id)

        #expect(model.rows.first?.fractionCompleted == 1, "done is done, size known or not")
    }

    @Test("The final byte count survives the throttle")
    func finalCountIsNotDropped() async throws {
        // Every progress event but the first would be throttled away here; the item's finish has to
        // carry the total through anyway.
        let model = try await makeModel()
        let id = UUID()
        let item = makeItem("big", size: 1_000)

        var events: [TransferEvent] = [.itemStarted(item)]
        for byte in stride(from: 100, through: 1000, by: 100) {
            events.append(.itemProgress(item, bytes: Int64(byte)))
        }
        events += [.itemFinished(item, .transferred(bytes: 1_000)),
                   .finished(TransferReport(transferred: 1, bytes: 1_000))]

        model.consume(stream(events), id: id, title: "big", isDownload: true)
        try await waitForFinish(model, id: id)

        #expect(model.rows.first?.transferredBytes == 1_000)
        #expect(model.rows.first?.fractionCompleted == 1)
    }

    @Test("A failed file says why, on its own row")
    func failuresAreShown() async throws {
        let model = try await makeModel()
        let id = UUID()
        let item = makeItem("gone.txt")

        model.consume(stream([
            .itemStarted(item),
            .itemFinished(item, .failed(.notFound(item.remote))),
            .finished(TransferReport(failed: 1)),
        ]), id: id, title: "gone.txt", isDownload: true)

        try await waitForFinish(model, id: id)
        let row = try #require(model.rows.first)
        guard case .failed(let message) = row.state else {
            Issue.record("expected a failure state, got \(row.state)")
            return
        }
        #expect(!message.isEmpty, "a failed row has to say something")
        #expect(model.report(of: id)?.isSuccess == false)
    }

    @Test("A transfer that never starts a file still shows, carrying the failure")
    func wholeTransferFailureIsVisible() async throws {
        // A refused connection produces no items at all. Without the placeholder the panel would be
        // empty and the user would think nothing happened.
        let model = try await makeModel()
        let id = UUID()

        model.consume(stream([
            .planned(items: 0, bytes: 0),
            .finished(TransferReport(failure: .unreachable(host: "example.com", reason: "refused"))),
        ]), id: id, title: "batch", isDownload: true)
        try await waitForFinish(model, id: id)

        let row = try #require(model.rows.first)
        #expect(row.title == "batch")
        if case .failed = row.state {} else {
            Issue.record("expected the placeholder to carry the failure, got \(row.state)")
        }
    }

    @Test("Rows are newest first")
    func newestFirst() async throws {
        let model = try await makeModel()
        let first = UUID(), second = UUID()

        model.consume(stream([.finished(TransferReport())]), id: first, title: "first", isDownload: true)
        model.consume(stream([.finished(TransferReport())]), id: second, title: "second", isDownload: true)

        #expect(model.rows.map(\.title) == ["second", "first"])
    }

    @Test("Nothing running means nothing on the badge")
    func summaryIsEmptyWhenIdle() async throws {
        let model = try await makeModel()
        #expect(model.activeCount == 0)
        #expect(model.interruptedCount == 0)
        #expect(model.overallFraction == nil)
        #expect(!model.hasActiveTransfers)
    }

    @Test("A finished transfer stops counting towards the badge")
    func summaryIgnoresFinished() async throws {
        let model = try await makeModel()
        let id = UUID()
        model.consume(stream([.finished(TransferReport(transferred: 1))]), id: id,
                      title: "done", isDownload: true)
        try await waitForFinish(model, id: id)

        #expect(model.activeCount == 0)
        #expect(!model.hasActiveTransfers)
    }

    @Test("Progress across everything moving is one fraction")
    func summaryAggregates() async throws {
        let model = try await makeModel()
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()
        let first = makeItem("first.bin", size: 100)
        let second = makeItem("second.bin", size: 100)

        model.consume(stream, id: UUID(), title: "two", isDownload: true)
        continuation.yield(.itemStarted(first))
        continuation.yield(.itemStarted(second))
        continuation.yield(.itemProgress(first, bytes: 50))
        try await waitUntil { model.rows.contains { $0.transferredBytes == 50 } }

        #expect(model.activeCount == 2)
        #expect(model.overallFraction == 0.25, "50 bytes of the 200 both files add up to")

        // A file whose size is unknown makes the aggregate meaningless — counting it as zero would
        // make the bar jump backwards the moment its size became known.
        let unsized = TransferItem(remote: RemotePath("/srv/third"),
                                   local: URL(fileURLWithPath: "/tmp/third"),
                                   isDirectory: false, size: nil)
        continuation.yield(.itemStarted(unsized))
        try await waitUntil { model.activeCount == 3 }
        #expect(model.overallFraction == nil)

        continuation.finish()
    }

    // MARK: - Restoring

    /// A model, plus the journal behind it, so a quit can be simulated by writing to the journal
    /// directly rather than by killing a process.
    private func makeModelWithJournal() async throws -> (TransferListModel, DriverProServices) {
        let (services, _) = try await ServicesFixture.makeServices(
            for: Self.host, prompt: SilentPrompt()
        )
        return (TransferListModel(services: services), services)
    }

    private func makeTransfer() -> Transfer {
        Transfer(host: Self.host,
                 work: .download(sources: [RemotePath("/srv/a.txt")],
                                 destination: URL(fileURLWithPath: "/tmp")),
                 overwritePolicy: .resume)
    }

    @Test("An interrupted transfer comes back as a row, and nothing reconnects")
    func restoresInterrupted() async throws {
        let (model, services) = try await makeModelWithJournal()
        let transfer = makeTransfer()
        try await services.journal.record(transfer, title: "a.txt")
        try await services.journal.updateCounters(
            for: transfer.id, report: TransferReport(transferred: 2, bytes: 1_024))

        await model.restore()

        let row = try #require(model.rows.first)
        #expect(row.transferID == transfer.id)
        #expect(row.title == "a.txt")
        #expect(row.isInterrupted)
        #expect(!row.isFinished)
        #expect(row.transferredBytes == 1_024, "how far it got, so the row is not blank")
        #expect(!model.hasActiveTransfers, "waiting is not running")
    }

    @Test("Restoring twice does not duplicate a row")
    func restoreIsIdempotent() async throws {
        // The journal also holds transfers that are running right now, so a second call must not add
        // a second row for them.
        let (model, services) = try await makeModelWithJournal()
        try await services.journal.record(makeTransfer(), title: "a.txt")

        await model.restore()
        await model.restore()

        #expect(model.rows.count == 1)
    }

    @Test("An interrupted transfer counts as waiting, not as moving bytes")
    func summaryDistinguishesInterrupted() async throws {
        let (model, services) = try await makeModelWithJournal()
        try await services.journal.record(makeTransfer(), title: "a.txt")
        await model.restore()

        #expect(model.activeCount == 0)
        #expect(model.interruptedCount == 1)
        #expect(model.overallFraction == nil, "a bar would claim movement that is not happening")
        #expect(model.rows.first?.title == "a.txt")
    }

    @Test("Resuming runs it again and the row stops being interrupted")
    func resumingRunsIt() async throws {
        let (model, services) = try await makeModelWithJournal()
        let transfer = makeTransfer()
        try await services.journal.record(transfer, title: "a.txt")
        await model.restore()

        await model.resume(transfer.id)
        try await waitForFinish(model, id: transfer.id)

        let row = try #require(model.rows.first { $0.transferID == transfer.id })
        #expect(!row.isInterrupted)
        #expect(row.isFinished, "it ran, whatever the outcome — the file is not on this fake server")
        #expect(try await services.journal.unfinished().isEmpty, "and it is no longer pending")
    }

    @Test("Dismissing an interrupted transfer stops it coming back")
    func dismissingForgetsIt() async throws {
        let (model, services) = try await makeModelWithJournal()
        let transfer = makeTransfer()
        try await services.journal.record(transfer, title: "a.txt")
        await model.restore()

        await model.dismiss(transfer.id)

        #expect(model.rows.isEmpty)
        #expect(try await services.journal.unfinished().isEmpty)

        await model.restore()
        #expect(model.rows.isEmpty, "dismissed means dismissed, across launches")
    }

    @Test("Resume All starts every waiting transfer")
    func resumeAll() async throws {
        let (model, services) = try await makeModelWithJournal()
        let first = makeTransfer(), second = makeTransfer()
        try await services.journal.record(first, title: "one")
        try await services.journal.record(second, title: "two")
        await model.restore()

        await model.resumeAll()
        try await waitForFinish(model, id: first.id)
        try await waitForFinish(model, id: second.id)

        #expect(!model.rows.contains { $0.isInterrupted })
    }

    @Test("Dismissing removes the row and cancels its consuming task")
    func dismissCancelsTheTask() async throws {
        // A row can be dismissed while its stream is still producing. A task left running would go on
        // writing to a row nobody can see.
        let model = try await makeModel()
        let id = UUID()

        // A stream that never finishes on its own.
        let (endless, _) = AsyncStream<TransferEvent>.makeStream()
        model.consume(endless, id: id, title: "endless", isDownload: true)

        #expect(model.rows.count == 1)
        #expect(model.activeTaskCount == 1)

        await model.dismiss(id)

        #expect(model.rows.isEmpty)
        #expect(model.activeTaskCount == 0, "the consuming task should have been cancelled")
    }

    @Test("Clearing finished rows leaves running ones alone")
    func clearFinishedKeepsActive() async throws {
        let model = try await makeModel()
        let done = UUID(), running = UUID()

        model.consume(stream([.finished(TransferReport(transferred: 1))]), id: done,
                      title: "done", isDownload: true)
        try await waitForFinish(model, id: done)

        let (endless, _) = AsyncStream<TransferEvent>.makeStream()
        model.consume(endless, id: running, title: "running", isDownload: false)

        #expect(model.hasActiveTransfers)
        model.clearFinished()

        #expect(model.rows.map(\.title) == ["running"])
        #expect(model.hasActiveTransfers)
    }
}
