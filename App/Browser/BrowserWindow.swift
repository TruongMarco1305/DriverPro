//
//  BrowserWindow.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPTransfer
import QuickLook
import SwiftUI

/// The main window: bookmarks on the left, the current directory on the right.
struct BrowserWindow: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        NavigationSplitView {
            BookmarkSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let browser = environment.browser {
                BrowserDetail(browser: browser, transfers: environment.transfers)
            } else {
                ContentUnavailableView(
                    "DriverPro could not start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(environment.startupError ?? "Unknown error.")
                )
            }
        }
        // Transfers left unfinished by the last quit reappear here as rows waiting to be resumed. On
        // the main window rather than the transfers window, which may never be opened.
        .task {
            await environment.transfers?.restore()
        }
        .sheet(item: $environment.connectionSheet) { mode in
            ConnectionSheet(mode: mode)
        }
        // One sheet driven by whatever the engine is currently asking. Setting it to nil means the
        // user dismissed without choosing, which the coordinator treats as a refusal.
        .sheet(item: Binding(
            get: { environment.prompt.pending },
            set: { if $0 == nil { environment.prompt.dismiss() } }
        )) { question in
            switch question {
            case .hostKey(let challenge, let host):
                HostKeySheet(challenge: challenge, host: host)
            case .certificate(let challenge, let host):
                CertificateSheet(challenge: challenge, host: host)
            case .credentials(let request):
                CredentialSheet(request: request)
            }
        }
    }
}

/// The right-hand side: path bar, listing, and the toolbar that drives them.
private struct BrowserDetail: View {

    @Bindable var browser: BrowserModel
    let transfers: TransferListModel?

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteItem?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteItem] = []

    /// The local copy Quick Look is showing. Setting it opens the panel; clearing it closes.
    @State private var previewURL: URL?
    /// The file that was too big to preview, and its size.
    @State private var oversizePreview: OversizePreview?
    /// Whether a preview copy is being fetched. The only sign that one is: it has no transfers row.
    @State private var isFetchingPreview = false

    /// Remembered across launches, so the choice is made once rather than every transfer.
    @AppStorage("overwritePolicy") private var storedPolicy = OverwritePolicy.resume.rawValue

    private var policy: OverwritePolicy {
        OverwritePolicy(rawValue: storedPolicy) ?? .resume
    }

    private var commands: FileCommands {
        FileCommands(browser: browser, transfers: transfers, policy: policy)
    }

    var body: some View {
        listing
            .quickLookPreview($previewURL)
            .toolbar { toolbarItems }
            .modifier(BrowserDialogs(
                browser: browser,
                commands: commands,
                isCreatingFolder: $isCreatingFolder,
                newFolderName: $newFolderName,
                renameTarget: $renameTarget,
                renameText: $renameText,
                deleteTargets: $deleteTargets,
                oversizePreview: $oversizePreview,
                isFetchingPreview: isFetchingPreview
            ))
    }

    /// The path bar and the listing, or the placeholder when there is no connection.
    private var listing: some View {
        VStack(spacing: 0) {
            // Not merely covered: an empty table with a "/" path bar behind the placeholder suggests a
            // connection that has nothing in it, which is a different thing from no connection.
            if browser.host == nil {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "externaldrive.badge.wifi",
                    description: Text("Choose a bookmark, or press ⌘K to open a connection.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PathBar(browser: browser)
                Divider()
                FileTable(browser: browser) { urls, item in
                    commands.upload(dropped: urls, onto: item)
                } contextMenu: {
                    FileCommandButtons(
                        commands: commands,
                        isCreatingFolder: $isCreatingFolder,
                        renameTarget: $renameTarget,
                        deleteTargets: $deleteTargets,
                        preview: startPreview
                    )
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {

            ToolbarItemGroup {
                FileCommandButtons(
                    commands: commands,
                    isCreatingFolder: $isCreatingFolder,
                    renameTarget: $renameTarget,
                    deleteTargets: $deleteTargets,
                    preview: startPreview
                )
                .labelStyle(.iconOnly)
                .disabled(browser.host == nil)

                Divider()

                Button {
                    Task { await browser.goUp() }
                } label: {
                    Label("Enclosing Folder", systemImage: "chevron.up")
                }
                .help("Go to the enclosing folder")
                .disabled(!browser.canGoUp || browser.host == nil)

                Button {
                    Task { await browser.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload this folder from the server")
                .disabled(browser.host == nil)

                Toggle(isOn: $browser.showsHiddenFiles) {
                    Label("Hidden Files", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help(browser.showsHiddenFiles ? "Hide dotfiles" : "Show hidden files")
                .disabled(browser.host == nil)

                sortMenu

                Menu {
                    OverwritePolicyPicker(policy: Binding(
                        get: { policy },
                        set: { storedPolicy = $0.rawValue }
                    ))
                } label: {
                    Label("Existing Files", systemImage: "doc.on.doc")
                }
                .help("Choose what happens to files that already exist")
                .disabled(browser.host == nil)

                // Before Disconnect rather than last, which is a layout decision and not a taste one:
                // its popover is anchored to this button and pinned to the screen's right edge, so as
                // the final item the arrow lands on the panel's top-right corner and AppKit squares
                // that corner off. A slot further in gives the arrow the clearance it needs. Moving the
                // popover's own anchor would be the direct fix and does not work — `swift-notes.md` §36.
                if let transfers {
                    TransfersButton(transfers: transfers)
                }

                Button {
                    Task { await browser.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .help("Close this connection")
                .disabled(browser.host == nil)
            }
    }

    /// Previews the first selected file, fetching it first.
    ///
    /// The fetch is invisible to the transfers panel, so the spinner here is the only sign that a
    /// preview of a large file is on its way, and the alert the only sign that one failed.
    private func startPreview() {
        Task {
            isFetchingPreview = true
            defer { isFetchingPreview = false }

            switch await commands.preview() {
            case .ready(let url): previewURL = url
            case .tooLarge(let name, let size):
                oversizePreview = OversizePreview(name: name, size: size)
            case .failed(let message): browser.report(message)
            case .nothing: break
            }
        }
    }

    /// Sorting lives in a menu rather than in clickable headers.
    ///
    /// SwiftUI's `Table` sorts through `KeyPathComparator`, which cannot express "directories first" or
    /// order optional sizes sensibly — both of which `BrowserModel` already handles. Rather than split
    /// the ordering rules across two places, the model stays authoritative. Native header sorting is
    /// worth revisiting once the comparator can be driven from the model.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $browser.sortColumn) {
                Text("Name").tag(BrowserModel.SortColumn.name)
                Text("Size").tag(BrowserModel.SortColumn.size)
                Text("Date Modified").tag(BrowserModel.SortColumn.modified)
                Text("Permissions").tag(BrowserModel.SortColumn.permissions)
            }
            Divider()
            Picker("Order", selection: $browser.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Choose how the listing is ordered")
        .disabled(browser.host == nil)
    }
}

/// Every alert and confirmation the browser puts up.
///
/// A `ViewModifier` rather than more modifiers on `BrowserDetail.body`: five dialogs in one expression
/// is past what the type-checker will accept, and it reads better as one thing anyway.
private struct BrowserDialogs: ViewModifier {

    let browser: BrowserModel
    let commands: FileCommands

    @Binding var isCreatingFolder: Bool
    @Binding var newFolderName: String
    @Binding var renameTarget: RemoteItem?
    @Binding var renameText: String
    @Binding var deleteTargets: [RemoteItem]
    @Binding var oversizePreview: OversizePreview?
    /// Whether a Quick Look copy is on its way, which the same spinner reports.
    let isFetchingPreview: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
            if browser.isLoading || isFetchingPreview {
                ProgressView().controlSize(.small).padding(6)
            }
        }
            .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await browser.createDirectory(named: name) }
            }
        }
            .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    let name = renameText
                    Task { await browser.rename(target, to: name) }
                }
                renameTarget = nil
            }
        }
            .onChange(of: renameTarget?.id) { renameText = renameTarget?.name ?? "" }
            .confirmationDialog(
            deleteMessage,
            isPresented: Binding(
                get: { !deleteTargets.isEmpty },
                set: { if !$0 { deleteTargets = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let targets = deleteTargets
                deleteTargets = []
                Task { await browser.delete(targets) }
            }
            Button("Cancel", role: .cancel) { deleteTargets = [] }
        } message: {
            Text("This cannot be undone.")
        }
            .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { browser.errorMessage != nil },
                set: { if !$0 { browser.dismissError() } }
            )
        ) {
            Button("OK") { browser.dismissError() }
        } message: {
            Text(browser.errorMessage ?? "")
        }
            .alert(
                "Too large to preview",
                isPresented: Binding(
                    get: { oversizePreview != nil },
                    set: { if !$0 { oversizePreview = nil } }
                )
            ) {
                Button("Download…") {
                    oversizePreview = nil
                    commands.download()
                }
                Button("Cancel", role: .cancel) { oversizePreview = nil }
            } message: {
                Text(oversizeMessage)
            }
    }

    /// Names the file and both sizes, so the refusal is a fact rather than a rule.
    private var oversizeMessage: String {
        guard let oversizePreview else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: oversizePreview.size, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: BrowserModel.previewSizeLimit,
                                              countStyle: .file)
        return "“\(oversizePreview.name)” is \(size). Files over \(limit) are too large to preview."
    }

    /// Names exactly what will be removed, so a destructive confirmation is not a blank cheque.
    private var deleteMessage: String {
        if deleteTargets.count == 1 {
            let item = deleteTargets[0]
            return item.isDirectory
                ? "Delete “\(item.name)” and everything inside it?"
                : "Delete “\(item.name)”?"
        }
        return "Delete \(deleteTargets.count) items?"
    }
}

/// A file that could not be previewed, and why the message can say so.
struct OversizePreview: Equatable {
    /// What it is called.
    let name: String
    /// How big it turned out to be.
    let size: Int64
}
