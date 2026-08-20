//
//  BookmarkInterchange.swift
//  DriverPro
//

import DPBookmarks
import DPCore
import DPPresentation
import DPServices
import SwiftUI
import UniformTypeIdentifiers

/// Importing and exporting Cyberduck `.duck` bookmarks.
///
/// Held apart from the views that trigger it because three of them do — the File menu, the sidebar's
/// drop target, and the summary alert they share — and the panels and wording should not be written
/// three times.
@MainActor
struct BookmarkInterchange {

    let environment: AppEnvironment

    /// Asks for files, then imports them.
    ///
    /// - Returns: What happened, or `nil` if the panel was cancelled or the import failed.
    func chooseAndImport() async -> DuckImportSummary? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true          // Cyberduck keeps a folder of them
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose Cyberduck bookmarks (.duck) or a folder of them."
        if let type = UTType(filenameExtension: DuckFormat.fileExtension) {
            panel.allowedContentTypes = [type, .folder]
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return await importing(panel.urls)
    }

    /// Imports files handed over by a drop.
    ///
    /// - Parameter urls: What was dropped. Anything that is not a `.duck` file is ignored.
    /// - Returns: What happened, or `nil` if none of it was a bookmark file.
    func importing(dropped urls: [URL]) async -> DuckImportSummary? {
        let candidates = urls.filter {
            $0.pathExtension.lowercased() == DuckFormat.fileExtension || $0.hasDirectoryPath
        }
        guard !candidates.isEmpty else { return nil }
        return await importing(candidates)
    }

    /// Asks where to write, then exports every bookmark.
    ///
    /// - Returns: How many were written, or `nil` if cancelled or failed.
    func chooseAndExport() async -> Int? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder to write one .duck file per bookmark."

        guard panel.runModal() == .OK, let directory = panel.url else { return nil }
        return await environment.bookmarks?.exportDuck(to: directory)
    }

    /// Asks where to save one bookmark, then writes it.
    ///
    /// - Parameter host: The bookmark to export.
    /// - Returns: Whether it was written.
    @discardableResult
    func chooseAndExport(_ host: RemoteHost) async -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        // panel.message = "Save “\(host.displayName)” as a Cyberduck bookmark."
        // Pre-named the way Cyberduck names its own, so a folder of exports from either app matches.
        panel.nameFieldStringValue = DuckFormat.fileName(for: host)
        if let type = UTType(filenameExtension: DuckFormat.fileExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let file = panel.url else { return false }
        return await environment.bookmarks?.exportDuck(host, to: file) ?? false
    }

    private func importing(_ urls: [URL]) async -> DuckImportSummary? {
        // The catalog decides what counts as supported, so a protocol arriving before its milestone is
        // reported rather than left to fail on the first click.
        await environment.bookmarks?.importDuck(
            from: urls,
            supported: environment.services?.catalog.supportedIdentifiers ?? [.sftp]
        )
    }

    /// Plain language for what an import did.
    ///
    /// Names the protocols it skipped rather than counting them, because "3 skipped" leaves the user
    /// wondering where their bookmarks went.
    ///
    /// - Parameters:
    ///   - summary: What the import reported.
    ///   - catalog: Used to name protocols the way the rest of the app does.
    static func message(for summary: DuckImportSummary, catalog: ProtocolCatalog) -> String {
        guard !summary.isEmpty else { return "Those files held no bookmarks." }

        var parts = ["Imported \(summary.imported) bookmark\(summary.imported == 1 ? "" : "s")."]

        if !summary.unsupported.isEmpty {
            let names = summary.unsupported.keys
                .map { catalog.descriptor(for: $0)?.displayName ?? $0.rawValue.uppercased() }
                .sorted()
                .formatted(.list(type: .and))
            parts.append("\(summary.unsupportedCount) skipped — DriverPro does not support \(names) yet.")
        }
        if summary.unreadable > 0 {
            parts.append("\(summary.unreadable) file\(summary.unreadable == 1 ? " was" : "s were") not a bookmark.")
        }
        return parts.joined(separator: "\n\n")
    }
}
