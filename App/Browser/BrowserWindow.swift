//
//  BrowserWindow.swift
//  DriverPro
//

import DPCore
import DPPresentation
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
        .sheet(isPresented: $environment.isShowingConnectionSheet) {
            ConnectionSheet()
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

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteItem?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteItem] = []

    private var commands: FileCommands {
        FileCommands(browser: browser, transfers: transfers)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                .disabled(!browser.canGoUp || browser.host == nil)

                Button {
                    Task { await browser.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(browser.host == nil)

                Toggle(isOn: $browser.showsHiddenFiles) {
                    Label("Hidden Files", systemImage: "eye")
                }
                .disabled(browser.host == nil)

                sortMenu

                Button {
                    Task { await browser.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .disabled(browser.host == nil)
            }
        }
        .overlay {
            if browser.host == nil {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "externaldrive.badge.wifi",
                    description: Text("Choose a bookmark, or press ⌘K to open a connection.")
                )
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
        .disabled(browser.host == nil)
    }
}
