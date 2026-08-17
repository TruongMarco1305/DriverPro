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

/// The transfers window's contents.
@MainActor
@Observable
public final class TransferListModel {

    /// One transfer, as shown to the user.
    public struct Row: Identifiable, Sendable {
        /// The transfer's identity, matching what `TransferQueue` was given.
        public let id: UUID
        /// What to call it in the list.
        public let title: String
        /// Whether it is coming down or going up.
        public let isDownload: Bool

        /// Files planned, once enumeration has finished.
        public var plannedItems = 0
        /// Total bytes, when every file's size was known.
        public var totalBytes: Int64?
        /// Bytes moved so far.
        public var transferredBytes: Int64 = 0
        /// The file currently moving.
        public var currentItem: String?
        /// The tally, once the run has ended.
        public var report: TransferReport?

        /// Whether this transfer was left unfinished by a quit and is waiting to be resumed.
        ///
        /// Distinct from "not finished": an interrupted transfer is standing still, so a progress bar
        /// would be reporting movement that is not happening.
        public var isInterrupted = false

        /// Whether the run has ended.
        public var isFinished: Bool { report != nil }

        /// How far along, or `nil` when the total is unknown and a bar would be a guess.
        public var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }
    }

    private let services: DriverProServices
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Transfers restored from the journal, held until the user resumes or dismisses them.
    private var interrupted: [UUID: StoredTransfer] = [:]

    /// Transfers, newest first.
    public private(set) var rows: [Row] = []

    /// Creates a list over an assembled engine.
    /// - Parameter services: The wired engine.
    public init(services: DriverProServices) {
        self.services = services
    }

    /// Whether anything is still running.
    public var hasActiveTransfers: Bool { rows.contains { !$0.isFinished && !$0.isInterrupted } }

    /// What the browser's status bar shows, or `nil` when nothing is running.
    ///
    /// Computed rather than stored: it reads rows whose progress is already coalesced, so it inherits
    /// that throttling instead of needing its own.
    public struct ActiveSummary: Hashable, Sendable {
        /// The file moving now, or the transfer's name before one starts.
        public let title: String
        /// Overall progress, or `nil` when any running transfer has no known total.
        public let fraction: Double?
        /// How many transfers are running.
        public let activeCount: Int
        /// How many are interrupted and waiting to be resumed.
        public let interruptedCount: Int
    }

    /// A one-line summary of everything in flight or waiting.
    public var activeSummary: ActiveSummary? {
        let active = rows.filter { !$0.isFinished && !$0.isInterrupted }
        let waiting = rows.filter(\.isInterrupted)

        guard let first = active.first else {
            // Nothing moving, but something is waiting: worth saying, with no bar — the status bar is
            // how an interrupted transfer gets noticed at all, since no window opens itself.
            guard let firstWaiting = waiting.first else { return nil }
            return ActiveSummary(title: firstWaiting.title, fraction: nil,
                                 activeCount: 0, interruptedCount: waiting.count)
        }

        // Aggregate across transfers, but only when every one of them knows its total. Mixing a known
        // total with an unknown one would produce a bar that jumps when the unknown one finishes.
        let totals = active.map(\.totalBytes)
        let fraction: Double? = {
            guard !totals.contains(where: { $0 == nil }) else { return nil }
            let total = totals.compactMap { $0 }.reduce(0, +)
            guard total > 0 else { return nil }
            let moved = active.map(\.transferredBytes).reduce(0, +)
            return min(1, Double(moved) / Double(total))
        }()

        return ActiveSummary(
            title: first.currentItem ?? first.title,
            fraction: fraction,
            activeCount: active.count,
            interruptedCount: waiting.count
        )
    }

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
        let known = Set(rows.map(\.id))

        for item in stored where !known.contains(item.id) {
            interrupted[item.id] = item
            var row = Row(id: item.id, title: item.title, isDownload: item.transfer.isDownload)
            row.isInterrupted = true
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
        rows.removeAll { $0.id == id }

        let stream = await services.queue.run(stored.transfer, title: stored.title)
        consume(stream, id: id, title: stored.title, isDownload: stored.transfer.isDownload)
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
        consume(stream, id: transfer.id, title: title, isDownload: transfer.isDownload)
    }

    /// Consumes an event stream into a row.
    ///
    /// Separated from ``start(_:title:)`` so tests can feed a stream directly rather than standing up a
    /// queue and a server.
    func consume(
        _ stream: AsyncStream<TransferEvent>,
        id: UUID,
        title: String,
        isDownload: Bool
    ) {
        rows.insert(Row(id: id, title: title, isDownload: isDownload), at: 0)

        tasks[id] = Task { [weak self] in
            var throttle = ProgressThrottle()
            var pendingBytes: Int64 = 0

            for await event in stream {
                guard let self else { return }

                switch event {
                case .planned(let items, let bytes):
                    update(id) { $0.plannedItems = items; $0.totalBytes = bytes }

                case .itemStarted(let item):
                    update(id) { $0.currentItem = item.remote.name }

                case .progress(let bytes, _):
                    // Coalesced: the byte count is remembered every time, but written only when it is
                    // worth redrawing.
                    pendingBytes = bytes
                    if throttle.shouldEmit(now: Date()) {
                        update(id) { $0.transferredBytes = pendingBytes }
                    }

                case .itemFinished:
                    update(id) { $0.transferredBytes = pendingBytes }

                case .finished(let report):
                    update(id) {
                        $0.transferredBytes = max(pendingBytes, report.bytes)
                        $0.currentItem = nil
                        $0.report = report
                    }
                }
            }
            await self?.forget(id)
        }
    }

    /// Stops a running transfer. The row stays, showing what it managed.
    /// - Parameter id: Which transfer.
    public func cancel(_ id: UUID) async {
        await services.queue.cancel(id)
    }

    /// Cancels a transfer and removes its row.
    ///
    /// The consuming task is cancelled too — a row can be dismissed while its stream is still
    /// producing, and a task left running would go on writing to a row nobody can see.
    ///
    /// - Parameter id: Which transfer.
    public func dismiss(_ id: UUID) async {
        await services.queue.cancel(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        rows.removeAll { $0.id == id }

        // Forgotten in the journal too, or an interrupted transfer the user dismissed would come back
        // at the next launch.
        interrupted[id] = nil
        try? await services.journal.forget(id)
    }

    /// Removes every finished row.
    public func clearFinished() {
        for row in rows where row.isFinished {
            tasks[row.id]?.cancel()
            tasks[row.id] = nil
        }
        rows.removeAll { $0.isFinished }
    }

    /// How many consuming tasks are alive. For tests.
    var activeTaskCount: Int { tasks.count }

    // MARK: - Helpers

    private func update(_ id: UUID, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    private func forget(_ id: UUID) {
        tasks[id] = nil
    }
}
