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
        #expect(form.isValid == testCase.valid)
    }

    @Test("The built bookmark trims whitespace and drops empty optionals")
    func buildsAHost() throws {
        let form = ConnectionFormModel()
        form.hostname = "  example.com  "
        form.port = "2222"
        form.username = " duck "
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

    @Test("A blank password means use what is stored, not an empty password")
    func blankPasswordDefersToTheStore() {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.username = "duck"
        form.password = ""

        #expect(form.makeCredentials() == nil, "no credentials means the coordinator asks the store")

        form.password = "hunter2"
        let credentials = form.makeCredentials()
        #expect(credentials != nil)
        #expect(credentials?.shouldPersist == true)
    }

    @Test("Loading a bookmark fills the form but never the password")
    func loadsFromBookmark() {
        let host = RemoteHost(
            protocolIdentifier: .sftp, hostname: "example.com", port: 2222, username: "duck",
            defaultPath: RemotePath("/srv"), nickname: "Work"
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

    @Test("The built bookmark survives a round trip through the store")
    func roundTripsThroughTheStore() async throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.port = "2222"
        form.username = "duck"
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
