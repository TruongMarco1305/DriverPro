//
//  TemporaryCopy.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPTransfer
import SwiftUI

/// Fetches a remote entry into a temporary folder, through the ordinary transfer queue.
///
/// Two things need this: dragging out, which must hand Finder a real file, and Quick Look, which must
/// hand the preview panel one. They differ in whether the fetch is *work the user asked to keep* — see
/// ``Purpose`` — and that is the only thing this type branches on.
@MainActor
enum TemporaryCopy {

    /// Why a copy is being made, which decides how visible the fetch is.
    enum Purpose {
        /// Dragging to Finder. The user keeps the result, so it is listed and journalled like any
        /// download: a 4 GB drag going quiet for a minute is indistinguishable from a hang.
        case drag
        /// Quick Look. Fetched, glanced at, thrown away — so it gets no row in the transfers panel and
        /// is never journalled.
        case preview

        /// Names the temp folder, so `drag-` and `preview-` copies are told apart by eye.
        var folderPrefix: String {
            switch self {
            case .drag: "drag"
            case .preview: "preview"
            }
        }
    }

    /// What the app is, once it has been built.
    ///
    /// A static rather than an injected dependency because `Transferable`'s exporting closure is a
    /// `static` requirement with nowhere to thread context through. Quick Look does not need it, but
    /// sharing one entry point is worth more than one caller passing its own.
    static weak var environment: AppEnvironment?

    /// The folder every temporary copy is written under, so a stale one is obvious.
    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "DriverPro")
    }

    /// Downloads one remote entry and returns the local copy.
    ///
    /// - Parameters:
    ///   - path: What to fetch. A directory is fetched whole.
    ///   - name: What it is called, and what the copy is named on disk.
    ///   - purpose: What the copy is for, which decides whether it appears in the transfers panel.
    /// - Returns: The file or folder on disk.
    /// - Throws: ``TemporaryCopyError`` if there is no connection, or the transfer did not succeed.
    static func fetch(
        _ path: RemotePath,
        named name: String,
        purpose: Purpose
    ) async throws -> URL {
        guard let environment, let browser = environment.browser, let host = browser.host else {
            throw TemporaryCopyError.notConnected
        }

        let folder = directory.appending(path: "\(purpose.folderPrefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transfer = Transfer(
            host: host,
            work: .download(sources: [path], destination: folder),
            // Always overwrite: the folder is fresh, so there is nothing to resume onto, and asking the
            // user's policy about a temporary file answers the wrong question.
            overwritePolicy: .overwrite
        )

        switch purpose {
        case .drag:
            await environment.transfers?.start(transfer, title: name)
            try await waitForFinish(transfer.id, named: name, in: environment)
        case .preview:
            try await runUnlisted(transfer, named: name, in: environment)
        }

        let url = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TemporaryCopyError.transferFailed(name: name, reason: nil)
        }
        return url
    }

    /// Runs a transfer without the transfers panel knowing about it, and waits for it to end.
    ///
    /// Straight to the queue rather than through `TransferListModel`: a preview should leave no trace,
    /// and that means no row, no toolbar badge, and no journal entry to restore after a quit — the
    /// folder this writes into is deleted at quit, so a restored preview would resume into nothing.
    ///
    /// The stream ends with exactly one `.finished`, so waiting is a `for await` rather than the polling
    /// the listed path needs. Cancellation comes free with it: abandoning the loop terminates the
    /// stream, and ``TransferQueue`` cancels the transfer when that happens.
    private static func runUnlisted(
        _ transfer: Transfer,
        named name: String,
        in environment: AppEnvironment
    ) async throws {
        guard let services = environment.services else { throw TemporaryCopyError.notConnected }

        let stream = await services.queue.run(transfer, title: name, journalled: false)
        var report: TransferReport?
        for await event in stream {
            if case .finished(let finished) = event { report = finished }
        }

        guard let report, report.isSuccess else {
            throw TemporaryCopyError.transferFailed(name: name,
                                                    reason: report?.failure?.errorDescription)
        }
    }

    /// Waits for a listed transfer to report a result.
    ///
    /// A drag cannot use a file that is still arriving, and `start` returns as soon as the work is
    /// queued. Polling rather than awaiting the stream because `TransferListModel` owns it.
    private static func waitForFinish(
        _ id: UUID,
        named name: String,
        in environment: AppEnvironment
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let transfers = environment.transfers else { throw TemporaryCopyError.notConnected }

            if let report = transfers.report(of: id) {
                guard report.isSuccess else {
                    throw TemporaryCopyError.transferFailed(
                        name: name, reason: report.failure?.errorDescription)
                }
                return
            }
            // Dismissed mid-flight: the rows are gone and no report will ever arrive.
            guard transfers.rows.contains(where: { $0.transferID == id }) else {
                throw TemporaryCopyError.transferFailed(name: name, reason: nil)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Removes every temporary copy.
    ///
    /// Called at quit: a cancelled drag or a closed preview leaves its download behind, and nothing else
    /// clears it — the OS may not touch the temporary directory for weeks.
    nonisolated static func clearAll() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "DriverPro")
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Why a temporary copy could not be produced.
enum TemporaryCopyError: LocalizedError {
    /// There is no connection to fetch from.
    case notConnected
    /// The download did not complete, with what the server said if it said anything.
    ///
    /// The reason is carried rather than dropped because a preview has no failed row to read it from:
    /// "permission denied" and "the file went away" both become the same sentence without it.
    case transferFailed(name: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "DriverPro is not connected to a server."
        case .transferFailed(let name, let reason):
            reason.map { "“\(name)” could not be downloaded. \($0)" }
                ?? "“\(name)” could not be downloaded."
        }
    }
}
