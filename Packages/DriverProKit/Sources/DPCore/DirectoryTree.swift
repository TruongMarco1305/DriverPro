//
//  DirectoryTree.swift
//  DPCore
//
//  Recursive operations built on the core `Session` protocol: walking a subtree, and deleting one.
//

import Foundation

extension Session {

    /// Deletes an entry and everything beneath it.
    ///
    /// Uses the server's own recursive delete when it has one. SFTP does not — `remove` and `rmdir` are
    /// separate with no tree form — so for those backends this walks the tree depth-first instead.
    ///
    /// Symbolic links are removed, never followed: deleting a link that points at your home directory
    /// should delete the link.
    ///
    /// - Parameter path: The entry to remove.
    /// - Throws: ``SessionError/notFound(_:)`` if nothing is there, or whatever the backend reports for a
    ///   child it cannot delete.
    public func deleteTree(_ path: RemotePath) async throws {
        if capabilities.contains(.recursiveDelete) {
            try await delete(path)
            return
        }
        try await deleteTree(try await stat(path))
    }

    /// Depth-first removal, using the kind already reported by the parent's listing.
    private func deleteTree(_ item: RemoteItem) async throws {
        if item.isDirectory {
            for child in try await list(item.path) {
                try Task.checkCancellation()
                try await deleteTree(child)
            }
        }
        try await delete(item.path)
    }

    /// Every file beneath a directory, depth-first, with directories listed before their contents.
    ///
    /// That order is what callers need: a download creates each directory before writing files into it.
    /// Directories are included in the result so an empty one still gets created locally.
    ///
    /// - Parameter root: Where to start. May be a file, in which case the result is just that file.
    /// - Returns: The subtree, parents before children.
    /// - Throws: Whatever the backend reports while listing.
    public func walk(_ root: RemotePath) async throws -> [RemoteItem] {
        let item = try await stat(root)
        guard item.isDirectory else { return [item] }

        var found = [item]
        var pending = [item.path]

        // Iterative rather than recursive: a deep tree would otherwise nest one async frame per level.
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            for child in try await list(directory).sorted(by: { $0.path < $1.path }) {
                found.append(child)
                if child.isDirectory { pending.append(child.path) }
            }
        }
        return found
    }
}
