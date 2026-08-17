//
//  TransferListModelTests.swift
//  DPPresentationTests
//

import DPCore
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
        try await waitUntil { model.rows.first(where: { $0.id == id })?.isFinished == true }
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

    @Test("A run produces one row that ends finished")
    func producesOneFinishedRow() async throws {
        let model = try await makeModel()
        let id = UUID()
        let item = makeItem("a.txt")

        model.consume(stream([
            .planned(items: 1, bytes: 100),
            .itemStarted(item),
            .progress(bytes: 100, of: 100),
            .itemFinished(item, .transferred(bytes: 100)),
            .finished(TransferReport(transferred: 1, bytes: 100))
        ]), id: id, title: "a.txt", isDownload: true)

        try await waitForFinish(model, id: id)

        #expect(model.rows.count == 1)
        let row = try #require(model.rows.first)
        #expect(row.plannedItems == 1)
        #expect(row.transferredBytes == 100)
        #expect(row.fractionCompleted == 1)
        #expect(row.report?.isSuccess == true)
        #expect(row.currentItem == nil, "nothing is in flight once it has finished")
    }

    @Test("Progress never exceeds the total, and is nil when the total is unknown")
    func fractionIsSafe() async throws {
        let model = try await makeModel()
        let id = UUID()

        model.consume(stream([
            .planned(items: 1, bytes: nil),          // a server that reported no sizes
            .progress(bytes: 50, of: nil),
            .finished(TransferReport(transferred: 1, bytes: 50))
        ]), id: id, title: "unsized", isDownload: true)

        try await waitForFinish(model, id: id)
        let row = try #require(model.rows.first)
        // A bar with no total would be a guess; the UI shows an indeterminate one instead.
        #expect(row.fractionCompleted == nil)
        #expect(row.transferredBytes == 50)
    }

    @Test("The final byte count survives the throttle")
    func finalCountIsNotDropped() async throws {
        // Every progress event but the first would be throttled away here; the terminal event has to
        // carry the total through anyway.
        let model = try await makeModel()
        let id = UUID()

        var events: [TransferEvent] = [.planned(items: 1, bytes: 1000)]
        for byte in stride(from: 100, through: 1000, by: 100) {
            events.append(.progress(bytes: Int64(byte), of: 1000))
        }
        events.append(.finished(TransferReport(transferred: 1, bytes: 1000)))

        model.consume(stream(events), id: id, title: "big", isDownload: true)
        try await waitForFinish(model, id: id)

        #expect(model.rows.first?.transferredBytes == 1000)
        #expect(model.rows.first?.fractionCompleted == 1)
    }

    @Test("A failed run is still reported, not hidden")
    func failuresAreShown() async throws {
        let model = try await makeModel()
        let id = UUID()
        let item = makeItem("gone.txt")

        model.consume(stream([
            .planned(items: 1, bytes: nil),
            .itemFinished(item, .failed(.notFound(item.remote))),
            .finished(TransferReport(failed: 1))
        ]), id: id, title: "gone.txt", isDownload: true)

        try await waitForFinish(model, id: id)
        let row = try #require(model.rows.first)
        #expect(row.report?.failed == 1)
        #expect(row.report?.isSuccess == false)
    }

    @Test("Rows are newest first")
    func newestFirst() async throws {
        let model = try await makeModel()
        let first = UUID(), second = UUID()

        model.consume(stream([.finished(TransferReport())]), id: first, title: "first", isDownload: true)
        model.consume(stream([.finished(TransferReport())]), id: second, title: "second", isDownload: true)

        #expect(model.rows.map(\.title) == ["second", "first"])
    }

    @Test("Nothing running means no status bar")
    func summaryIsNilWhenIdle() async throws {
        let model = try await makeModel()
        #expect(model.activeSummary == nil)
    }

    @Test("A finished transfer stops appearing in the status bar")
    func summaryIgnoresFinished() async throws {
        let model = try await makeModel()
        let id = UUID()
        model.consume(stream([.finished(TransferReport(transferred: 1))]), id: id,
                      title: "done", isDownload: true)
        try await waitForFinish(model, id: id)

        #expect(model.activeSummary == nil, "the bar should disappear once nothing is running")
    }

    @Test("The status bar names the file in flight and its overall progress")
    func summaryReportsProgress() async throws {
        let model = try await makeModel()
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()
        model.consume(stream, id: UUID(), title: "batch", isDownload: true)

        continuation.yield(.planned(items: 1, bytes: 1000))
        continuation.yield(.itemStarted(makeItem("moving.txt")))
        continuation.yield(.progress(bytes: 250, of: 1000))
        try await waitUntil { model.rows.first?.transferredBytes == 250 }

        let summary = try #require(model.activeSummary)
        #expect(summary.title == "moving.txt", "the file, not the transfer, is what says where it is")
        #expect(summary.fraction == 0.25)
        #expect(summary.activeCount == 1)
        continuation.finish()
    }

    @Test("Several transfers aggregate, and an unknown total makes the bar indeterminate")
    func summaryAggregates() async throws {
        let model = try await makeModel()
        let (first, firstFeed) = AsyncStream<TransferEvent>.makeStream()
        let (second, secondFeed) = AsyncStream<TransferEvent>.makeStream()

        model.consume(first, id: UUID(), title: "one", isDownload: true)
        model.consume(second, id: UUID(), title: "two", isDownload: false)

        firstFeed.yield(.planned(items: 1, bytes: 100))
        firstFeed.yield(.progress(bytes: 50, of: 100))
        secondFeed.yield(.planned(items: 1, bytes: 100))
        try await waitUntil {
            model.rows.allSatisfy { $0.totalBytes == 100 } && model.rows.contains { $0.transferredBytes == 50 }
        }

        var summary = try #require(model.activeSummary)
        #expect(summary.activeCount == 2)
        #expect(summary.fraction == 0.25, "50 bytes of the 200 both transfers add up to")

        // A transfer whose total is unknown makes the aggregate meaningless — counting it as zero would
        // make the bar jump backwards the moment its size became known.
        let (third, thirdFeed) = AsyncStream<TransferEvent>.makeStream()
        model.consume(third, id: UUID(), title: "three", isDownload: true)
        thirdFeed.yield(.planned(items: 1, bytes: nil))
        try await waitUntil { model.rows.count == 3 && model.rows.allSatisfy { $0.plannedItems == 1 } }

        summary = try #require(model.activeSummary)
        #expect(summary.activeCount == 3)
        #expect(summary.fraction == nil)

        firstFeed.finish(); secondFeed.finish(); thirdFeed.finish()
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
