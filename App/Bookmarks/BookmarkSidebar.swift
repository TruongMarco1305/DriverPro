//
//  BookmarkSidebar.swift
//  DriverPro
//

import DPBookmarks
import DPCore
import DPPresentation
import DPServices
import SwiftUI

/// Saved connections. Selecting one connects to it.
struct BookmarkSidebar: View {

    @Environment(AppEnvironment.self) private var environment

    /// Which row the pointer is over. A `List` of plain buttons gives no feedback of its own.
    @State private var hovered: RemoteHost.ID?

    /// Whether a `.duck` file is hovering over the list.
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var environment = environment

        Group {
            if let bookmarks = environment.bookmarks {
                List {
                    ForEach(bookmarks.bookmarks) { host in
                        row(for: host, in: bookmarks)
                    }
                }
                .task { await bookmarks.reload() }
                .overlay {
                    if bookmarks.bookmarks.isEmpty {
                        ContentUnavailableView(
                            "No Bookmarks",
                            systemImage: "bookmark",
                            description: Text("Press ⌘K to connect to a server.")
                        )
                    }
                }
            } else {
                List {}
            }
        }
        // Clipped on the container, not the rows, so the list scrolls under a rounded edge rather than
        // each row being rounded.
        .clipShape(.rect(topLeadingRadius: 10, topTrailingRadius: 10))
        // Dropping a `.duck` file here imports it — Cyberduck's own gesture, and the reason someone
        // arriving with a folder of bookmarks does not have to find a menu first.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await importDropped(urls) }
            return true
        } isTargeted: {
            isDropTarget = $0
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .modifier(BookmarkImportAlert(summary: $environment.importSummary, catalog: catalog))
        .toolbar {
            Button {
                environment.connectionSheet = .create
            } label: {
                Label("New Connection", systemImage: "plus")
            }
            .help("Connect to a server (⌘K)")
        }
    }

    private var catalog: ProtocolCatalog {
        environment.services?.catalog ?? .live
    }

    private func importDropped(_ urls: [URL]) async {
        environment.importSummary = await BookmarkInterchange(environment: environment)
            .importing(dropped: urls)
    }

    private func row(for host: RemoteHost, in bookmarks: BookmarkListModel) -> some View {
        // The connection being browsed, marked the way a selected row looks anywhere in macOS. Derived
        // rather than stored: `BrowserModel` already knows, and disconnecting clears it for free.
        let isConnected = environment.browser?.host?.id == host.id

        return Button {
            Task { await environment.browser?.connect(to: host) }
        } label: {
            HStack(spacing: 10) {
                // Fixed width so names line up however wide the symbol draws.
                Image(systemName: icon(for: host))
                    .font(.title3)
                    .foregroundStyle(isConnected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(host.displayName).lineLimit(1)
                    // The user name, never the address: a sidebar should not double as a list of the
                    // servers this machine can reach. `subtitle` is nil when it would only repeat the
                    // title.
                    if let subtitle = host.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isConnected ? .white.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isConnected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(.rect)      // the gaps are clickable too, not just the text
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(background(isConnected: isConnected, isHovered: hovered == host.id))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? host.id : (hovered == host.id ? nil : hovered) }
        .help(host.comment ?? "Connect to \(host.displayName)")
        .contextMenu {
            Button("Edit Bookmark…") { environment.connectionSheet = .edit(host) }

            // One file, shareable. No secret goes with it — a `.duck` holds the address and the
            // Keychain coordinates, never the password.
            Button("Export Bookmark…") {
                Task { await BookmarkInterchange(environment: environment).chooseAndExport(host) }
            }

            Divider()

            // Deleting a bookmark leaves its Keychain item alone: the two have separate lifetimes,
            // and silently removing a password would be surprising.
            Button("Delete Bookmark", role: .destructive) {
                Task { await bookmarks.delete(host.id) }
            }
        }
    }

    /// Selection wins over hover, so pointing at the open connection does not lighten it.
    private func background(isConnected: Bool, isHovered: Bool) -> Color {
        if isConnected { return .accentColor }
        return isHovered ? Color.primary.opacity(0.08) : .clear
    }

    /// The symbol for a bookmark's protocol, from the catalog rather than a `switch` here.
    private func icon(for host: RemoteHost) -> String {
        ProtocolCatalog.live.descriptor(for: host.protocolIdentifier)?.iconName ?? "server.rack"
    }
}

/// Reports what an import did, wherever it was started from.
///
/// A `ViewModifier` because the sidebar shows it for a drop and the File menu shows it for a picker,
/// and one wording is better than two.
struct BookmarkImportAlert: ViewModifier {

    @Binding var summary: DuckImportSummary?
    let catalog: ProtocolCatalog

    func body(content: Content) -> some View {
        content.alert(
            "Bookmarks imported",
            isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })
        ) {
            Button("OK") { summary = nil }
        } message: {
            Text(summary.map { BookmarkInterchange.message(for: $0, catalog: catalog) } ?? "")
        }
    }
}
