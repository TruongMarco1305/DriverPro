//
//  DraggedRemoteFile.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPTransfer
import SwiftUI
import UniformTypeIdentifiers

/// A remote entry being dragged to Finder.
///
/// The file does not exist locally yet, so the drag has to fetch it before anything can receive it. The
/// fetch runs through the normal transfer queue into a temporary folder, and that folder's copy is what
/// Finder is handed — so the drag shows real progress in the transfers panel instead of a spinner with
/// nothing behind it.
///
/// **The cost:** the bytes land on disk twice, once in temp and once where they were dropped. That is
/// the price of staying inside SwiftUI's drag model; `NSFilePromiseProvider` writes straight to the
/// destination but needs an AppKit bridge inside the table. See `docs/decisions/012-drag-and-drop.md`.
struct DraggedRemoteFile: Codable, Sendable {

    /// Where the file lives on the server.
    let path: RemotePath
    /// What it is called, and what the temp copy is named.
    let name: String
    /// Whether the drag is a whole tree.
    let isDirectory: Bool

    init(_ item: RemoteItem) {
        self.path = item.path
        self.name = item.name
        self.isDirectory = item.isDirectory
    }
}

extension DraggedRemoteFile: Transferable {

    /// ## Swift note — `Transferable`
    /// One conformance describes every way a value can leave the app. `FileRepresentation` says "this is
    /// a file on disk", and its `exporting` closure is `async` — the receiver waits while it runs, which
    /// is what lets a download happen inside a drag.
    ///
    /// `.data` rather than a specific type because a remote entry may be anything, a folder included.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { dragged in
            let url = try await DragExport.fetch(dragged)
            // The temp copy is ours and nothing else will read it, so Finder may take it in place
            // rather than making a third copy.
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }
}

/// Fetches dragged entries into a temporary folder, through the ordinary transfer queue.
@MainActor
enum DragExport {

    /// Where the drag's environment comes from. Set once the app has built one.
    ///
    /// A static rather than an injected dependency because `Transferable`'s exporting closure is a
    /// `static` requirement with no way to pass context through it.
    static weak var environment: AppEnvironment?

    /// The folder every drag writes into, under one parent so a stale one is obvious.
    static var temporaryDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "DriverPro")
    }

    /// Downloads one dragged entry and returns the local copy.
    ///
    /// - Parameter dragged: What is being dragged.
    /// - Returns: The file or folder on disk, ready to hand over.
    /// - Throws: If there is no connection, or the transfer failed.
    static func fetch(_ dragged: DraggedRemoteFile) async throws -> URL {
        guard let environment, let browser = environment.browser, let host = browser.host else {
            throw DragError.notConnected
        }

        let folder = temporaryDirectory.appending(path: "drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transfer = Transfer(
            host: host,
            work: .download(sources: [dragged.path], destination: folder),
            // Always overwrite: the folder is fresh, so there is nothing to resume onto, and asking
            // the user's policy about a temp file would be answering the wrong question.
            overwritePolicy: .overwrite
        )

        // Through the list rather than the queue directly, so a drag looks like every other transfer:
        // a row of its own in the panel, with a progress bar and the toolbar badge.
        await environment.transfers?.start(transfer, title: dragged.name)
        try await waitForFinish(transfer.id, named: dragged.name, in: environment)

        let url = folder.appending(path: dragged.name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DragError.transferFailed(dragged.name)
        }
        return url
    }

    /// Waits for the transfer to report a result.
    ///
    /// The drag cannot hand over a file that is still arriving, and `start` returns as soon as the work
    /// is queued.
    private static func waitForFinish(
        _ id: UUID,
        named name: String,
        in environment: AppEnvironment
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let transfers = environment.transfers else { throw DragError.notConnected }

            if let report = transfers.report(of: id) {
                guard report.isSuccess else { throw DragError.transferFailed(name) }
                return
            }
            // Dismissed mid-drag: the rows are gone and no report will ever arrive.
            guard transfers.rows.contains(where: { $0.transferID == id }) else {
                throw DragError.transferFailed(name)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Removes every drag's temporary folder.
    ///
    /// Called at quit: a cancelled drag leaves its partial download behind, and without this they
    /// accumulate until the OS clears the temporary directory, which may be never.
    nonisolated static func clearTemporaryFiles() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "DriverPro")
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Why a drag out could not produce a file.
enum DragError: LocalizedError {
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
