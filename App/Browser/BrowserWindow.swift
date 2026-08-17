//
//  BrowserWindow.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPTransfer
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

    @Environment(\.openWindow) private var openWindow

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteItem?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteItem] = []

    /// Remembered across launches, so the choice is made once rather than every transfer.
    @AppStorage("overwritePolicy") private var storedPolicy = OverwritePolicy.resume.rawValue

    private var policy: OverwritePolicy {
        OverwritePolicy(rawValue: storedPolicy) ?? .resume
    }

    private var commands: FileCommands {
        FileCommands(browser: browser, transfers: transfers, policy: policy) {
            openWindow(id: "transfers")
        }
    }

    var body: some View {
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
                FileTable(browser: browser) {
                    FileCommandButtons(
                        commands: commands,
                        isCreatingFolder: $isCreatingFolder,
                        renameTarget: $renameTarget,
                        deleteTargets: $deleteTargets
                    )
                }
            }

            // Outside the branch: a transfer can still be finishing after a disconnect.
            if let transfers, let summary = transfers.activeSummary {
                Divider()
                TransferStatusBar(summary: summary) { openWindow(id: "transfers") }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                FileCommandButtons(
                    commands: commands,
                    isCreatingFolder: $isCreatingFolder,
                    renameTarget: $renameTarget,
                    deleteTargets: $deleteTargets
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
                    Label("Hidden Files", systemImage: "eye")
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

                Button {
                    Task { await browser.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .help("Close this connection")
                .disabled(browser.host == nil)
            }
        }
        .overlay(alignment: .top) {
            if browser.isLoading { ProgressView().controlSize(.small).padding(6) }
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
