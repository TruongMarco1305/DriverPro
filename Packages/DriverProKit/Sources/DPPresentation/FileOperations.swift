//
//  FileOperations.swift
//  DPPresentation
//

import DPCore
import DPTransfer
import Foundation

/// Acting on the current directory and selection: creating, renaming, deleting, and moving files.
///
/// These live on ``BrowserModel`` because that is what they operate on. Each refreshes the listing
/// afterwards and reports failures the same way navigation does.
extension BrowserModel {

    // MARK: - What the server allows

    /// Whether the connected backend can rename.
    ///
    /// The UI asks before offering the command. A greyed-out Rename with a reason beats an error alert
    /// after the click — S3 has no rename at all, so this will matter for real in M4.
    public var canRename: Bool { capabilities.contains(.rename) }

    /// Whether permissions can be changed on this backend.
    public var canChangePermissions: Bool { capabilities.contains(.posixPermissions) }

    // MARK: - Namespace

    /// Creates a directory inside the current one.
    ///
    /// - Parameter name: The folder's name. A name containing separators is treated as one component.
    public func createDirectory(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let host else { return }

        await perform(host) { session in
            try await session.createDirectory(self.path.appending(trimmed))
        }
    }

    /// Renames an entry, keeping it in the same directory.
    ///
    /// - Parameters:
    ///   - item: What to rename.
    ///   - newName: Its new name.
    public func rename(_ item: RemoteItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name, let host else { return }

        await perform(host) { session in
            try await session.move(item.path, to: item.path.renamed(to: trimmed))
        }
    }

    /// Deletes entries, including directories and everything under them.
    ///
    /// Uses ``Session/deleteTree(_:)``, which walks the tree depth-first on backends without a
    /// recursive delete — SFTP among them.
    ///
    /// - Parameter items: What to remove.
    public func delete(_ items: [RemoteItem]) async {
        guard !items.isEmpty, let host else { return }

        await perform(host) { session in
            for item in items {
                try Task.checkCancellation()
                try await session.deleteTree(item.path)
            }
        }
    }

    // MARK: - Transfers

    /// Builds a download of the selected entries into a local folder.
    ///
    /// Returns the job rather than starting it: the transfer list owns running things, and keeping that
    /// separation means the browser does not need to know a queue exists.
    ///
    /// - Parameters:
    ///   - items: What to fetch. Directories are taken whole.
    ///   - destination: The local folder to write into.
    ///   - policy: What to do about files that already exist.
    /// - Returns: The job, or `nil` if there is nothing to do.
    public func makeDownload(
        of items: [RemoteItem],
        to destination: URL,
        policy: OverwritePolicy = .resume
    ) -> Transfer? {
        guard let host, !items.isEmpty else { return nil }
        return Transfer(
            host: host,
            work: .download(sources: items.map(\.path), destination: destination),
            overwritePolicy: policy
        )
    }

    /// Builds an upload of local files into the directory being shown.
    ///
    /// - Parameters:
    ///   - urls: What to send. Folders are taken whole.
    ///   - policy: What to do about files that already exist.
    /// - Returns: The job, or `nil` if there is nothing to do.
    public func makeUpload(of urls: [URL], policy: OverwritePolicy = .resume) -> Transfer? {
        guard let host, !urls.isEmpty else { return nil }
        return Transfer(
            host: host,
            work: .upload(sources: urls, destination: path),
            overwritePolicy: policy
        )
    }

    /// The entries currently selected, in the order shown.
    public var selectedItems: [RemoteItem] {
        visibleItems.filter { selection.contains($0.path) }
    }

    // MARK: - Shared plumbing

    /// Runs an operation, then refreshes. A failure reports why and leaves the listing alone.
    private func perform(
        _ host: RemoteHost,
        _ body: @escaping @Sendable (any Session) async throws -> Void
    ) async {
        do {
            try await services.withSession(for: host, body)
            await refresh()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}
