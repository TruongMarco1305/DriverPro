//
//  BrowserModel.swift
//  DPPresentation
//

import DPCore
import DPServices
import Foundation
import Observation

/// What the file table is showing, and everything it takes to decide that.
///
/// Sorting, hidden-file filtering, navigation, and turning a `SessionError` into a sentence are all
/// ordinary logic. Keeping them here rather than in a view is what lets `swift test` cover them.
@MainActor
@Observable
public final class BrowserModel {

    /// A column the listing can be ordered by.
    public enum SortColumn: String, CaseIterable, Sendable {
        case name, size, modified, permissions
    }

    /// Internal rather than private so `FileOperations.swift` can reach it.
    let services: DriverProServices

    /// The connection being browsed, once one is open.
    public private(set) var host: RemoteHost?
    /// The directory currently shown.
    public private(set) var path: RemotePath = .root
    /// Everything the server reported, before filtering or sorting.
    public private(set) var entries: [RemoteItem] = []

    /// What the connected backend can do. Empty until connected.
    ///
    /// Read by the UI to decide which commands to offer at all, rather than offering them and failing
    /// after the click.
    public internal(set) var capabilities: SessionCapabilities = []

    /// Whether a listing is in flight.
    public private(set) var isLoading = false
    /// A message to show the user, or `nil`.
    public internal(set) var errorMessage: String?

    /// Whether dotfiles are shown.
    public var showsHiddenFiles = false
    /// Which column orders the listing.
    public var sortColumn: SortColumn = .name
    /// Whether that order is ascending.
    public var sortAscending = true
    /// Rows the user has selected.
    public var selection: Set<RemotePath> = []

    /// Creates a browser over an assembled engine.
    /// - Parameter services: The wired engine.
    public init(services: DriverProServices) {
        self.services = services
    }

    // MARK: - Presentation

    /// The rows to draw: filtered, then sorted, directories first.
    ///
    /// Directories lead regardless of column, which is what every file browser does and what makes
    /// navigating by keyboard bearable.
    public var visibleItems: [RemoteItem] {
        let filtered = showsHiddenFiles ? entries : entries.filter { !$0.isHidden }

        return filtered.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return sortAscending ? isBefore(left, right) : isBefore(right, left)
        }
    }

    private func isBefore(_ left: RemoteItem, _ right: RemoteItem) -> Bool {
        switch sortColumn {
        case .name:
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        case .size:
            // Unsized entries sort together at the start rather than pretending to be zero bytes.
            return (left.size ?? -1) < (right.size ?? -1)
        case .modified:
            return (left.modifiedAt ?? .distantPast) < (right.modifiedAt ?? .distantPast)
        case .permissions:
            return (left.permissions?.rawValue ?? 0) < (right.permissions?.rawValue ?? 0)
        }
    }

    /// Every directory from the root to here, for the path bar.
    public var breadcrumb: [RemotePath] { path.ancestorsAndSelf }

    /// What the path bar should call a crumb.
    ///
    /// The root reads as the connection's name rather than `/`, so the trail says which server you are
    /// on as well as where you are inside it. Naming, not layout, so it lives here and is tested.
    ///
    /// - Parameter path: The crumb.
    public func breadcrumbLabel(for path: RemotePath) -> String {
        guard path.isRoot else { return path.name }
        return host?.displayName ?? "/"
    }

    /// Whether there is a parent to go up to.
    public var canGoUp: Bool { !path.isRoot }

    // MARK: - Navigating

    /// Connects and shows the starting directory.
    ///
    /// - Parameter host: The bookmark to open.
    public func connect(to host: RemoteHost) async {
        self.host = host
        isLoading = true
        errorMessage = nil

        do {
            try await services.connect(to: host)
            let (start, supported) = try await services.withSession(for: host) { session in
                (try await session.defaultDirectory(), session.capabilities)
            }
            capabilities = supported
            isLoading = false
            await navigate(to: start)
        } catch {
            isLoading = false
            self.host = nil
            errorMessage = Self.message(for: error)
        }
    }

    /// Lists a directory and shows it.
    ///
    /// A failure leaves the previous listing on screen. Blanking the table because one listing failed
    /// loses the user's place for no reason — the message says what happened.
    ///
    /// - Parameter destination: Where to go.
    public func navigate(to destination: RemotePath) async {
        guard let host else { return }
        isLoading = true
        errorMessage = nil

        do {
            let listed = try await services.withSession(for: host) { session in
                try await session.list(destination)
            }
            path = destination
            entries = listed
            selection = []
        } catch {
            errorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    /// Descends into a directory. Files are ignored — opening one is a transfer, which is 2b.
    /// - Parameter item: The row that was activated.
    public func open(_ item: RemoteItem) async {
        guard item.isDirectory else { return }
        await navigate(to: item.path)
    }

    /// Opens rows the table reports as activated, by their ids.
    ///
    /// The table's double-click hands back a selection rather than a row, so resolving it is decided
    /// here: exactly one directory opens, and anything else — a file, several rows, a stale id — does
    /// nothing rather than guessing which one was meant.
    ///
    /// - Parameter ids: Paths of the activated rows.
    public func open(_ ids: Set<RemotePath>) async {
        guard ids.count == 1, let id = ids.first,
              let item = entries.first(where: { $0.path == id }) else { return }
        await open(item)
    }

    /// Goes to the parent directory.
    public func goUp() async {
        guard let parent = path.parent else { return }
        await navigate(to: parent)
    }

    /// Re-lists the current directory.
    public func refresh() async {
        await navigate(to: path)
    }

    /// Closes the connection and clears the listing.
    public func disconnect() async {
        await services.disconnectAll()
        host = nil
        capabilities = []
        entries = []
        selection = []
        path = .root
    }

    /// Shows a message in the browser's error alert.
    ///
    /// For work the app does on the browser's behalf that has nowhere of its own to fail: a Quick Look
    /// copy has no row in the transfers panel, so a refused download would otherwise be silent.
    ///
    /// - Parameter message: What to tell the user.
    public func report(_ message: String) {
        errorMessage = message
    }

    /// Clears the current message.
    public func dismissError() {
        errorMessage = nil
    }

    // MARK: - Errors

    /// Turns an error into something worth showing a person.
    ///
    /// `SessionError` already carries user-facing text and a recovery suggestion, so this mostly joins
    /// them. Cancellation produces nothing: the user did that on purpose and does not need telling.
    static func message(for error: any Error) -> String? {
        if let sessionError = error as? SessionError {
            if case .cancelled = sessionError { return nil }
            let description = sessionError.errorDescription ?? "Something went wrong."
            if let suggestion = sessionError.recoverySuggestion {
                return "\(description)\n\n\(suggestion)"
            }
            return description
        }
        return error.localizedDescription
    }
}
