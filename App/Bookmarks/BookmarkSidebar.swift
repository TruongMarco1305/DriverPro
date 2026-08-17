//
//  BookmarkSidebar.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// Saved connections. Selecting one connects to it.
struct BookmarkSidebar: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        Group {
            if let bookmarks = environment.bookmarks {
                List {
                    Section("Bookmarks") {
                        ForEach(bookmarks.bookmarks) { host in
                            row(for: host, in: bookmarks)
                        }
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
        .toolbar {
            Button {
                environment.isShowingConnectionSheet = true
            } label: {
                Label("New Connection", systemImage: "plus")
            }
        }
    }

    private func row(for host: RemoteHost, in bookmarks: BookmarkListModel) -> some View {
        Button {
            Task { await environment.browser?.connect(to: host) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                Text("\(host.protocolIdentifier.rawValue)://\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Deleting a bookmark leaves its Keychain item alone: the two have separate lifetimes,
            // and silently removing a password would be surprising.
            Button("Delete Bookmark", role: .destructive) {
                Task { await bookmarks.delete(host.id) }
            }
        }
    }
}
