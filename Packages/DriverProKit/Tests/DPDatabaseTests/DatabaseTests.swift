//
//  DatabaseTests.swift
//  DPDatabaseTests
//

import Foundation
import Testing
@testable import DPDatabase

/// The schema used by most tests here.
private let scratchMigrations = [
    Migration(version: 1, statements: [
        """
        CREATE TABLE thing (
            id    INTEGER PRIMARY KEY,
            name  TEXT,
            score REAL,
            data  BLOB
        )
        """
    ])
]

@Suite("Database")
struct DatabaseTests {

    private func makeDatabase(_ migrations: [Migration] = scratchMigrations) throws -> Database {
        try Database(.memory, migrations: migrations)
    }

    // MARK: - Binding and reading

    @Test("Every storage class survives a round trip")
    func bindsAllTypes() async throws {
        let database = try makeDatabase()
        let blob = Data([0x00, 0xFF, 0x10, 0x00])   // embedded NULs, which naive C string handling loses

        try await database.execute(
            "INSERT INTO thing (id, name, score, data) VALUES (?, ?, ?, ?)",
            [.integer(1), .text("hello"), .real(2.5), .blob(blob)]
        )

        let row = try #require(try await database.rows("SELECT * FROM thing").first)
        #expect(try row.integer("id") == 1)
        #expect(try row.string("name") == "hello")
        #expect(try row.real("score") == 2.5)
        #expect(row["data"] == .blob(blob))
    }

    @Test("A long, runtime-built string is stored whole")
    func longTextSurvives() async throws {
        // This is the SQLITE_TRANSIENT test. Binding with SQLITE_STATIC promises SQLite that the bytes
        // outlive the statement, which is false for a Swift String handed to C — the buffer is
        // temporary. The damage shows up as truncated or empty text, and short literals often survive
        // by luck, so the string here is built at runtime and long enough not to.
        let database = try makeDatabase()
        let long = (0..<2000).map { "segment-\($0)" }.joined(separator: ",")

        try await database.execute("INSERT INTO thing (id, name) VALUES (?, ?)",
                                   [.integer(1), .text(long)])

        let row = try #require(try await database.rows("SELECT name FROM thing").first)
        let stored = try row.string("name")
        #expect(stored == long)
        #expect(stored.count == long.count, "text was truncated — check the bind destructor")
    }

    @Test("NULL and empty string stay distinguishable")
    func nullIsNotEmptyString() async throws {
        let database = try makeDatabase()
        try await database.execute("INSERT INTO thing (id, name) VALUES (?, ?)", [.integer(1), .null])
        try await database.execute("INSERT INTO thing (id, name) VALUES (?, ?)", [.integer(2), .text("")])

        let rows = try await database.rows("SELECT id, name FROM thing ORDER BY id")
        #expect(rows[0]["name"] == .null)
        #expect(rows[1]["name"] == .text(""))
        #expect(rows[0].optionalString("name") == nil)
        #expect(rows[1].optionalString("name") == "")
    }

    @Test("Reading a column as the wrong type is an error, not a silent zero")
    func typeMismatchThrows() async throws {
        let database = try makeDatabase()
        try await database.execute("INSERT INTO thing (id, name) VALUES (?, ?)",
                                   [.integer(1), .text("text")])

        let row = try #require(try await database.rows("SELECT * FROM thing").first)
        #expect(throws: DatabaseError.self) { try row.integer("name") }
        #expect(throws: DatabaseError.self) { try row.string("missing-column") }
    }

    @Test("Dates and UUIDs round-trip through their storage forms")
    func convenienceTypes() async throws {
        let database = try makeDatabase()
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        try await database.execute("INSERT INTO thing (id, name, score) VALUES (?, ?, ?)",
                                   [.integer(1), SQLValue(id), SQLValue(when)])

        let row = try #require(try await database.rows("SELECT * FROM thing").first)
        #expect(try row.uuid("name") == id)
        #expect(try row.date("score") == when)
    }

    // MARK: - Errors

    @Test("Malformed SQL reports what SQLite said")
    func malformedSQLSurfacesMessage() async throws {
        let database = try makeDatabase()

        let error = await #expect(throws: DatabaseError.self) {
            try await database.rows("SELECT * FROM nonexistent_table")
        }
        guard case .statementFailed(_, let message, let sql)? = error else {
            Issue.record("expected .statementFailed, got \(String(describing: error))")
            return
        }
        // A generic "query failed" would leave you guessing; the SQLite text names the table.
        #expect(message.contains("nonexistent_table"))
        #expect(sql.contains("nonexistent_table"))
    }

    @Test("A constraint violation is reported rather than silently ignored")
    func constraintViolation() async throws {
        let database = try makeDatabase()
        try await database.execute("INSERT INTO thing (id) VALUES (?)", [.integer(1)])

        await #expect(throws: DatabaseError.self) {
            try await database.execute("INSERT INTO thing (id) VALUES (?)", [.integer(1)])
        }
    }

    @Test("Using a closed connection fails clearly")
    func closedConnection() async throws {
        let database = try makeDatabase()
        await database.close()

        await #expect(throws: DatabaseError.self) {
            try await database.rows("SELECT 1")
        }
    }

    // MARK: - Transactions

    @Test("A failing statement rolls the whole batch back")
    func transactionRollsBack() async throws {
        let database = try makeDatabase()
        try await database.execute("INSERT INTO thing (id) VALUES (?)", [.integer(1)])

        await #expect(throws: DatabaseError.self) {
            try await database.transaction([
                SQL("INSERT INTO thing (id) VALUES (?)", [.integer(2)]),
                SQL("INSERT INTO thing (id) VALUES (?)", [.integer(3)]),
                SQL("INSERT INTO thing (id) VALUES (?)", [.integer(1)])   // duplicate key
            ])
        }

        // Neither 2 nor 3 may survive: all or nothing is the whole point.
        let rows = try await database.rows("SELECT id FROM thing ORDER BY id")
        #expect(rows.count == 1)
        #expect(try rows[0].integer("id") == 1)
    }

    @Test("A batch that succeeds applies everything")
    func transactionCommits() async throws {
        let database = try makeDatabase()
        try await database.transaction([
            SQL("INSERT INTO thing (id) VALUES (?)", [.integer(1)]),
            SQL("INSERT INTO thing (id) VALUES (?)", [.integer(2)])
        ])

        #expect(try await database.rows("SELECT id FROM thing").count == 2)
    }
}

@Suite("Migrations")
struct MigrationTests {

    @Test("Migrations run in order and record the version")
    func appliesInOrder() async throws {
        let database = try Database(.memory, migrations: [
            Migration(version: 1, statements: ["CREATE TABLE a (id INTEGER PRIMARY KEY)"]),
            Migration(version: 2, statements: ["CREATE TABLE b (id INTEGER PRIMARY KEY)"]),
            Migration(version: 3, statements: ["ALTER TABLE a ADD COLUMN note TEXT"])
        ])

        #expect(try await database.schemaVersion() == 3)
        try await database.execute("INSERT INTO a (id, note) VALUES (1, 'ok')")
        try await database.execute("INSERT INTO b (id) VALUES (1)")
    }

    @Test("Reopening an up-to-date file applies nothing")
    func reopeningIsANoOp() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let migrations = [
            Migration(version: 1, statements: ["CREATE TABLE a (id INTEGER PRIMARY KEY)"])
        ]

        let first = try Database(.file(url), migrations: migrations)
        try await first.execute("INSERT INTO a (id) VALUES (1)")
        await first.close()

        // Re-running `CREATE TABLE a` would throw, so this only passes if the version was honoured.
        let second = try Database(.file(url), migrations: migrations)
        #expect(try await second.schemaVersion() == 1)
        #expect(try await second.rows("SELECT id FROM a").count == 1, "existing data must survive")
    }

    @Test("Only migrations newer than the file's version are applied")
    func appliesOnlyNewMigrations() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let v1 = [Migration(version: 1, statements: ["CREATE TABLE a (id INTEGER PRIMARY KEY)"])]
        let database = try Database(.file(url), migrations: v1)
        try await database.execute("INSERT INTO a (id) VALUES (1)")
        await database.close()

        // A later release adds a migration. The old one must not run again.
        let v2 = v1 + [Migration(version: 2, statements: ["ALTER TABLE a ADD COLUMN note TEXT"])]
        let upgraded = try Database(.file(url), migrations: v2)

        #expect(try await upgraded.schemaVersion() == 2)
        #expect(try await upgraded.rows("SELECT id, note FROM a").count == 1)
    }

    @Test("A failing migration leaves the schema at its previous version")
    func failedMigrationRollsBack() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let good = [Migration(version: 1, statements: ["CREATE TABLE a (id INTEGER PRIMARY KEY)"])]
        let first = try Database(.file(url), migrations: good)
        await first.close()

        // Version 2 creates a table and then runs nonsense. Neither may survive.
        let broken = good + [Migration(version: 2, statements: [
            "CREATE TABLE b (id INTEGER PRIMARY KEY)",
            "THIS IS NOT SQL"
        ])]

        #expect(throws: DatabaseError.self) {
            _ = try Database(.file(url), migrations: broken)
        }

        let reopened = try Database(.file(url), migrations: good)
        #expect(try await reopened.schemaVersion() == 1, "a half-applied migration must not be recorded")
        // Table b must not exist, or the migration was only partly rolled back.
        await #expect(throws: DatabaseError.self) {
            try await reopened.rows("SELECT id FROM b")
        }
    }

    @Test("A file database persists across connections")
    func filePersists() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let migrations = [Migration(version: 1, statements: ["CREATE TABLE a (id INTEGER PRIMARY KEY)"])]
        let writer = try Database(.file(url), migrations: migrations)
        try await writer.execute("INSERT INTO a (id) VALUES (?)", [.integer(42)])
        await writer.close()

        let reader = try Database(.file(url), migrations: migrations)
        let rows = try await reader.rows("SELECT id FROM a")
        #expect(try rows.first?.integer("id") == 42)
    }
}
