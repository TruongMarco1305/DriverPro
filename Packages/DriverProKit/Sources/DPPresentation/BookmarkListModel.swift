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

    /// Clears the current message.
    public func dismissError() {
        errorMessage = nil
    }
}
