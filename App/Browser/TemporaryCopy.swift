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
/// hand the preview panel one. Both go through `TransferListModel.start` rather than the queue directly,
/// so the bytes are visible in the transfers panel like any other transfer — an app that goes quiet for
/// thirty seconds is indistinguishable from one that has hung.
@MainActor
enum TemporaryCopy {

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
    ///   - purpose: A word for the folder, so `drag-` and `preview-` copies are told apart by eye.
    /// - Returns: The file or folder on disk.
    /// - Throws: ``TemporaryCopyError`` if there is no connection, or the transfer did not succeed.
    static func fetch(_ path: RemotePath, named name: String, purpose: String) async throws -> URL {
        guard let environment, let browser = environment.browser, let host = browser.host else {
            throw TemporaryCopyError.notConnected
        }

        let folder = directory.appending(path: "\(purpose)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transfer = Transfer(
            host: host,
            work: .download(sources: [path], destination: folder),
            // Always overwrite: the folder is fresh, so there is nothing to resume onto, and asking the
            // user's policy about a temporary file answers the wrong question.
            overwritePolicy: .overwrite
        )

        await environment.transfers?.start(transfer, title: name)
        try await waitForFinish(transfer.id, named: name, in: environment)

        let url = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TemporaryCopyError.transferFailed(name)
        }
        return url
    }

    /// Waits for the transfer to report a result.
    ///
    /// Neither a drag nor a preview can use a file that is still arriving, and `start` returns as soon
    /// as the work is queued.
    private static func waitForFinish(
        _ id: UUID,
        named name: String,
        in environment: AppEnvironment
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let transfers = environment.transfers else { throw TemporaryCopyError.notConnected }

            if let report = transfers.report(of: id) {
                guard report.isSuccess else { throw TemporaryCopyError.transferFailed(name) }
                return
            }
            // Dismissed mid-flight: the rows are gone and no report will ever arrive.
            guard transfers.rows.contains(where: { $0.transferID == id }) else {
                throw TemporaryCopyError.transferFailed(name)
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
    /// The download did not complete.
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "DriverPro is not connected to a server."
        case .transferFailed(let name): "“\(name)” could not be downloaded."
        }
    }
}
