//
//  TransferListModel.swift
//  DPPresentation
//

import DPCore
import DPServices
import DPTransfer
import Foundation
import Observation

/// Decides how often progress is worth redrawing.
///
/// A transfer emits an event per chunk — thousands per second on a fast link. Writing observable state
/// that often would rebuild the window far more than a person can see, so updates are limited to a
/// sensible cadence. Terminal events always pass, or the last one could be dropped and the bar would
/// stop short of the end.
///
/// Kept as a plain value with the clock passed in, so its behaviour is testable without waiting.
struct ProgressThrottle {

    /// Shortest gap between updates.
    let interval: TimeInterval
    private var lastEmitted: Date?

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    /// Whether an update should be written now.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - isTerminal: Whether this is the final update for an item or a transfer.
    /// - Returns: `true` when the update should be applied.
    mutating func shouldEmit(now: Date, isTerminal: Bool = false) -> Bool {
        if isTerminal {
            lastEmitted = now
            return true
        }
        guard let lastEmitted else {
            self.lastEmitted = now
            return true
        }
        guard now.timeIntervalSince(lastEmitted) >= interval else { return false }
        self.lastEmitted = now
        return true
    }
}

/// What the transfers panel shows: one row per file.
///
/// A transfer may move hundreds of files, and the panel lists them individually — which is only
/// possible because the queue reports `itemProgress` per file as well as a total for the whole job.
/// Transfer-level actions (cancel, resume, dismiss) still work on the whole thing.
@MainActor
@Observable
public final class TransferListModel {

    /// One line in the panel: a file being moved, or a transfer that has no file in flight yet.
    public struct Row: Identifiable, Sendable {

        /// Where a row has got to.
        public enum State: Hashable, Sendable {
            /// Queued, nothing moving yet.
            case waiting
            /// Bytes are moving.
            case moving
            /// Arrived.
            case done
            /// Left alone because of the overwrite policy.
            case skipped
            /// Did not arrive, with something to show the user.
            case failed(String)
            /// Stopped by the user.
            case cancelled
            /// Left unfinished by a quit, waiting to be resumed.
            case interrupted
        }

        /// Identity: unique per file within a transfer.
        public let id: String
        /// The transfer this belongs to — what Cancel and Resume act on.
        public let transferID: UUID
        /// The file's name, or the transfer's title before a file has started.
        public let title: String
        /// Which connection it is going to or from.
        public let connection: String
        /// Whether it is coming down or going up.
        public let isDownload: Bool

        /// Size in bytes, when the server reported one.
        public var totalBytes: Int64?
        /// Bytes moved so far.
        public var transferredBytes: Int64 = 0
        /// Where this row has got to.
        public var state: State = .waiting

        /// How far along, or `nil` when the total is unknown and a bar would be a guess.
        public var fractionCompleted: Double? {
            if case .done = state { return 1 }
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }

        /// Whether this row has stopped changing.
        public var isFinished: Bool {
            switch state {
            case .waiting, .moving, .interrupted: false
            case .done, .skipped, .failed, .cancelled: true
            }
        }

        /// Whether a quit left this one waiting to be resumed.
        public var isInterrupted: Bool { state == .interrupted }
    }

    /// What a running transfer needs, beyond its rows.
    private struct Context {
        let title: String
        let connection: String
        let isDownload: Bool
        /// `true` once a file has started, so the placeholder row can go.
        var hasFileRows = false
    }

    private let services: DriverProServices
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var contexts: [UUID: Context] = [:]

    /// Transfers restored from the journal, held until the user resumes or dismisses them.
    private var interrupted: [UUID: StoredTransfer] = [:]

    /// Reports of transfers that have ended, for callers waiting on one.
    private var reports: [UUID: TransferReport] = [:]

    /// Rows, most recent activity first.
    public private(set) var rows: [Row] = []

    /// Creates a list over an assembled engine.
    /// - Parameter services: The wired engine.
    public init(services: DriverProServices) {
        self.services = services
    }

    // MARK: - Summaries

    /// Whether anything is still running.
    public var hasActiveTransfers: Bool {
        rows.contains { !$0.isFinished && !$0.isInterrupted }
    }

    /// How many rows are moving or queued — the number on the toolbar badge.
    public var activeCount: Int {
        rows.count { !$0.isFinished && !$0.isInterrupted }
    }

    /// How many are waiting to be resumed after a quit.
    public var interruptedCount: Int {
        rows.count(where: \.isInterrupted)
    }

    /// Progress across everything still moving, or `nil` when any of it has no known total.
    ///
    /// Mixing a known total with an unknown one would produce a bar that jumps when the unknown one
    /// finishes, so one missing size makes the whole thing indeterminate.
    public var overallFraction: Double? {
        let active = rows.filter { !$0.isFinished && !$0.isInterrupted }
        guard !active.isEmpty, !active.contains(where: { $0.totalBytes == nil }) else { return nil }

        let total = active.compactMap(\.totalBytes).reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, Double(active.map(\.transferredBytes).reduce(0, +)) / Double(total))
    }

    /// The report of a transfer that has ended, or `nil` while it is still running.
    /// - Parameter id: Which transfer.
    public func report(of id: UUID) -> TransferReport? { reports[id] }

    // MARK: - Restoring

    /// Reloads transfers the journal says never finished, as rows waiting to be resumed.
    ///
    /// Nothing reconnects: an interrupted transfer sits until the user asks for it, so launching the app
    /// never starts network activity or a password prompt on its own.
    ///
    /// Safe to call more than once — a transfer already on screen, including one running right now, is
    /// not added a second time.
    public func restore() async {
        guard let stored = try? await services.journal.unfinished() else { return }
        let known = Set(rows.map(\.transferID))

        for item in stored where !known.contains(item.id) {
            interrupted[item.id] = item
            contexts[item.id] = Context(title: item.title,
                                        connection: item.transfer.host.displayName,
                                        isDownload: item.transfer.isDownload)

            var row = makeRow(for: item.id, title: item.title)
            row.state = .interrupted
            row.transferredBytes = item.report.bytes
            rows.insert(row, at: 0)
        }
    }

    /// Runs an interrupted transfer again.
    ///
    /// Not a rewind: the queue re-enumerates the sources and the transfer's ``OverwritePolicy`` decides
    /// each file, so `.resume` continues a partial one and a file already complete costs nothing. See
    /// `docs/decisions/010-queue-persistence.md`.
    ///
    /// - Parameter id: Which transfer.
    public func resume(_ id: UUID) async {
        guard let stored = interrupted.removeValue(forKey: id) else { return }
        rows.removeAll { $0.transferID == id }

        let stream = await services.queue.run(stored.transfer, title: stored.title)
        consume(stream, id: id, title: stored.title, isDownload: stored.transfer.isDownload,
                connection: stored.transfer.host.displayName)
    }

    /// Runs every interrupted transfer again.
    public func resumeAll() async {
        for id in interrupted.keys { await resume(id) }
    }

    // MARK: - Running

    /// Starts a transfer and adds a row for it.
    ///
    /// - Parameters:
    ///   - transfer: What to move.
    ///   - title: What to call it in the list.
    public func start(_ transfer: Transfer, title: String) async {
        // The title goes to the queue as well as the row: the journal stores it, so a transfer restored
        // after a quit is still called what the user saw it called.
        let stream = await services.queue.run(transfer, title: title)
        consume(stream, id: transfer.id, title: title, isDownload: transfer.isDownload,
                connection: transfer.host.displayName)
    }

    /// Consumes an event stream into rows.
    ///
    /// Separated from ``start(_:title:)`` so tests can feed a stream directly rather than standing up a
    /// queue and a server.
    /// - Parameter throttleInterval: How long between progress writes. Tests that are about *what* is
    ///   tracked rather than *how often* pass zero, so every event is written and nothing depends on a
    ///   wall clock. `ProgressThrottleTests` covers the coalescing itself, with a clock it controls.
    func consume(
        _ stream: AsyncStream<TransferEvent>,
        id: UUID,
        title: String,
        isDownload: Bool,
        connection: String = "",
        throttleInterval: TimeInterval = 0.1
    ) {
        contexts[id] = Context(title: title, connection: connection, isDownload: isDownload)
        reports[id] = nil
        rows.insert(makeRow(for: id, title: title), at: 0)

        tasks[id] = Task { [weak self] in
            var throttle = ProgressThrottle(interval: throttleInterval)
            var pending: [RemotePath: Int64] = [:]

            for await event in stream {
                guard let self else { return }

                switch event {
                case .planned, .progress:
                    // Both are transfer-wide; per-file rows carry their own totals and counts.
                    break

                case .itemStarted(let item):
                    began(item, in: id)

                case .itemProgress(let item, let bytes):
                    // Coalesced: every count is remembered, but written only when it is worth
                    // redrawing. Files move concurrently, so several may be pending at once.
                    pending[item.remote] = bytes
                    if throttle.shouldEmit(now: Date()) {
                        flush(&pending, in: id)
                    }

                case .itemFinished(let item, let outcome):
                    flush(&pending, in: id)
                    finished(item, outcome, in: id)

                case .finished(let report):
                    flush(&pending, in: id)
                    ended(id, report: report)
                }
            }
            await self?.forget(id)
        }
    }

    // MARK: - Acting on a transfer

    /// Stops a running transfer. Its rows stay, showing what they managed.
    /// - Parameter id: Which transfer.
    public func cancel(_ id: UUID) async {
        await services.queue.cancel(id)
    }

    /// Cancels a transfer and removes every row belonging to it.
    ///
    /// The consuming task is cancelled too — rows can be dismissed while the stream is still producing,
    /// and a task left running would go on writing to rows nobody can see.
    ///
    /// - Parameter id: Which transfer.
    public func dismiss(_ id: UUID) async {
        await services.queue.cancel(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        contexts[id] = nil
        rows.removeAll { $0.transferID == id }

        // Forgotten in the journal too, or an interrupted transfer the user dismissed would come back
        // at the next launch.
        interrupted[id] = nil
        try? await services.journal.forget(id)
    }

    /// What the × on a row does.
    ///
    /// A finished row is just removed. A row still moving means the whole transfer has to stop, since a
    /// single file cannot be pulled out of one — so this dismisses the transfer, rows and all.
    ///
    /// - Parameter rowID: Which row.
    public func dismissRow(_ rowID: String) async {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }

        if row.isFinished {
            rows.removeAll { $0.id == rowID }
            // Once nothing of a transfer is left on screen, its context is dead weight.
            if !rows.contains(where: { $0.transferID == row.transferID }) {
                contexts[row.transferID] = nil
            }
        } else {
            await dismiss(row.transferID)
        }
    }

    /// Removes every finished row.
    public func clearFinished() {
        rows.removeAll(where: \.isFinished)
        for (id, _) in contexts where !rows.contains(where: { $0.transferID == id }) {
            tasks[id]?.cancel()
            tasks[id] = nil
            contexts[id] = nil
        }
    }

    /// How many consuming tasks are alive. For tests.
    var activeTaskCount: Int { tasks.count }

    // MARK: - Event handling

    /// Replaces a transfer's placeholder with a row for the file that just started.
    private func began(_ item: TransferItem, in id: UUID) {
        guard var context = contexts[id] else { return }

        if !context.hasFileRows {
            rows.removeAll { $0.id == id.uuidString }
            context.hasFileRows = true
            contexts[id] = context
        }

        var row = makeRow(for: id, title: item.remote.name, item: item)
        row.totalBytes = item.size
        row.state = .moving
        rows.insert(row, at: 0)
    }

    private func flush(_ pending: inout [RemotePath: Int64], in id: UUID) {
        for (path, bytes) in pending {
            update(rowID(id, path)) { $0.transferredBytes = bytes }
        }
        pending.removeAll()
    }

    private func finished(_ item: TransferItem, _ outcome: ItemOutcome, in id: UUID) {
        update(rowID(id, item.remote)) { row in
            switch outcome {
            case .transferred(let bytes):
                row.transferredBytes = max(row.transferredBytes, bytes)
                row.state = .done
            case .skipped:
                row.state = .skipped
            case .failed(let error):
                row.state = .failed(error.errorDescription ?? "Failed")
            }
        }
    }

    /// Settles whatever is left when the transfer ends.
    ///
    /// A transfer that never started a file still has its placeholder, and that is the row that has to
    /// carry a whole-transfer failure — otherwise a refused connection would leave the panel empty.
    private func ended(_ id: UUID, report: TransferReport) {
        reports[id] = report

        for index in rows.indices where rows[index].transferID == id && !rows[index].isFinished {
            if let failure = report.failure {
                rows[index].state = .failed(failure.errorDescription ?? "Failed")
            } else if report.wasCancelled {
                rows[index].state = .cancelled
            } else {
                rows[index].state = .done
            }
        }
    }

    // MARK: - Helpers

    private func makeRow(for id: UUID, title: String, item: TransferItem? = nil) -> Row {
        let context = contexts[id]
        return Row(
            id: item.map { rowID(id, $0.remote) } ?? id.uuidString,
            transferID: id,
            title: title,
            connection: context?.connection ?? "",
            isDownload: context?.isDownload ?? true
        )
    }

    private func rowID(_ id: UUID, _ path: RemotePath) -> String {
        "\(id.uuidString)/\(path.pathString)"
    }

    private func update(_ rowID: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        change(&rows[index])
    }

    private func forget(_ id: UUID) {
        tasks[id] = nil
    }
}
