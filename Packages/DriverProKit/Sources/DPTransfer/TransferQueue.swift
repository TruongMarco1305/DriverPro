//
//  TransferQueue.swift
//  DPTransfer
//

import DPCore
import Foundation

/// Runs transfers: enumerate, then move files with bounded concurrency, reporting as it goes.
///
/// ## Swift note — `TaskGroup`
/// Files move inside a `withThrowingTaskGroup`. A group runs child tasks concurrently and, crucially,
/// cannot outlive its own scope — when the enclosing function returns, every child is finished or
/// cancelled. That is what makes "cancel the transfer" reliable rather than best-effort.
///
/// Concurrency is bounded by starting only `maxConcurrentFiles` children, then adding one more each
/// time a child finishes. Launching all of them at once would open a connection per file.
public actor TransferQueue {

    private let pool: SessionPool
    private let maxConcurrentFiles: Int
    private let journal: (any TransferJournal)?
    private var running: [UUID: Task<Void, Never>] = [:]

    /// Creates a queue.
    ///
    /// - Parameters:
    ///   - pool: Where connections come from.
    ///   - maxConcurrentFiles: How many files move at once. Should not exceed the pool's per-host limit,
    ///     or workers simply queue for connections.
    ///   - journal: Where unfinished transfers are remembered. `nil` means a transfer is forgotten when
    ///     the process ends, which is what tests want and what M1 did.
    public init(
        pool: SessionPool,
        maxConcurrentFiles: Int = 4,
        journal: (any TransferJournal)? = nil
    ) {
        self.pool = pool
        self.maxConcurrentFiles = maxConcurrentFiles
        self.journal = journal
    }

    // MARK: - Running

    /// Starts a transfer and returns the stream of what happens to it.
    ///
    /// The work begins immediately; consuming the stream is optional. The stream always ends with exactly
    /// one ``TransferEvent/finished(_:)``, including when the transfer is cancelled or fails.
    ///
    /// - Parameter transfer: What to move.
    /// - Returns: Events, in order.
    /// - Parameter title: What to call it if it has to be restored after a quit. Defaults to the id.
    public func run(_ transfer: Transfer, title: String? = nil) -> AsyncStream<TransferEvent> {
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()

        let task = Task {
            // Recorded before any work starts: a transfer that dies during planning is still one the
            // user asked for, and should come back.
            try? await journal?.record(transfer, title: title ?? transfer.id.uuidString)

            let report = await execute(transfer, emit: { continuation.yield($0) })

            // However it ended, it has ended — and the journal holds only what has not.
            try? await journal?.forget(transfer.id)

            continuation.yield(.finished(report))
            continuation.finish()
            self.forget(transfer.id)
        }
        running[transfer.id] = task

        // Stopping the consumer stops the work; abandoning a transfers window should not keep writing.
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                Task { await self?.cancel(transfer.id) }
            }
        }
        return stream
    }

    /// Cancels a running transfer. Unknown ids are ignored.
    /// - Parameter id: Which transfer to stop.
    public func cancel(_ id: UUID) {
        running[id]?.cancel()
    }

    private func forget(_ id: UUID) {
        running[id] = nil
    }

    // MARK: - Execution

    private func execute(
        _ transfer: Transfer,
        emit: @escaping @Sendable (TransferEvent) -> Void
    ) async -> TransferReport {
        var report = TransferReport()

        do {
            let plan = try await plan(transfer)
            emit(.planned(items: plan.items.count, bytes: totalBytes(of: plan.items)))

            // Sources that could not be enumerated are reported individually, with their real paths,
            // and do not stop the sources that were fine.
            for failure in plan.failures {
                report.failed += 1
                emit(.itemFinished(failure.item, .failed(failure.error)))
            }

            // Directories first, parents before children, so a file never arrives before its folder.
            // Done serially: creating them concurrently races on shared parents.
            try await createDirectories(for: transfer, items: plan.items)

            let files = plan.items.filter { !$0.isDirectory }
            let transferred = await transferFiles(files, in: transfer, emit: emit)

            // Accumulated, not assigned — assigning would discard the planning failures counted above.
            report.transferred += transferred.transferred
            report.skipped += transferred.skipped
            report.failed += transferred.failed
            report.bytes += transferred.bytes
            report.wasCancelled = report.wasCancelled || transferred.wasCancelled
        } catch is CancellationError {
            report.wasCancelled = true
        } catch {
            // Only whole-transfer failures reach here: the connection was refused, or the credentials
            // were. `.planned` has not been emitted yet, so emit it with zeros to keep the contract that
            // it always comes first.
            emit(.planned(items: 0, bytes: 0))
            report.failure = asSessionError(error)
        }

        if Task.isCancelled { report.wasCancelled = true }
        return report
    }

    /// What a transfer will move, and which of its sources could not be read.
    private struct TransferPlan {
        var items: [TransferItem] = []
        var failures: [(item: TransferItem, error: SessionError)] = []
    }

    /// Works out every file and directory the transfer touches, and where each one lands.
    ///
    /// Throws only when the transfer cannot proceed at all — chiefly a failure to get a connection. A
    /// source that cannot be enumerated is recorded as a failure and the rest are still planned.
    private func plan(_ transfer: Transfer) async throws -> TransferPlan {
        switch transfer.work {
        case .download(let sources, let destination):
            return try await pool.withSession(for: transfer.host) { session in
                var plan = TransferPlan()
                for source in sources {
                    let localForSource = destination.appending(path: source.name)
                    do {
                        // `walk` returns parents before children, which is the order directories must
                        // be created in. Reusing it keeps tree traversal in one place.
                        let found = try await session.walk(source)
                        let base = source.parent ?? .root
                        for item in found {
                            guard let tail = base.relativeComponents(to: item.path) else { continue }
                            plan.items.append(TransferItem(
                                remote: item.path,
                                local: destination.appending(path: tail.joined(separator: "/")),
                                isDirectory: item.isDirectory,
                                size: item.size
                            ))
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        plan.failures.append((
                            TransferItem(remote: source, local: localForSource, isDirectory: false),
                            asSessionError(error)
                        ))
                    }
                }
                return plan
            }

        case .upload(let sources, let destination):
            var plan = TransferPlan()
            for source in sources {
                do {
                    plan.items.append(contentsOf: try enumerateLocal(source, into: destination))
                } catch {
                    plan.failures.append((
                        TransferItem(remote: destination.appending(source.lastPathComponent),
                                     local: source, isDirectory: false),
                        asSessionError(error)
                    ))
                }
            }
            return plan
        }
    }

    /// Walks a local file or folder, mapping each entry onto its remote destination.
    private func enumerateLocal(_ source: URL, into destination: RemotePath) throws -> [TransferItem] {
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let root = destination.appending(source.lastPathComponent)

        guard isDirectory else {
            return [TransferItem(remote: root, local: source, isDirectory: false,
                                 size: LocalFileIO.size(of: source))]
        }

        var items = [TransferItem(remote: root, local: source, isDirectory: true)]

        // `.skipsHiddenFiles` is deliberately absent — a dotfile the user selected should be uploaded.
        // Symbolic links are not followed, so a link pointing back up the tree cannot loop forever.
        let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: []
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator?.skipDescendants()
                continue
            }
            guard let tail = relativeComponents(of: url, under: source) else { continue }

            items.append(TransferItem(
                remote: root.appending(path: tail.joined(separator: "/")),
                local: url,
                isDirectory: values?.isDirectory ?? false,
                size: LocalFileIO.size(of: url)
            ))
        }
        return items
    }

    private func createDirectories(for transfer: Transfer, items: [TransferItem]) async throws {
        let directories = items
            .filter(\.isDirectory)
            .sorted { $0.remote.components.count < $1.remote.components.count }
        guard !directories.isEmpty else { return }

        if transfer.isDownload {
            for directory in directories {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(
                    at: directory.local, withIntermediateDirectories: true)
            }
        } else {
            try await pool.withSession(for: transfer.host) { session in
                for directory in directories {
                    try Task.checkCancellation()
                    // Already there is success, not failure — a second upload into the same tree is
                    // normal, and the alternative is an exists-check round trip per directory.
                    do {
                        try await session.createDirectory(directory.remote)
                    } catch SessionError.alreadyExists {
                        continue
                    }
                }
            }
        }
    }

    /// Moves the files, `maxConcurrentFiles` at a time.
    private func transferFiles(
        _ files: [TransferItem],
        in transfer: Transfer,
        emit: @escaping @Sendable (TransferEvent) -> Void
    ) async -> TransferReport {
        // The journal is updated per finished file, not per chunk: a write every few kilobytes would
        // cost more than the transfer, and the counters are only there so a restored row can say how
        // far it got.
        var report = TransferReport()
        let total = totalBytes(of: files)
        let progress = ProgressReporter(grandTotal: total, emit: emit)

        await withTaskGroup(of: (TransferItem, ItemOutcome).self) { group in
            var next = 0

            func addWorker() {
                guard next < files.count else { return }
                let item = files[next]
                next += 1
                group.addTask { [pool] in
                    emit(.itemStarted(item))
                    let outcome = await Self.move(
                        item, in: transfer, pool: pool,
                        onBytes: { await progress.add($0, for: item) }
                    )
                    return (item, outcome)
                }
            }

            for _ in 0..<Swift.min(maxConcurrentFiles, files.count) { addWorker() }

            while let (item, outcome) = await group.next() {
                switch outcome {
                case .transferred(let bytes):
                    report.transferred += 1
                    report.bytes += bytes
                case .skipped:
                    report.skipped += 1
                case .failed:
                    report.failed += 1
                }
                emit(.itemFinished(item, outcome))
                try? await journal?.updateCounters(for: transfer.id, report: report)

                if Task.isCancelled {
                    report.wasCancelled = true
                    group.cancelAll()
                } else {
                    addWorker()
                }
            }
        }
        return report
    }

    /// Moves one file. Never throws — a single failure must not abandon the rest of the queue.
    private static func move(
        _ item: TransferItem,
        in transfer: Transfer,
        pool: SessionPool,
        onBytes: @escaping @Sendable (Int) async -> Void
    ) async -> ItemOutcome {
        do {
            return try await pool.withSession(for: transfer.host) { session in
                transfer.isDownload
                    ? try await download(item, session: session, policy: transfer.overwritePolicy, onBytes: onBytes)
                    : try await upload(item, session: session, policy: transfer.overwritePolicy, onBytes: onBytes)
            }
        } catch {
            return .failed(asSessionError(error))
        }
    }

    private static func download(
        _ item: TransferItem,
        session: any Session,
        policy: OverwritePolicy,
        onBytes: @escaping @Sendable (Int) async -> Void
    ) async throws -> ItemOutcome {
        var destination = item.local
        var offset: Int64 = 0

        if FileManager.default.fileExists(atPath: destination.path) {
            switch policy {
            case .skip:
                return .skipped
            case .rename:
                destination = await LocalFileIO.uniqueURL(for: destination)
            case .resume where session.capabilities.contains(.resumeDownload):
                offset = LocalFileIO.size(of: destination) ?? 0

                // Resuming assumes what is already on disk is a *prefix* of the remote file. A local
                // file LARGER than the source cannot be — it is a different file that happens to share
                // the name — so start again rather than reporting success and keeping it.
                //
                // The reverse case, a smaller unrelated file, cannot be told apart from a genuinely
                // interrupted download without hashing. That is the assumption `.resume` rests on, and
                // the reason the policy is selectable.
                if let size = item.size {
                    if offset > size {
                        offset = 0
                    } else if offset == size {
                        return .transferred(bytes: 0)   // already complete
                    }
                }
            case .resume, .overwrite:
                offset = 0
            }
        }

        let stream = try await session.read(item.remote, from: offset)
        let written = try await LocalFileIO.write(stream, to: destination, resumingAt: offset,
                                                  onProgress: onBytes)
        return .transferred(bytes: written)
    }

    private static func upload(
        _ item: TransferItem,
        session: any Session,
        policy: OverwritePolicy,
        onBytes: @escaping @Sendable (Int) async -> Void
    ) async throws -> ItemOutcome {
        var destination = item.remote
        var offset: Int64 = 0

        if await session.exists(destination) {
            switch policy {
            case .skip:
                return .skipped
            case .rename:
                destination = await uniqueRemotePath(for: destination, session: session)
            case .resume where session.capabilities.contains(.resumeUpload):
                offset = (try? await session.stat(destination).size) ?? 0

                // Same reasoning as the download side: a remote file larger than the local source
                // cannot be a partial copy of it.
                if let size = item.size {
                    if offset > size {
                        offset = 0
                    } else if offset == size {
                        return .transferred(bytes: 0)
                    }
                }
            case .resume, .overwrite:
                offset = 0
            }
        }

        let size = item.size ?? LocalFileIO.size(of: item.local)

        // Count what actually leaves the disk. Reporting the *planned* size means a file whose size
        // could not be read is recorded as zero bytes despite transferring fine.
        let counter = ByteCounter()
        let stream = LocalFileIO.read(item.local, from: offset) { bytes in
            await counter.add(bytes)
            await onBytes(bytes)
        }
        try await session.write(destination, contents: stream, size: size, resumingAt: offset)
        return .transferred(bytes: await counter.total)
    }

    /// The remote equivalent of ``LocalFileIO/uniqueURL(for:)``, sharing its naming rule.
    private static func uniqueRemotePath(
        for path: RemotePath,
        session: any Session
    ) async -> RemotePath {
        let parent = path.parent ?? .root
        let name = await LocalFileIO.uniqueName(stem: path.stem, extension: path.pathExtension) {
            await session.exists(parent.appending($0))
        }
        return parent.appending(name)
    }

    // MARK: - Helpers

    private func totalBytes(of items: [TransferItem]) -> Int64? {
        let sizes = items.filter { !$0.isDirectory }.compactMap(\.size)
        guard sizes.count == items.filter({ !$0.isDirectory }).count else { return nil }
        return sizes.reduce(0, +)
    }

    private func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
            return nil
        }
        return Array(parts.dropFirst(rootParts.count))
    }
}

/// Running byte total, shared by the workers.
///
/// Counting and emitting happen together inside the actor. Doing them separately — incrementing here
/// and emitting from a detached task — makes the count correct but the *events* unordered, so a
/// progress bar jumps around and the final value can be missed entirely because the run finished while
/// emissions were still in flight.
private actor ProgressReporter {
    private var total: Int64 = 0
    private var perItem: [RemotePath: Int64] = [:]
    private let grandTotal: Int64?
    private let emit: @Sendable (TransferEvent) -> Void

    init(grandTotal: Int64?, emit: @escaping @Sendable (TransferEvent) -> Void) {
        self.grandTotal = grandTotal
        self.emit = emit
    }

    /// Counts bytes for one file and for the transfer, and says so.
    ///
    /// Both events are emitted here, in this order, for the same reason the count lives here: files
    /// move concurrently, so the only place where "this file's total" and "the transfer's total" are
    /// consistent with each other is inside the actor that owns them both.
    func add(_ bytes: Int, for item: TransferItem) {
        let moved = (perItem[item.remote] ?? 0) + Int64(bytes)
        perItem[item.remote] = moved
        total += Int64(bytes)

        emit(.itemProgress(item, bytes: moved))
        emit(.progress(bytes: total, of: grandTotal))
    }
}

/// Bytes actually read from disk during one upload.
private actor ByteCounter {
    private(set) var total: Int64 = 0

    func add(_ bytes: Int) { total += Int64(bytes) }
}

/// Normalises anything thrown into a `SessionError`, so outcomes stay comparable.
private func asSessionError(_ error: any Error) -> SessionError {
    if let sessionError = error as? SessionError { return sessionError }
    if error is CancellationError { return .cancelled }
    return .transport(error.localizedDescription)
}
