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

        start(transfer, title: title(for: items))
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
        start(transfer, title: name)
    }

    /// Queues a transfer.
    ///
    /// Nothing is opened or brought forward: the toolbar's badge is how a transfer announces itself
    /// now, which is a change the user can see without a window taking focus mid-browse.
    private func start(_ transfer: Transfer, title: String) {
        Task { await transfers?.start(transfer, title: title) }
    }

    /// Starts an upload of files dropped from Finder.
    ///
    /// - Parameters:
    ///   - urls: What was dropped.
    ///   - item: The folder row it landed on, or `nil` for the directory being shown.
    func upload(dropped urls: [URL], onto item: RemoteItem?) {
        let transfer = item.map { browser.makeUpload(of: urls, onto: $0, policy: policy) }
            ?? browser.makeUpload(of: urls, policy: policy)
        guard let transfer else { return }

        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        start(transfer, title: name)
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
        Button("Download", systemImage: "square.and.arrow.down") { commands.download() }
            .help("Download the selected items")
            .disabled(!commands.hasSelection)

        Button("Upload…", systemImage: "square.and.arrow.up") { commands.upload() }
            .help("Upload files into this folder")

        Divider()

        Button("New Folder", systemImage: "folder.badge.plus") { isCreatingFolder = true }
            .help("Create a folder here")

        Button("Rename…", systemImage: "pencil") {
            renameTarget = commands.browser.selectedItems.first
        }
        .help("Rename the selected item")
        // Greyed out rather than offered and failing: S3 has no rename at all.
        .disabled(!commands.browser.canRename || commands.browser.selectedItems.count != 1)

        Button("Delete…", systemImage: "trash", role: .destructive) {
            deleteTargets = commands.browser.selectedItems
        }
        .help("Delete the selected items")
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
