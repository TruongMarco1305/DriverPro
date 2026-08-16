//
//  Database.swift
//  DPDatabase
//

import Foundation
import SQLite3

/// One SQLite connection, serialised through an actor.
///
/// ## Swift note — SQLite is a C API
/// Everything here is `sqlite3_*` C functions taking an `OpaquePointer`. Three habits make that safe:
///
/// 1. **Every prepared statement is finalised in a `defer`.** A leaked statement holds its read
///    transaction open and eventually blocks writers — a hang, not a crash, which is worse to diagnose.
/// 2. **Text and blobs bind with `SQLITE_TRANSIENT`.** See ``transientDestructor``; this is the classic
///    SQLite-from-Swift bug.
/// 3. **The connection handle never leaves the actor.** `OpaquePointer` is not `Sendable`, and it does
///    not need to be: it is stored in actor-isolated state, and every C call is synchronous, so there is
///    no suspension point at which it could escape. No `@unchecked Sendable` required.
public actor Database {

    /// Where the database lives.
    public enum Location: Sendable {
        /// A file on disk. Parent directories are created if missing.
        case file(URL)
        /// A private in-memory database, discarded when closed. Used by tests: hermetic and fast.
        case memory
    }

    /// Owns the connection handle and closes it when the last reference goes.
    ///
    /// ## Swift note — why not just a `deinit` on the actor
    /// An actor's `deinit` is nonisolated, so Swift 6 refuses to let it touch a non-`Sendable` stored
    /// property such as `OpaquePointer` — it cannot prove nothing else is using it. Giving the handle
    /// its own owner sidesteps that: when `Database` goes away its reference drops, and this class's
    /// `deinit` closes the connection. Ownership expresses the lifetime instead of a teardown method
    /// somebody has to remember to call.
    ///
    /// `@unchecked Sendable` is justified narrowly: the handle is only ever used inside `Database`'s
    /// isolation, and `sqlite3_close_v2` is safe to call from any thread.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer

        init(handle: OpaquePointer) { self.handle = handle }

        deinit { sqlite3_close_v2(handle) }
    }

    private var connection: Connection?

    private var handle: OpaquePointer? { connection?.handle }

    /// The path this connection was opened on, for diagnostics.
    public nonisolated let path: String

    // MARK: - Opening

    /// Opens the database and brings its schema up to date.
    ///
    /// - Parameters:
    ///   - location: File or in-memory.
    ///   - migrations: Schema history, in ascending version order. Only versions above the file's
    ///     current `user_version` are applied.
    /// - Throws: ``DatabaseError/openFailed(path:message:)`` or
    ///   ``DatabaseError/migrationFailed(version:message:)``.
    public init(_ location: Location, migrations: [Migration] = []) throws {
        switch location {
        case .memory:
            path = ":memory:"
        case .file(let url):
            path = url.path
            let parent = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        }

        // Work happens through static helpers taking the handle explicitly, so none of it depends on
        // actor isolation that is not yet established during `init`.
        let opened = try Self.open(path: path)
        do {
            try Self.configure(opened)
            try Self.migrate(opened, migrations: migrations)
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
        connection = Connection(handle: opened)
    }

    /// Closes the connection. Further calls throw ``DatabaseError/openFailed(path:message:)``.
    ///
    /// Optional — dropping the last reference to the database closes it too. Useful when a file needs
    /// releasing at a known moment rather than whenever the object happens to be deallocated.
    public func close() {
        connection = nil
    }

    // MARK: - Running statements

    /// Runs a statement that returns no rows.
    ///
    /// - Parameters:
    ///   - sql: Statement text with `?` placeholders.
    ///   - bindings: Values for the placeholders, in order.
    /// - Throws: ``DatabaseError/statementFailed(code:message:sql:)``.
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        _ = try run(sql, bindings, collectingRows: false)
    }

    /// Runs a query and returns its rows.
    ///
    /// - Parameters:
    ///   - sql: Statement text with `?` placeholders.
    ///   - bindings: Values for the placeholders, in order.
    /// - Returns: Every row, materialised.
    /// - Throws: ``DatabaseError/statementFailed(code:message:sql:)``.
    public func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        try run(sql, bindings, collectingRows: true)
    }

    /// Runs several statements as one unit: all of them apply, or none do.
    ///
    /// - Parameter statements: What to run, in order.
    /// - Throws: The first failure, after rolling back.
    public func transaction(_ statements: [SQL]) throws {
        try Self.exec(handle, "BEGIN")
        do {
            for statement in statements {
                _ = try run(statement.text, statement.bindings, collectingRows: false)
            }
            try Self.exec(handle, "COMMIT")
        } catch {
            // Rollback is best-effort: if it fails too, the original error is the useful one.
            try? Self.exec(handle, "ROLLBACK")
            throw error
        }
    }

    /// The schema version currently recorded in the file.
    public func schemaVersion() throws -> Int {
        let rows = try rows("PRAGMA user_version")
        guard case .integer(let version)? = rows.first?["user_version"] else { return 0 }
        return Int(version)
    }

    // MARK: - Implementation

    private func run(_ sql: String, _ bindings: [SQLValue], collectingRows: Bool) throws -> [Row] {
        guard let handle else {
            throw DatabaseError.openFailed(path: path, message: "the connection is closed")
        }
        return try Self.perform(handle, sql, bindings, collectingRows: collectingRows)
    }

    // MARK: - Static helpers
    //
    // Take the handle explicitly so they can be used from `init`, before actor isolation is established.

    private static func open(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw DatabaseError.openFailed(path: path, message: message)
        }
        return handle
    }

    private static func configure(_ handle: OpaquePointer?) throws {
        // WAL lets readers and writers coexist, and survives a crash mid-write. It costs two extra
        // files alongside the database (-wal and -shm) while the connection is open.
        try exec(handle, "PRAGMA journal_mode = WAL")
        try exec(handle, "PRAGMA foreign_keys = ON")
        // Rather than failing instantly when another connection holds a lock, wait a little.
        try exec(handle, "PRAGMA busy_timeout = 5000")
    }

    private static func migrate(_ handle: OpaquePointer?, migrations: [Migration]) throws {
        let current = try currentVersion(handle)

        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            do {
                try exec(handle, "BEGIN")
                for statement in migration.statements {
                    try exec(handle, statement)
                }
                // Not parameterisable — PRAGMA takes a literal. Safe because it is an Int, never input.
                try exec(handle, "PRAGMA user_version = \(migration.version)")
                try exec(handle, "COMMIT")
            } catch {
                try? exec(handle, "ROLLBACK")
                let message = (error as? DatabaseError)?.errorDescription ?? "\(error)"
                throw DatabaseError.migrationFailed(version: migration.version, message: message)
            }
        }
    }

    private static func currentVersion(_ handle: OpaquePointer?) throws -> Int {
        let rows = try perform(handle, "PRAGMA user_version", collectingRows: true)
        guard case .integer(let version)? = rows.first?["user_version"] else { return 0 }
        return Int(version)
    }

    /// Prepares, binds, steps, and finalises. The one place any of that happens.
    ///
    /// Static, and taking the handle explicitly, so `init` can use it before actor isolation is
    /// established — which is why migrations do not need a second copy of this logic.
    private static func perform(
        _ handle: OpaquePointer?,
        _ sql: String,
        _ bindings: [SQLValue] = [],
        collectingRows: Bool
    ) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(handle, sql: sql)
        }
        // Finalised on every path, including a thrown binding error.
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement, sql: sql, handle: handle)

        var results: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if collectingRows { results.append(readRow(statement)) }
            case SQLITE_DONE:
                return results
            default:
                throw lastError(handle, sql: sql)
            }
        }
    }

    /// Runs one statement with no bindings and no results.
    private static func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        _ = try perform(handle, sql, collectingRows: false)
    }

    // MARK: - Binding

    /// SQLite's `SQLITE_TRANSIENT`, which Swift cannot import.
    ///
    /// The C header defines it as `((sqlite3_destructor_type)-1)`, and macros do not survive the C
    /// importer — so it has to be rebuilt by hand.
    ///
    /// **Why it matters.** The alternative, `SQLITE_STATIC`, promises SQLite that the bytes will still
    /// be there when the statement runs. For a Swift `String` handed to a C function that is false: the
    /// UTF-8 buffer is temporary and may be gone by the time `sqlite3_step` reads it. `TRANSIENT` tells
    /// SQLite to copy immediately. Getting this wrong produces truncated or empty text, intermittently,
    /// usually only for longer strings — a bug that passes a small test suite comfortably.
    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private static func bind(
        _ values: [SQLValue],
        to statement: OpaquePointer?,
        sql: String,
        handle: OpaquePointer?
    ) throws {
        for (offset, value) in values.enumerated() {
            // SQLite parameter indices are 1-based.
            let index = Int32(offset + 1)
            let result: Int32

            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, transientDestructor)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count),
                                      transientDestructor)
                }
            }

            guard result == SQLITE_OK else { throw lastError(handle, sql: sql) }
        }
    }

    // MARK: - Reading

    private static func readRow(_ statement: OpaquePointer?) -> Row {
        var values: [String: SQLValue] = [:]

        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))

            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                if let pointer = sqlite3_column_blob(statement, index) {
                    let count = Int(sqlite3_column_bytes(statement, index))
                    values[name] = .blob(Data(bytes: pointer, count: count))
                } else {
                    values[name] = .blob(Data())
                }
            default:
                values[name] = .null
            }
        }
        return Row(values: values)
    }

    private static func lastError(_ handle: OpaquePointer?, sql: String) -> DatabaseError {
        DatabaseError.statementFailed(
            code: sqlite3_errcode(handle),
            message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error",
            sql: sql
        )
    }
}
