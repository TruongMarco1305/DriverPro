//
//  FormAndBookmarkTests.swift
//  DPPresentationTests
//

import DPBookmarks
import DPCore
import DPDatabase
import DPServices
import Foundation
import Testing
@testable import DPPresentation

@Suite("ConnectionFormModel")
@MainActor
struct ConnectionFormModelTests {

    @Test("The port starts at the protocol's default")
    func portDefaultsFromDescriptor() {
        let form = ConnectionFormModel()
        #expect(form.protocolIdentifier == .sftp)
        #expect(form.port == "22")
    }

    @Test("Choosing a protocol resets the port to that protocol's default")
    func choosingAProtocolResetsThePort() {
        // The chooser step relies on this: pick SFTP, then go back and pick WebDAV, and the port must
        // follow rather than leaving 22 in a WebDAV form.
        let catalog = ProtocolCatalog(descriptors: [
            ProtocolDescriptor(id: .sftp, displayName: "SFTP", summary: "Over SSH.", scheme: "sftp",
                               defaultPort: 22, fields: [.username, .password], iconName: "server.rack"),
            ProtocolDescriptor(id: .webdav, displayName: "WebDAV", summary: "Over HTTPS.", scheme: "https",
                               defaultPort: 443, fields: [.username, .password], iconName: "globe")
        ])
        let form = ConnectionFormModel(catalog: catalog)
        #expect(form.port == "22")

        form.port = "2222"
        form.protocolIdentifier = .webdav
        #expect(form.port == "443", "a typed port belongs to the protocol it was typed for")
    }

    @Test("Which fields to show comes from the descriptor, not from a switch in a view")
    func fieldsComeFromDescriptor() {
        // The claim that adding WebDAV needs no view change is only true if the view asks this.
        let form = ConnectionFormModel()
        #expect(form.shows(.username))
        #expect(form.shows(.password))
        #expect(form.shows(.privateKey))
        #expect(!form.shows(.anonymous), "SFTP has no anonymous mode")
    }

    @Test("A hostname is required, and the port must be a real port", arguments: [
        (hostname: "", port: "22", valid: false),
        (hostname: "   ", port: "22", valid: false),
        (hostname: "example.com", port: "22", valid: true),
        (hostname: "example.com", port: "", valid: false),
        (hostname: "example.com", port: "abc", valid: false),
        (hostname: "example.com", port: "0", valid: false),
        (hostname: "example.com", port: "70000", valid: false),
        (hostname: "example.com", port: "2222", valid: true)
    ])
    func validation(_ testCase: (hostname: String, port: String, valid: Bool)) {
        let form = ConnectionFormModel()
        form.hostname = testCase.hostname
        form.port = testCase.port
        form.password = "hunter2"      // required; varied separately below
        #expect(form.isValid == testCase.valid)
    }

    @Test("A password is required, because this sheet only creates new connections")
    func passwordIsRequired() {
        // Reconnecting to a saved bookmark never opens this sheet, so there is nothing in the Keychain
        // to fall back on and a blank password would just fail at the server.
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        #expect(!form.isValid)

        form.password = "hunter2"
        #expect(form.isValid)
    }

    @Test("Credentials are always saved to the Keychain")
    func credentialsAlwaysPersist() {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.username = "duck"
        form.password = "hunter2"

        #expect(form.makeCredentials()?.shouldPersist == true)
    }

    @Test("The description is stored on the bookmark and read back")
    func descriptionRoundTrips() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"
        form.nickname = "Work"
        form.details = "  Staging box, EU  "

        let host = try #require(form.makeHost())
        #expect(host.comment == "Staging box, EU", "whitespace trimmed like the other fields")

        let reloaded = ConnectionFormModel()
        reloaded.load(from: host)
        #expect(reloaded.details == "Staging box, EU")
    }

    @Test("An empty description stays absent rather than becoming a blank string")
    func emptyDescriptionIsNil() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"
        form.details = "   "

        #expect(try #require(form.makeHost()).comment == nil)
    }

    @Test("The built bookmark trims whitespace and drops empty optionals")
    func buildsAHost() throws {
        let form = ConnectionFormModel()
        form.hostname = "  example.com  "
        form.port = "2222"
        form.username = " duck "
        form.password = "hunter2"
        form.nickname = ""
        form.defaultPath = "  "

        let host = try #require(form.makeHost())
        #expect(host.hostname == "example.com")
        #expect(host.port == 2222)
        #expect(host.username == "duck")
        // Empty is not the same as blank: "no nickname recorded" must stay distinguishable.
        #expect(host.nickname == nil)
        #expect(host.defaultPath == nil)
    }

    @Test("An invalid form builds nothing")
    func invalidFormBuildsNothing() {
        let form = ConnectionFormModel()
        form.hostname = ""
        #expect(form.makeHost() == nil)
    }

    @Test("Loading a bookmark fills the form but never the password")
    func loadsFromBookmark() {
        let host = RemoteHost(
            protocolIdentifier: .sftp, hostname: "example.com", port: 2222, username: "duck",
            defaultPath: RemotePath("/srv"), nickname: "Work", comment: "notes"
        )
        let form = ConnectionFormModel()
        form.password = "left over from before"
        form.load(from: host)

        #expect(form.hostname == "example.com")
        #expect(form.port == "2222")
        #expect(form.username == "duck")
        #expect(form.defaultPath == "/srv")
        #expect(form.nickname == "Work")
        #expect(form.password.isEmpty, "a stored password is never loaded back into a text field")
    }

    // MARK: - Editing

    @Test("Editing keeps the bookmark's identity, so a save updates rather than duplicates")
    func editingKeepsTheIdentity() async throws {
        let original = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                                  username: "duck", nickname: "Work")
        let store = BookmarkStore(database: try Database(.memory, migrations: BookmarkStore.migrations))
        try await store.save(original)

        let form = ConnectionFormModel()
        form.load(from: original)
        #expect(form.isEditing)

        form.nickname = "Work (EU)"
        let edited = try #require(form.makeHost())
        #expect(edited.id == original.id)

        try await store.save(edited)
        let saved = try await store.load()
        #expect(saved.count == 1, "an edit must not leave the old row behind")
        #expect(saved.first?.nickname == "Work (EU)")
    }

    @Test("A blank password is fine when editing, because the saved one is being kept")
    func editingDoesNotRequireThePassword() {
        // The Keychain never reads a password back into a text field, so demanding one here would mean
        // retyping it to change a nickname.
        let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                              username: "duck")
        let form = ConnectionFormModel()
        form.load(from: host)

        #expect(form.password.isEmpty)
        #expect(form.isValid)
        #expect(form.makeCredentials() == nil, "nothing typed means nothing to hand over")

        form.password = "new one"
        #expect(form.makeCredentials()?.shouldPersist == true)
    }

    @Test("A form that was never loaded still mints a fresh identity each time")
    func creatingMintsNewIdentities() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"

        #expect(!form.isEditing)
        #expect(try #require(form.makeHost()).id != #require(form.makeHost()).id)
    }

    // MARK: - Persistence

    @Test("The built bookmark survives a round trip through the store")
    func roundTripsThroughTheStore() async throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.port = "2222"
        form.username = "duck"
        form.password = "hunter2"
        form.nickname = "Work"

        let host = try #require(form.makeHost())
        let store = BookmarkStore(database: try Database(.memory, migrations: BookmarkStore.migrations))
        try await store.save(host)

        #expect(try await store.load().first == host)
    }
}

@Suite("BookmarkListModel")
@MainActor
struct BookmarkListModelTests {

    private func makeModel() throws -> BookmarkListModel {
        BookmarkListModel(store: BookmarkStore(
            database: try Database(.memory, migrations: BookmarkStore.migrations)
        ))
    }

    private func makeHost(_ nickname: String) -> RemoteHost {
        RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                   username: "duck", nickname: nickname)
    }

    @Test("An empty store shows nothing and reports no error")
    func startsEmpty() async throws {
        let model = try makeModel()
        await model.reload()
        #expect(model.bookmarks.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("Saving shows up in the list, sorted")
    func savingAppears() async throws {
        let model = try makeModel()
        await model.save(makeHost("Zebra"))
        await model.save(makeHost("apple"))

        #expect(model.bookmarks.map(\.nickname) == ["apple", "Zebra"])
    }

    @Test("Deleting removes one and keeps the rest")
    func deletingRemovesOne() async throws {
        let model = try makeModel()
        let keep = makeHost("Keep")
        let drop = makeHost("Drop")
        await model.save(keep)
        await model.save(drop)

        await model.delete(drop.id)
        #expect(model.bookmarks.map(\.nickname) == ["Keep"])
    }

    @Test("Deleting something absent is not an error")
    func deletingAbsentIsFine() async throws {
        let model = try makeModel()
        await model.delete(UUID())
        #expect(model.errorMessage == nil)
    }
}
