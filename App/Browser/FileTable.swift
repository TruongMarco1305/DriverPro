//
//  FileTable.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// The directory listing.
struct FileTable<Menu: View>: View {

    @Bindable var browser: BrowserModel
    @ViewBuilder let contextMenu: () -> Menu

    var body: some View {
        Table(browser.visibleItems, selection: $browser.selection) {
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
        }
        .tableStyle(.inset)
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
