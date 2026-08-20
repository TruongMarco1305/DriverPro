//
//  BookmarkListModel.swift
//  DPPresentation
//

import DPBookmarks
import DPCore
import Foundation
import Observation

/// The sidebar's contents.
///
/// A thin layer over `BookmarkStore`: it exists so the view never awaits an actor directly, and so
/// "what does the sidebar show after a delete?" is a question `swift test` can answer.
@MainActor
@Observable
public final class BookmarkListModel {

    private let store: BookmarkStore

    /// Saved connections, sorted by display name.
    public private(set) var bookmarks: [RemoteHost] = []
    /// A message to show the user, or `nil`.
    public private(set) var errorMessage: String?

    /// Creates a list over a store.
    /// - Parameter store: Where bookmarks live.
    public init(store: BookmarkStore) {
        self.store = store
    }

    /// Reloads from disk.
    public func reload() async {
        do {
            bookmarks = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = BrowserModel.message(for: error)
        }
    }

    /// Saves a bookmark and reloads.
    /// - Parameter host: The bookmark to write.
    public func save(_ host: RemoteHost) async {
        do {
            try await store.save(host)
            await reload()
        } catch {
            errorMessage = BrowserModel.message(for: error)
        }
    }

    /// Deletes a bookmark and reloads.
    ///
    /// The Keychain item is deliberately left alone: bookmarks and secrets have separate lifetimes, and
    /// removing a password because a shortcut to it was deleted would be surprising. Tidying orphans is
    /// an explicit action, not a side effect.
    ///
    /// - Parameter id: Which bookmark to remove.
    public func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            await reload()
        } catch {
            errorMessage = BrowserModel.message(for: error)
        }
    }

    // MARK: - Cyberduck interchange

    /// Imports `.duck` files and reloads.
    ///
    /// - Parameters:
    ///   - urls: Files or folders, as a picker or a drop hands them over.
    ///   - supported: Protocols this build can connect with, from the catalog.
    /// - Returns: What happened, for the view to report, or `nil` if the import itself failed.
    @discardableResult
    public func importDuck(
        from urls: [URL],
        supported: Set<ProtocolIdentifier>
    ) async -> DuckImportSummary? {
        do {
            let summary = try await store.importDuck(from: urls, supported: supported)
            await reload()
            return summary
        } catch {
            errorMessage = BrowserModel.message(for: error)
            return nil
        }
    }

    /// Writes every bookmark to a folder as `.duck` files.
    ///
    /// - Parameter directory: Where to write.
    /// - Returns: How many were written, or `nil` if the export failed.
    @discardableResult
    public func exportDuck(to directory: URL) async -> Int? {
        do {
            return try await store.exportDuck(to: directory)
        } catch {
            errorMessage = BrowserModel.message(for: error)
            return nil
        }
    }

    /// Writes one bookmark to one `.duck` file.
    ///
    /// - Parameters:
    ///   - host: The bookmark to write.
    ///   - file: Where to write it.
    /// - Returns: Whether it was written.
    @discardableResult
    public func exportDuck(_ host: RemoteHost, to file: URL) async -> Bool {
        do {
            try await store.exportDuck(host, to: file)
            return true
        } catch {
            errorMessage = BrowserModel.message(for: error)
            return false
        }
    }

    /// Clears the current message.
    public func dismissError() {
        errorMessage = nil
    }
}
