//
//  BookmarkStoreTests.swift
//  DPBookmarksTests
//

import DPCore
import DPDatabase
import Foundation
import Testing
@testable import DPBookmarks

@Suite("BookmarkStore")
struct BookmarkStoreTests {

    /// A store over a private in-memory database: hermetic, fast, nothing to clean up.
    private func makeStore() throws -> BookmarkStore {
        BookmarkStore(database: try Database(.memory, migrations: BookmarkStore.migrations))
    }

    private func makeHost(nickname: String? = nil, hostname: String = "example.com") -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: hostname,
            port: 22,
            username: "duck",
            nickname: nickname
        )
    }

    @Test("A saved bookmark comes back with its fields intact")
    func roundTrip() async throws {
        let store = try makeStore()
        let host = RemoteHost(
            protocolIdentifier: .s3,
            hostname: "s3.example.com",
            port: 443,
            username: "AKIAEXAMPLE",
            defaultPath: RemotePath("/bucket/prefix"),
            nickname: "Backups",
            comment: "nightly",
            properties: ["s3.region": "eu-west-1", "s3.pathStyle": "true"]
        )

        try await store.save(host)
        let loaded = try await store.load()

        #expect(loaded.count == 1)
        // Every field, including the protocol-specific bag and the default path.
        #expect(loaded.first == host)
    }

    @Test("An empty database loads as no bookmarks, not an error")
    func emptyDatabase() async throws {
        #expect(try await makeStore().load().isEmpty)
    }

    @Test("Saving twice updates in place rather than duplicating")
    func saveIsIdempotent() async throws {
        let store = try makeStore()
        var host = makeHost(nickname: "First")

        try await store.save(host)
        host.nickname = "Second"
        try await store.save(host)

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.nickname == "Second")
    }

    @Test("Updating preserves when the bookmark was first added")
    func updatePreservesCreatedAt() async throws {
        let database = try Database(.memory, migrations: BookmarkStore.migrations)
        let store = BookmarkStore(database: database)
        var host = makeHost(nickname: "Original")

        try await store.save(host)
        let created = try await database.rows("SELECT created_at FROM bookmark").first?.real("created_at")

        try await Task.sleep(for: .milliseconds(20))
        host.nickname = "Renamed"
        try await store.save(host)

        let rows = try await database.rows("SELECT created_at, updated_at FROM bookmark")
        #expect(try rows.first?.real("created_at") == created, "renaming must not reset the creation date")
        #expect(try #require(rows.first).real("updated_at") > #require(created))
    }

    @Test("Load by id returns just that bookmark")
    func loadByID() async throws {
        let store = try makeStore()
        let wanted = makeHost(nickname: "Wanted")
        try await store.save(wanted)
        try await store.save(makeHost(nickname: "Other"))

        #expect(try await store.load(wanted.id) == wanted)
        #expect(try await store.load(UUID()) == nil)
    }

    @Test("Delete removes one bookmark and leaves the rest")
    func deleteRemovesOne() async throws {
        let store = try makeStore()
        let keep = makeHost(nickname: "Keep")
        let drop = makeHost(nickname: "Drop")

        try await store.save(keep)
        try await store.save(drop)
        try await store.delete(drop.id)

        #expect(try await store.load().map(\.nickname) == ["Keep"])
    }

    @Test("Deleting something that is not there succeeds")
    func deleteIsIdempotent() async throws {
        try await makeStore().delete(UUID())
    }

    @Test("Bookmarks load sorted by display name")
    func sortedByDisplayName() async throws {
        let store = try makeStore()
        for name in ["Zebra", "apple", "Mango"] {
            try await store.save(makeHost(nickname: name))
        }
        #expect(try await store.load().map(\.nickname) == ["apple", "Mango", "Zebra"])
    }

    @Test("One unusable row does not hide the others")
    func corruptRowIsSkipped() async throws {
        // The database equivalent of the old "corrupt file" case: a row written by a hand edit or a
        // future schema must not make the whole sidebar unusable.
        let database = try Database(.memory, migrations: BookmarkStore.migrations)
        let store = BookmarkStore(database: database)
        try await store.save(makeHost(nickname: "Good"))

        try await database.execute(
            """
            INSERT INTO bookmark (id, protocol, hostname, port, properties, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text("not-a-uuid"), .text("sftp"), .text("bad.example.com"), .integer(22),
             .text("{}"), .real(0), .real(0)]
        )

        #expect(try await store.load().map(\.nickname) == ["Good"])
    }

    @Test("Malformed properties degrade to empty rather than losing the bookmark")
    func malformedPropertiesDegrade() async throws {
        let database = try Database(.memory, migrations: BookmarkStore.migrations)
        let store = BookmarkStore(database: database)
        let host = makeHost(nickname: "Wonky")
        try await store.save(host)

        try await database.execute("UPDATE bookmark SET properties = ? WHERE id = ?",
                                   [.text("{ not json"), SQLValue(host.id)])

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.properties.isEmpty == true)
    }

    // MARK: - Secrets

    @Test("The schema has no column that could hold a secret")
    func schemaHoldsNoSecret() async throws {
        // The structural version of the guarantee: previously we grepped the file, now the column list
        // itself makes a password unstorable.
        let database = try Database(.memory, migrations: BookmarkStore.migrations)
        let columns = try await database.rows("PRAGMA table_info(bookmark)")
            .compactMap { try? $0.string("name") }

        #expect(!columns.isEmpty)
        for column in columns {
            #expect(!column.lowercased().contains("password"))
            #expect(!column.lowercased().contains("passphrase"))
            #expect(!column.lowercased().contains("secret"))
        }
    }

    @Test("Stored bytes contain no secret")
    func storedDataHoldsNoSecret() async throws {
        let store = try makeStore()
        try await store.save(makeHost(nickname: "Work"))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-export-\(UUID().uuidString)")
        try await store.exportJSON(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let json = try String(contentsOf: try #require(files.first), encoding: .utf8)

        #expect(json.contains("example.com"))
        #expect(!json.lowercased().contains("password"))
        #expect(!json.lowercased().contains("passphrase"))
        #expect(!json.contains("hunter2"))
    }

    // MARK: - Interchange

    @Test("Export and import reproduce every bookmark exactly")
    func exportImportRoundTrip() async throws {
        let source = try makeStore()
        let hosts = [
            makeHost(nickname: "One", hostname: "a.example.com"),
            makeHost(nickname: "Two", hostname: "b.example.com"),
            RemoteHost(protocolIdentifier: .webdav, hostname: "dav.example.com", port: 443,
                       username: "u", nickname: "Three", properties: ["k": "v"])
        ]
        for host in hosts { try await source.save(host) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await source.exportJSON(to: directory) == 3)

        // A different database entirely — this is the restore-from-backup path.
        let destination = try makeStore()
        #expect(try await destination.importJSON(from: directory) == 3)
        #expect(try await destination.load() == hosts.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        })
    }

    @Test("Import skips files it cannot parse")
    func importSkipsBadFiles() async throws {
        let store = try makeStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = makeHost(nickname: "Good")
        try JSONEncoder().encode(good).write(to: directory.appending(path: "\(good.id.uuidString).json"))
        try Data("{ not json".utf8).write(to: directory.appending(path: "broken.json"))
        try Data("ignored".utf8).write(to: directory.appending(path: "notes.txt"))

        #expect(try await store.importJSON(from: directory) == 1)
        #expect(try await store.load().map(\.nickname) == ["Good"])
    }

    @Test("Import replaces an existing bookmark with the same id")
    func importReplaces() async throws {
        let store = try makeStore()
        var host = makeHost(nickname: "Before")
        try await store.save(host)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        host.nickname = "After"
        try JSONEncoder().encode(host).write(to: directory.appending(path: "\(host.id.uuidString).json"))

        #expect(try await store.importJSON(from: directory) == 1)
        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.nickname == "After")
    }
}
