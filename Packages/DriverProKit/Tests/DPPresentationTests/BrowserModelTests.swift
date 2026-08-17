//
//  BrowserModelTests.swift
//  DPPresentationTests
//

import DPBookmarks
import DPCore
import DPCredentials
import DPDatabase
import DPServices
import DPTestSupport
import Foundation
import Testing
@testable import DPPresentation

/// A prompt that answers instantly, so connecting needs no user.
private struct SilentPrompt: UserPrompt {
    var credentials: Credentials? = .password(username: "duck", password: "hunter2")

    func askHostKey(_ challenge: HostKeyChallenge, for host: RemoteHost) async -> HostKeyDecision {
        .acceptOnce
    }
    func askCredentials(_ request: CredentialRequest) async -> Credentials? { credentials }
}

private struct MemoryFactory: SessionFactory {
    let session: MemorySession
    func makeSession(for host: RemoteHost) throws -> any Session { session }
}

@Suite("BrowserModel")
@MainActor
struct BrowserModelTests {

    private static let host = RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22,
                                         username: "duck")

    /// A model connected to an in-memory server seeded with a small tree.
    private func makeModel(
        seed: Bool = true,
        prompt: any UserPrompt = SilentPrompt()
    ) async throws -> (BrowserModel, MemorySession) {
        let session = MemorySession(host: Self.host)
        if seed {
            await session.seed(directory: RemotePath("/srv"))
            await session.seed(file: RemotePath("/srv/beta.txt"), contents: Data(repeating: 0, count: 300))
            await session.seed(file: RemotePath("/srv/alpha.bin"), contents: Data(repeating: 0, count: 100))
            await session.seed(file: RemotePath("/srv/.hidden"), contents: Data("x".utf8))
            await session.seed(directory: RemotePath("/srv/zeta"))
        }

        let services = DriverProServices(
            database: try Database(.memory, migrations: BookmarkStore.migrations),
            credentials: InMemoryCredentialStore(),
            knownHosts: KnownHostsStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "kh-\(UUID().uuidString)")),
            prompt: prompt,
            sessionFactory: MemoryFactory(session: session)
        )

        let model = BrowserModel(services: services)
        return (model, session)
    }

    // MARK: - Connecting

    @Test("Connecting lists the starting directory")
    func connectsAndLists() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)

        #expect(model.host == Self.host)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(!model.entries.isEmpty)
    }

    @Test("A failed connection reports why and leaves no host attached")
    func failedConnectionReports() async throws {
        // A cancelled prompt means no credentials, so the connection is refused.
        let (model, _) = try await makeModel(prompt: SilentPrompt(credentials: nil))
        await model.connect(to: Self.host)

        #expect(model.host == nil)
        #expect(model.errorMessage != nil)
        #expect(!model.isLoading)
    }

    // MARK: - Filtering and sorting

    @Test("Hidden files are filtered until asked for")
    func hiddenFilesToggle() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        #expect(!model.visibleItems.contains { $0.name == ".hidden" })

        model.showsHiddenFiles = true
        #expect(model.visibleItems.contains { $0.name == ".hidden" })
    }

    @Test("Directories lead, whatever the sort column")
    func directoriesSortFirst() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        for column in BrowserModel.SortColumn.allCases {
            model.sortColumn = column
            let items = model.visibleItems
            let firstFile = items.firstIndex { !$0.isDirectory } ?? items.count
            let lastDirectory = items.lastIndex { $0.isDirectory } ?? -1
            #expect(lastDirectory < firstFile, "a file appeared before a directory sorting by \(column)")
        }
    }

    @Test("Sorting by name is case-insensitive and reversible")
    func sortsByName() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        model.sortColumn = .name
        model.sortAscending = true
        let ascending = model.visibleItems.filter { !$0.isDirectory }.map(\.name)

        model.sortAscending = false
        let descending = model.visibleItems.filter { !$0.isDirectory }.map(\.name)

        #expect(ascending == ["alpha.bin", "beta.txt"])
        #expect(descending == ascending.reversed())
    }

    @Test("Sorting by size orders by bytes, not by name")
    func sortsBySize() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        model.sortColumn = .size
        model.sortAscending = true
        let names = model.visibleItems.filter { !$0.isDirectory }.map(\.name)
        #expect(names == ["alpha.bin", "beta.txt"], "100 bytes should precede 300")
    }

    // MARK: - Navigating

    @Test("Opening a directory descends; opening a file does not")
    func openDescendsIntoDirectories() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        let directory = try #require(model.visibleItems.first { $0.isDirectory })
        await model.open(directory)
        #expect(model.path == RemotePath("/srv/zeta"))

        await model.navigate(to: RemotePath("/srv"))
        let file = try #require(model.visibleItems.first { !$0.isDirectory })
        await model.open(file)
        #expect(model.path == RemotePath("/srv"), "opening a file is a transfer, not navigation")
    }

    @Test("Going up walks the tree and stops at the root")
    func goesUp() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv/zeta"))

        #expect(model.canGoUp)
        await model.goUp()
        #expect(model.path == RemotePath("/srv"))

        await model.goUp()
        #expect(model.path == .root)
        #expect(!model.canGoUp)
    }

    @Test("The breadcrumb is the path from the root down")
    func breadcrumb() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv/zeta"))

        #expect(model.breadcrumb.map(\.pathString) == ["/", "/srv", "/srv/zeta"])
    }

    @Test("A failed listing keeps the previous one on screen")
    func failedListingKeepsEntries() async throws {
        // Blanking the table because one listing failed loses the user's place for no reason.
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        let before = model.entries.count
        #expect(before > 0)

        await model.navigate(to: RemotePath("/does-not-exist"))

        #expect(model.errorMessage != nil)
        #expect(model.entries.count == before, "the listing should still be showing")
        #expect(model.path == RemotePath("/srv"), "and the path should not have moved")
    }

    @Test("Selection is cleared when the directory changes")
    func selectionResets() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))

        model.selection = [RemotePath("/srv/beta.txt")]
        await model.navigate(to: RemotePath("/srv/zeta"))
        #expect(model.selection.isEmpty)
    }

    // MARK: - Errors

    @Test("Cancellation is not shown to the user")
    func cancellationIsSilent() {
        // The user cancelled on purpose; an alert saying so is noise.
        #expect(BrowserModel.message(for: SessionError.cancelled) == nil)
    }

    @Test("An error message carries both what happened and what to do")
    func errorMessageIncludesSuggestion() throws {
        let message = try #require(BrowserModel.message(for: SessionError.authenticationFailed(reason: "bad password")))
        #expect(message.contains("Login failed"))
        #expect(message.contains("user name"), "the recovery suggestion should be included")
    }

    @Test("Dismissing clears the message")
    func dismissClearsError() async throws {
        let (model, _) = try await makeModel()
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/nope"))
        #expect(model.errorMessage != nil)

        model.dismissError()
        #expect(model.errorMessage == nil)
    }
}
