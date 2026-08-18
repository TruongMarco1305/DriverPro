//
//  FileOperationTests.swift
//  DPPresentationTests
//

import DPCore
import DPTestSupport
import DPTransfer
import Foundation
import Testing
@testable import DPPresentation

@Suite("File operations")
@MainActor
struct FileOperationTests {

    private static let host = RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22,
                                         username: "duck")

    /// A browser connected to a seeded in-memory server, sitting in `/srv`.
    private func makeBrowser(
        capabilities: SessionCapabilities = .posixFileSystem
    ) async throws -> (BrowserModel, MemorySession) {
        let session = MemorySession(host: Self.host, capabilities: capabilities)
        await session.seed(directory: RemotePath("/srv"))
        await session.seed(file: RemotePath("/srv/file.txt"), contents: Data("hello".utf8))
        await session.seed(file: RemotePath("/srv/tree/deep/leaf.bin"), contents: Data("x".utf8))

        let (services, _) = try await ServicesFixture.makeServices(
            for: Self.host, prompt: SilentPrompt(), session: session
        )
        let model = BrowserModel(services: services)
        await model.connect(to: Self.host)
        await model.navigate(to: RemotePath("/srv"))
        return (model, session)
    }

    // MARK: - Creating

    @Test("Creating a folder shows it without a manual refresh")
    func createDirectoryRefreshes() async throws {
        let (model, _) = try await makeBrowser()

        await model.createDirectory(named: "new-folder")

        #expect(model.errorMessage == nil)
        #expect(model.visibleItems.contains { $0.name == "new-folder" && $0.isDirectory })
    }

    @Test("A blank name does nothing")
    func blankNameIsIgnored() async throws {
        let (model, _) = try await makeBrowser()
        let before = model.entries.count

        await model.createDirectory(named: "   ")

        #expect(model.entries.count == before)
        #expect(model.errorMessage == nil)
    }

    @Test("Creating over an existing name reports why, and keeps the listing")
    func duplicateNameReports() async throws {
        let (model, _) = try await makeBrowser()
        let before = model.entries.count

        await model.createDirectory(named: "file.txt")

        #expect(model.errorMessage != nil)
        #expect(model.entries.count == before, "a failed operation must not blank the table")
    }

    // MARK: - Renaming

    @Test("Renaming moves the entry and refreshes")
    func renameWorks() async throws {
        let (model, _) = try await makeBrowser()
        let item = try #require(model.visibleItems.first { $0.name == "file.txt" })

        await model.rename(item, to: "renamed.txt")

        #expect(model.errorMessage == nil)
        #expect(model.visibleItems.contains { $0.name == "renamed.txt" })
        #expect(!model.visibleItems.contains { $0.name == "file.txt" })
    }

    @Test("Renaming to the same name, or to blank, does nothing")
    func renameNoOps() async throws {
        let (model, _) = try await makeBrowser()
        let item = try #require(model.visibleItems.first { $0.name == "file.txt" })

        await model.rename(item, to: "file.txt")
        await model.rename(item, to: "  ")

        #expect(model.errorMessage == nil)
        #expect(model.visibleItems.contains { $0.name == "file.txt" })
    }

    @Test("Rename is not offered when the backend cannot do it")
    func renameIsCapabilityGated() async throws {
        // An S3-shaped backend. The UI reads this to grey the command out rather than offering it and
        // failing after the click — the reason SessionCapabilities exists.
        let (capable, _) = try await makeBrowser()
        #expect(capable.canRename)

        let (limited, _) = try await makeBrowser(
            capabilities: SessionCapabilities.posixFileSystem.subtracting(.rename)
        )
        #expect(!limited.canRename)
    }

    // MARK: - Deleting

    @Test("Deleting a file removes it")
    func deleteFile() async throws {
        let (model, _) = try await makeBrowser()
        let item = try #require(model.visibleItems.first { $0.name == "file.txt" })

        await model.delete([item])

        #expect(model.errorMessage == nil)
        #expect(!model.visibleItems.contains { $0.name == "file.txt" })
    }

    @Test("Deleting a folder takes its contents with it")
    func deleteDirectoryRecursively() async throws {
        // SFTP has no recursive delete, so this goes through Session.deleteTree and walks depth-first.
        // The in-memory session here also lacks the capability, so the fallback is what runs.
        let (model, session) = try await makeBrowser(
            capabilities: SessionCapabilities.posixFileSystem.subtracting(.recursiveDelete)
        )
        let tree = try #require(model.visibleItems.first { $0.name == "tree" })

        await model.delete([tree])

        #expect(model.errorMessage == nil)
        #expect(!model.visibleItems.contains { $0.name == "tree" })
        #expect(await !session.exists(RemotePath("/srv/tree/deep/leaf.bin")))
    }

    @Test("Deleting several entries removes all of them")
    func deleteMultiple() async throws {
        let (model, _) = try await makeBrowser(
            capabilities: SessionCapabilities.posixFileSystem.subtracting(.recursiveDelete)
        )
        let items = model.visibleItems

        await model.delete(items)

        #expect(model.visibleItems.isEmpty)
    }

    @Test("Deleting nothing does nothing")
    func deleteEmptyIsSafe() async throws {
        let (model, _) = try await makeBrowser()
        let before = model.entries.count

        await model.delete([])

        #expect(model.entries.count == before)
    }

    // MARK: - Building transfers

    @Test("A download names the selected entries and the chosen folder")
    func buildsADownload() async throws {
        let (model, _) = try await makeBrowser()
        let item = try #require(model.visibleItems.first { $0.name == "file.txt" })
        let destination = URL(fileURLWithPath: "/tmp/downloads")

        let transfer = try #require(model.makeDownload(of: [item], to: destination))

        #expect(transfer.isDownload)
        #expect(transfer.host == Self.host)
        guard case .download(let sources, let target) = transfer.work else {
            Issue.record("expected a download")
            return
        }
        #expect(sources == [RemotePath("/srv/file.txt")])
        #expect(target == destination)
    }

    @Test("An upload targets the directory currently shown")
    func buildsAnUpload() async throws {
        // The most likely way to get this wrong is sending files to the wrong place.
        let (model, _) = try await makeBrowser()
        await model.navigate(to: RemotePath("/srv/tree"))
        let local = URL(fileURLWithPath: "/tmp/thing.txt")

        let transfer = try #require(model.makeUpload(of: [local]))

        #expect(!transfer.isDownload)
        guard case .upload(let sources, let destination) = transfer.work else {
            Issue.record("expected an upload")
            return
        }
        #expect(sources == [local])
        #expect(destination == RemotePath("/srv/tree"), "uploads go to the directory being shown")
    }

    @Test("A drop onto a folder row uploads into that folder, not the one being shown")
    func uploadsOntoAFolderRow() async throws {
        // The two meanings of a drop: onto the listing, and onto a folder in it.
        let (model, _) = try await makeBrowser()
        let folder = try #require(model.visibleItems.first { $0.isDirectory })
        let local = URL(fileURLWithPath: "/tmp/x")

        let transfer = try #require(model.makeUpload(of: [local], onto: folder))
        guard case .upload(_, let destination) = transfer.work else {
            Issue.record("not an upload")
            return
        }
        #expect(destination == folder.path)
        #expect(destination != model.path, "otherwise the folder row is decoration")
    }

    @Test("A drop onto a file row is refused rather than redirected")
    func refusesADropOntoAFile() async throws {
        // Uploading into the file's parent instead would put files somewhere nobody aimed at.
        let (model, _) = try await makeBrowser()
        let file = try #require(model.visibleItems.first { !$0.isDirectory })

        #expect(model.makeUpload(of: [URL(fileURLWithPath: "/tmp/x")], onto: file) == nil)
    }

    @Test("An explicit destination overrides the directory being shown")
    func explicitDestinationWins() async throws {
        let (model, _) = try await makeBrowser()
        let transfer = try #require(
            model.makeUpload(of: [URL(fileURLWithPath: "/tmp/x")], into: RemotePath("/elsewhere"))
        )
        guard case .upload(_, let destination) = transfer.work else {
            Issue.record("not an upload")
            return
        }
        #expect(destination == RemotePath("/elsewhere"))
    }

    @Test("The default policy is resume, not overwrite")
    func defaultPolicyIsResume() async throws {
        // Overwrite was the silent default until now: downloading a file you already had destroyed the
        // local copy with no warning.
        let (model, _) = try await makeBrowser()
        let item = try #require(model.visibleItems.first { $0.name == "file.txt" })

        let download = try #require(model.makeDownload(of: [item], to: URL(fileURLWithPath: "/tmp")))
        let upload = try #require(model.makeUpload(of: [URL(fileURLWithPath: "/tmp/x")]))

        #expect(download.overwritePolicy == .resume)
        #expect(upload.overwritePolicy == .resume)
    }

    @Test("The chosen policy reaches the transfer", arguments: [
        OverwritePolicy.overwrite, .skip, .rename, .resume
    ])
    func policyIsCarried(_ policy: OverwritePolicy) async throws {
        let (model, _) = try await makeBrowser()
        let item = try #require(model.visibleItems.first { $0.name == "file.txt" })

        let download = try #require(
            model.makeDownload(of: [item], to: URL(fileURLWithPath: "/tmp"), policy: policy)
        )
        let upload = try #require(model.makeUpload(of: [URL(fileURLWithPath: "/tmp/x")], policy: policy))

        #expect(download.overwritePolicy == policy)
        #expect(upload.overwritePolicy == policy)
    }

    @Test("Nothing selected builds no transfer")
    func emptyBuildsNothing() async throws {
        let (model, _) = try await makeBrowser()
        #expect(model.makeDownload(of: [], to: URL(fileURLWithPath: "/tmp")) == nil)
        #expect(model.makeUpload(of: []) == nil)
    }

    @Test("Selected items follow the visible order")
    func selectedItemsReflectSelection() async throws {
        let (model, _) = try await makeBrowser()
        model.selection = [RemotePath("/srv/file.txt")]

        #expect(model.selectedItems.map(\.name) == ["file.txt"])

        model.selection = []
        #expect(model.selectedItems.isEmpty)
    }
}
