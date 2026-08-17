//
//  DriverProApp.swift
//  DriverPro
//
//  The app target. Views only: everything it shows comes from DPPresentation, and everything it does
//  goes through DPServices. No protocol target is imported here.
//

import DPPresentation
import DPServices
import SwiftUI

@main
struct DriverProApp: App {

    /// The whole application, built once.
    @State private var environment = AppEnvironment()

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
                Button("Open Connection…") { environment.isShowingConnectionSheet = true }
                    .keyboardShortcut("k")
            }
        }

        // A separate window rather than a panel, so transfers keep running and stay watchable while
        // browsing continues.
        Window("Transfers", id: "transfers") {
            TransfersWindow()
                .environment(environment)
                .frame(minWidth: 520, minHeight: 260)
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
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

    /// Whether the connection sheet is up.
    var isShowingConnectionSheet = false

    init() {
        do {
            let services = try DriverProServices.live(prompt: prompt)
            self.services = services
            self.browser = BrowserModel(services: services)
            self.bookmarks = BookmarkListModel(store: services.bookmarks)
            self.transfers = TransferListModel(services: services)
            TerminationDelegate.shared = self
        } catch {
            startupError = "DriverPro could not open its database.\n\n\(error.localizedDescription)"
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
        }
        return .terminateLater
    }
}
