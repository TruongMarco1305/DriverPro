//
//  DraggedRemoteFile.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI
import UniformTypeIdentifiers

/// A remote entry being dragged to Finder.
///
/// The file does not exist locally yet, so the drag has to fetch it before anything can receive it —
/// see ``TemporaryCopy``, which the preview panel uses too.
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
            let url = try await TemporaryCopy.fetch(dragged.path, named: dragged.name, purpose: .drag)
            // The temp copy is ours and nothing else will read it, so Finder may take it in place
            // rather than making a third copy.
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }
}
