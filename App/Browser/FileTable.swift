//
//  FileTable.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// The directory listing.
///
/// Written with an explicit `ForEach` of `TableRow` rather than the shorter `Table(data)` form, because
/// only rows built that way can be drag sources and drop targets — dropping onto a *folder* has to mean
/// something different from dropping onto the listing.
struct FileTable<Menu: View>: View {

    @Bindable var browser: BrowserModel
    /// Starts an upload of dropped files into a directory. `nil` means the one being shown.
    let upload: ([URL], RemoteItem?) -> Void
    @ViewBuilder let contextMenu: () -> Menu

    var body: some View {
        Table(of: RemoteItem.self, selection: $browser.selection) {
            TableColumn("Name") { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(systemName: icon(for: item))
                        .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Size") { item in
                // Blank, not "0 bytes", when the server did not report a size. Inventing a number
                // would look like data.
                Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)

            TableColumn("Date Modified") { item in
                Text(item.modifiedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(160)

            TableColumn("Permissions") { item in
                Text(item.permissions?.symbolicString ?? "—")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            .width(110)
        } rows: {
            ForEach(browser.visibleItems) { item in
                // Only a folder is a drop target, so only a folder highlights during a drag. A file row
                // accepting the drop and quietly uploading into its parent is not where anyone aimed.
                if item.isDirectory {
                    TableRow(item)
                        .draggable(DraggedRemoteFile(item))
                        .dropDestination(for: URL.self) { urls in
                            guard !urls.isEmpty else { return }
                            upload(urls, item)
                        }
                } else {
                    TableRow(item)
                        .draggable(DraggedRemoteFile(item))
                }
            }
        }
        .tableStyle(.inset)
        // Dropping on the listing itself sends files to the directory being shown. Rows get their own
        // target below, and theirs wins when the pointer is over one.
        .dropDestination(for: URL.self) { urls, _ in
            guard browser.host != nil, !urls.isEmpty else { return false }
            upload(urls, nil)
            return true
        }
        // `primaryAction` is the row's double-click, and it covers the whole row rather than only the
        // text a tap gesture would sit on. The menu ignores the ids it is handed and reads the
        // selection, which is what the toolbar's copy of these buttons acts on too.
        .contextMenu(forSelectionType: RemotePath.self) { _ in
            contextMenu()
        } primaryAction: { ids in
            Task { await browser.open(ids) }
        }
    }

    private func icon(for item: RemoteItem) -> String {
        switch item.kind {
        case .directory: "folder.fill"
        case .symbolicLink: "arrowshape.turn.up.right"
        case .file: "doc"
        }
    }
}
