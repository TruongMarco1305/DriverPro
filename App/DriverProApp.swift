//
//  DriverProApp.swift
//  DriverPro
//
//  The app target. Views only: everything it shows comes from DPPresentation, and everything it does
//  goes through DPServices. No protocol target is imported here.
//

import DPBookmarks
import DPCore
import DPPresentation
import DPServices
import SwiftUI

@main
struct DriverProApp: App {

    /// The whole application, built once.
    @State private var environment = AppEnvironment()

    private var interchange: BookmarkInterchange {
        BookmarkInterchange(environment: environment)
    }

    /// Closes connections before the process exits.
    @NSApplicationDelegateAdaptor(TerminationDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("DriverPro") {
            BrowserWindow()
                .environment(environment)
                .frame(minWidth: 860, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Connection…") { environment.connectionSheet = .create }
                    .keyboardShortcut("k")

                Divider()

                Button("Import Bookmarks…") {
                    Task { environment.importSummary = await interchange.chooseAndImport() }
                }
                Button("Export Bookmarks…") {
                    Task { _ = await interchange.chooseAndExport() }
                }
                .disabled(environment.bookmarks?.bookmarks.isEmpty ?? true)
            }
        }
    }
}

/// Everything the app owns, assembled at launch.
///
/// This is the composition root's other half: `DriverProServices.live` builds the engine, and the
/// models here hold the state the views draw. Building it can fail — the database lives on disk — so
/// the failure is captured and shown rather than crashing on launch.
@MainActor
@Observable
final class AppEnvironment {

    /// Answers the engine's questions by putting sheets on screen.
    let prompt = PromptCoordinator()

    private(set) var services: DriverProServices?
    private(set) var browser: BrowserModel?
    private(set) var bookmarks: BookmarkListModel?
    private(set) var transfers: TransferListModel?

    /// Why the app could not start, if it could not.
    private(set) var startupError: String?

    /// The connection sheet that is up, or `nil` when none is.
    var connectionSheet: ConnectionSheetMode?

    /// What the last `.duck` import did, until the alert reporting it is dismissed.
    ///
    /// On the environment rather than in a view because two places start an import — the File menu and
    /// the sidebar's drop target — and both report it through the same alert.
    var importSummary: DuckImportSummary?

    init() {
        do {
            let services = try DriverProServices.live(prompt: prompt)
            self.services = services
            self.browser = BrowserModel(services: services)
            self.bookmarks = BookmarkListModel(store: services.bookmarks)
            self.transfers = TransferListModel(services: services)
            TerminationDelegate.shared = self
            // `Transferable`'s exporting closure is static, with nowhere to pass context through.
            TemporaryCopy.environment = self
        } catch {
            startupError = "DriverPro could not open its database.\n\n\(error.localizedDescription)"
        }
    }
}

/// What the connection sheet is for.
///
/// One sheet serves both jobs — the fields are the same, and only the identity, the primary button and
/// whether the protocol chooser appears differ.
enum ConnectionSheetMode: Identifiable {
    /// Describe a new connection, starting from the protocol chooser.
    case create
    /// Change a saved bookmark, keeping its identity.
    case edit(RemoteHost)

    /// Identity for `sheet(item:)`. Editing is keyed by the bookmark, so switching bookmarks re-presents.
    var id: String {
        switch self {
        case .create: "create"
        case .edit(let host): host.id.uuidString
        }
    }
}

/// Closes pooled connections before the app exits.
///
/// ## Swift note — async cleanup at quit
/// `applicationShouldTerminate` is synchronous, so returning `.terminateNow` lets the process die
/// immediately — which is what happened before this existed, leaving SSH sockets open until the kernel
/// tore them down.
///
/// `.terminateLater` asks AppKit to wait. The work then happens in a `Task`, and
/// `reply(toApplicationShouldTerminate:)` releases the app afterwards. The reply is in a `defer` so a
/// failed disconnect cannot leave the app unable to quit — a hang at shutdown is far worse than a
/// lingering socket.
@MainActor
final class TerminationDelegate: NSObject, NSApplicationDelegate {

    /// The environment to shut down. Set once the app has built one.
    static weak var shared: AppEnvironment?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services = Self.shared?.services else { return .terminateNow }

        Task {
            defer { NSApp.reply(toApplicationShouldTerminate: true) }
            await services.disconnectAll()
            // A cancelled drag or a closed preview leaves its download behind; nothing else clears it.
            TemporaryCopy.clearAll()
        }
        return .terminateLater
    }
}
