//
//  FileCommands.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPTransfer
import SwiftUI

/// The file operations: download, upload, new folder, rename, delete.
///
/// Held in one place so the toolbar and the context menu offer exactly the same things, enabled under
/// exactly the same conditions.
@MainActor
struct FileCommands {

    let browser: BrowserModel
    let transfers: TransferListModel?
    /// What to do about files that already exist. Chosen by the user, read when a job is built.
    let policy: OverwritePolicy

    /// Whether anything is selected to act on.
    var hasSelection: Bool { !browser.selectedItems.isEmpty }

    // MARK: - Transfers

    /// Asks where to save, then starts a download of the selection.
    func download() {
        let items = browser.selectedItems
        guard !items.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Choose where to save \(items.count) item(s). Existing files: \(Self.label(for: policy))."

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard let transfer = browser.makeDownload(of: items, to: destination, policy: policy) else { return }

        Task { await transfers?.start(transfer, title: title(for: items)) }
    }

    /// Asks what to send, then starts an upload into the directory being shown.
    func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        // Naming the destination in the panel is what stops files landing in the wrong directory.
        panel.message = "Choose what to upload to \(browser.path.pathString)."

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard let transfer = browser.makeUpload(of: panel.urls, policy: policy) else { return }

        let name = panel.urls.count == 1
            ? panel.urls[0].lastPathComponent
            : "\(panel.urls.count) items"
        Task { await transfers?.start(transfer, title: name) }
    }

    /// Plain language for a policy, for menus and panel text.
    static func label(for policy: OverwritePolicy) -> String {
        switch policy {
        case .resume: "resume or replace"
        case .skip: "skip"
        case .rename: "keep both"
        case .overwrite: "always replace"
        }
    }

    private func title(for items: [RemoteItem]) -> String {
        items.count == 1 ? items[0].name : "\(items.count) items"
    }
}

/// The buttons and menu items, shared by the toolbar and the context menu.
struct FileCommandButtons: View {

    let commands: FileCommands
    @Binding var isCreatingFolder: Bool
    @Binding var renameTarget: RemoteItem?
    @Binding var deleteTargets: [RemoteItem]

    var body: some View {
        Button("Download", systemImage: "arrow.down") { commands.download() }
            .disabled(!commands.hasSelection)

        Button("Upload…", systemImage: "arrow.up") { commands.upload() }

        Divider()

        Button("New Folder", systemImage: "folder.badge.plus") { isCreatingFolder = true }

        Button("Rename…", systemImage: "pencil") {
            renameTarget = commands.browser.selectedItems.first
        }
        // Greyed out rather than offered and failing: S3 has no rename at all.
        .disabled(!commands.browser.canRename || commands.browser.selectedItems.count != 1)

        Button("Delete…", systemImage: "trash", role: .destructive) {
            deleteTargets = commands.browser.selectedItems
        }
        .disabled(!commands.hasSelection)
    }
}

/// Chooses what happens to files that already exist.
///
/// Until this existed every transfer used `.overwrite` silently, so downloading a file you already had
/// destroyed the local copy without asking. The default is now `.resume`, which continues a partial
/// file and leaves a complete one alone.
struct OverwritePolicyPicker: View {

    @Binding var policy: OverwritePolicy

    var body: some View {
        Picker("If a file already exists", selection: $policy) {
            Text("Resume or replace").tag(OverwritePolicy.resume)
            Text("Skip existing").tag(OverwritePolicy.skip)
            Text("Keep both").tag(OverwritePolicy.rename)
            Text("Always replace").tag(OverwritePolicy.overwrite)
        }
    }
}
