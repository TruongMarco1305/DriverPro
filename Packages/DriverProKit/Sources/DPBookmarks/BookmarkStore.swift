//
//  BookmarkStore.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPBookmarks persists saved connections. It may import Foundation, DPCore, and DPDatabase — in
//  particular it never touches secrets, which live in DPCredentials and the Keychain.
//

import DPCore
import DPDatabase
import Foundation

/// Failures specific to bookmark storage.
public enum BookmarkError: Error, Hashable, Sendable {
    /// A bookmark file could not be read or written during export or import.
    case fileUnavailable(path: String, reason: String)
}

extension BookmarkError: LocalizedError {
    /// A message naming the file that could not be used.
    public var errorDescription: String? {
        switch self {
        case .fileUnavailable(let path, let reason):
            "Could not read or write the bookmark file at \(path): \(reason)"
        }
    }
}

/// What an import of `.duck` files did.
///
/// Counts rather than a bare number, because "8 imported" is only half the story when three were
/// skipped: the user needs to know a protocol is not supported yet, not wonder where their bookmarks
/// went.
public struct DuckImportSummary: Hashable, Sendable {

    /// Bookmarks saved.
    public var imported = 0
    /// Files that were not bookmarks, or could not be read.
    public var unreadable = 0
    /// Bookmarks skipped, by the protocol this build cannot speak.
    public var unsupported: [ProtocolIdentifier: Int] = [:]

    /// Creates a summary.
    ///
    /// - Parameters:
    ///   - imported: Bookmarks saved.
    ///   - unreadable: Files that were not bookmarks.
    ///   - unsupported: Skipped bookmarks, by protocol.
    public init(
        imported: Int = 0,
        unreadable: Int = 0,
        unsupported: [ProtocolIdentifier: Int] = [:]
    ) {
        self.imported = imported
        self.unreadable = unreadable
        self.unsupported = unsupported
    }

    /// How many were skipped because their protocol is not supported.
    public var unsupportedCount: Int { unsupported.values.reduce(0, +) }

    /// Whether the import found nothing at all to do.
    public var isEmpty: Bool { imported == 0 && unreadable == 0 && unsupported.isEmpty }
}

/// Saved connections, in the database.
///
/// **No secrets are stored here.** `RemoteHost` carries the address and the Keychain coordinates, never
/// the password — which is what makes a bookmark safe to export, copy between machines, or attach to a
/// bug report. The schema has no column that could hold one.
///
/// Bookmarks were previously one JSON file each. The move to SQLite is about what comes next — the
/// transfer queue and connection history both want a database — rather than about bookmarks, which are
/// few enough that either would do. ``exportJSON(to:)`` keeps the readable form available as a
/// deliberate action. See `docs/decisions/006-sqlite-for-persistence.md`.
public actor BookmarkStore {

    private let database: Database

    /// Schema this store needs.
    ///
    /// **Version numbers are global to the database**, not per-table: every store sharing the connection
    /// draws from one sequence, so the transfer queue's first migration will be version 2, not another
    /// version 1. Allocating them centrally is the price of a single file.
    public static let migrations: [Migration] = [
        Migration(version: 1, statements: [
            """
            CREATE TABLE bookmark (
                id           TEXT PRIMARY KEY NOT NULL,
                protocol     TEXT NOT NULL,
                hostname     TEXT NOT NULL,
                port         INTEGER NOT NULL,
                username     TEXT,
                default_path TEXT,
                nickname     TEXT,
                comment      TEXT,
                properties   TEXT NOT NULL DEFAULT '{}',
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL
            )
            """,
            "CREATE INDEX bookmark_hostname ON bookmark (hostname)",
        ]),
    ]

    /// The default location of the database file.
    public static var defaultDatabaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "DriverPro/DriverPro.sqlite")
    }

    /// Creates a store over an open database.
    ///
    /// The database is injected rather than opened here so the app can share one connection across
    /// stores, and tests can pass `.memory`.
    ///
    /// - Parameter database: A database migrated with at least ``migrations``.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Reading

    /// Loads every bookmark, sorted by display name.
    ///
    /// A row that cannot be mapped is skipped rather than thrown on — one bookmark corrupted by a hand
    /// edit or a bad import must not make the whole sidebar unusable.
    ///
    /// - Returns: The bookmarks found.
    /// - Throws: ``DatabaseError`` if the query itself fails.
    public func load() async throws -> [RemoteHost] {
        try await database.rows("SELECT * FROM bookmark")
            .compactMap(Self.makeHost)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Loads one bookmark.
    ///
    /// - Parameter id: Which bookmark.
    /// - Returns: The bookmark, or `nil` if there is none with that id.
    /// - Throws: ``DatabaseError`` if the query fails.
    public func load(_ id: UUID) async throws -> RemoteHost? {
        try await database.rows("SELECT * FROM bookmark WHERE id = ?", [SQLValue(id)])
            .compactMap(Self.makeHost)
            .first
    }

    // MARK: - Writing

    /// Saves a bookmark, replacing any earlier version of it.
    ///
    /// `created_at` survives an update, so "when did I first add this?" stays answerable.
    ///
    /// - Parameter host: The bookmark to write.
    /// - Throws: ``DatabaseError`` if the write fails.
    public func save(_ host: RemoteHost) async throws {
        let now = Date()
        let properties = Self.encodeProperties(host.properties)

        try await database.execute(
            """
            INSERT INTO bookmark
                (id, protocol, hostname, port, username, default_path, nickname, comment,
                 properties, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                protocol = excluded.protocol,
                hostname = excluded.hostname,
                port = excluded.port,
                username = excluded.username,
                default_path = excluded.default_path,
                nickname = excluded.nickname,
                comment = excluded.comment,
                properties = excluded.properties,
                updated_at = excluded.updated_at
            """,
            [
                SQLValue(host.id),
                SQLValue(host.protocolIdentifier.rawValue),
                SQLValue(host.hostname),
                SQLValue(host.port),
                SQLValue(host.username),
                SQLValue(host.defaultPath?.pathString),
                SQLValue(host.nickname),
                SQLValue(host.comment),
                SQLValue(properties),
                SQLValue(now),
                SQLValue(now),
            ]
        )
    }

    /// Deletes a bookmark. Deleting one that is not there succeeds.
    ///
    /// - Parameter id: Which bookmark to remove.
    /// - Throws: ``DatabaseError`` if the delete fails.
    public func delete(_ id: UUID) async throws {
        try await database.execute("DELETE FROM bookmark WHERE id = ?", [SQLValue(id)])
    }

    // MARK: - Interchange

    /// Writes every bookmark to a directory as one JSON file each.
    ///
    /// The readable, hand-editable, syncable form — kept as something you ask for rather than as a
    /// consequence of how storage happens to work. Also the backup story: a corrupt database loses
    /// everything, and this is what you restore from.
    ///
    /// - Parameter directory: Where to write. Created if missing.
    /// - Returns: How many bookmarks were written.
    /// - Throws: ``BookmarkError/fileUnavailable(path:reason:)`` if a file cannot be written.
    @discardableResult
    public func exportJSON(to directory: URL) async throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BookmarkError.fileUnavailable(path: directory.path, reason: error.localizedDescription)
        }

        let hosts = try await load()
        for host in hosts {
            let file = directory.appending(path: "\(host.id.uuidString).json")
            do {
                try encoder.encode(host).write(to: file, options: .atomic)
            } catch {
                throw BookmarkError.fileUnavailable(path: file.path, reason: error.localizedDescription)
            }
        }
        return hosts.count
    }

    /// Reads bookmarks from a directory of JSON files, saving each one.
    ///
    /// Existing bookmarks with the same id are replaced. Files that cannot be parsed are skipped, so one
    /// bad file does not abandon the import.
    ///
    /// - Parameter directory: Where to read from.
    /// - Returns: How many bookmarks were imported.
    /// - Throws: ``BookmarkError/fileUnavailable(path:reason:)`` if the directory cannot be listed.
    @discardableResult
    public func importJSON(from directory: URL) async throws -> Int {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw BookmarkError.fileUnavailable(path: directory.path, reason: error.localizedDescription)
        }

        var imported = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let host = try? JSONDecoder().decode(RemoteHost.self, from: data)
            else { continue }
            try await save(host)
            imported += 1
        }
        return imported
    }

    // MARK: - Cyberduck interchange

    /// Reads `.duck` files, saving every bookmark DriverPro can use.
    ///
    /// Accepts files and directories together, because both a picker and a drop can hand over either.
    /// A directory is scanned one level deep for `*.duck`, which is how Cyberduck lays its own out.
    ///
    /// Nothing throws for a bad file: one unreadable bookmark in a folder of twenty must not abandon
    /// the other nineteen, so failures are counted and returned instead.
    ///
    /// - Parameters:
    ///   - urls: Files or directories to read.
    ///   - supported: Protocols this build can connect with. Anything else is counted as unsupported
    ///     rather than imported — a bookmark that fails the moment it is clicked is worse than none.
    /// - Returns: What happened, in enough detail to tell the user.
    /// - Throws: ``BookmarkError/fileUnavailable(path:reason:)`` if a directory cannot be listed, or
    ///   ``DatabaseError`` if a write fails.
    @discardableResult
    public func importDuck(
        from urls: [URL],
        supported: Set<ProtocolIdentifier>
    ) async throws -> DuckImportSummary {
        var summary = DuckImportSummary()

        for file in try Self.duckFiles(in: urls) {
            guard let data = try? Data(contentsOf: file) else {
                summary.unreadable += 1
                continue
            }

            switch DuckFormat.decode(data, supported: supported) {
            case .bookmark(let host):
                try await save(host)
                summary.imported += 1
            case .unsupported(let identifier):
                summary.unsupported[identifier, default: 0] += 1
            case .unreadable:
                summary.unreadable += 1
            }
        }
        return summary
    }

    /// Writes every bookmark to a directory as one `.duck` file each.
    ///
    /// - Parameter directory: Where to write. Created if missing.
    /// - Returns: How many bookmarks were written.
    /// - Throws: ``BookmarkError/fileUnavailable(path:reason:)`` if a file cannot be written.
    @discardableResult
    public func exportDuck(to directory: URL) async throws -> Int {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BookmarkError.fileUnavailable(path: directory.path, reason: error.localizedDescription)
        }

        let hosts = try await load()
        var used: Set<String> = []

        for host in hosts {
            let file = directory.appending(path: Self.uniqueFileName(for: host, avoiding: &used))
            do {
                try DuckFormat.encode(host).write(to: file, options: .atomic)
            } catch {
                throw BookmarkError.fileUnavailable(path: file.path, reason: error.localizedDescription)
            }
        }
        return hosts.count
    }

    /// Writes one bookmark to one `.duck` file.
    ///
    /// The single-bookmark counterpart to ``exportDuck(to:)``, for sharing one connection rather than
    /// backing up all of them.
    ///
    /// - Parameters:
    ///   - host: The bookmark to write.
    ///   - file: Where to write it. Any existing file is replaced.
    /// - Throws: ``BookmarkError/fileUnavailable(path:reason:)`` if it cannot be written.
    public func exportDuck(_ host: RemoteHost, to file: URL) async throws {
        do {
            try DuckFormat.encode(host).write(to: file, options: .atomic)
        } catch {
            throw BookmarkError.fileUnavailable(path: file.path, reason: error.localizedDescription)
        }
    }

    /// Every `.duck` file among the given files and directories.
    private static func duckFiles(in urls: [URL]) throws -> [URL] {
        var files: [URL] = []

        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else {
                if url.pathExtension.lowercased() == DuckFormat.fileExtension { files.append(url) }
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)
                files += contents.filter { $0.pathExtension.lowercased() == DuckFormat.fileExtension }
            } catch {
                throw BookmarkError.fileUnavailable(path: url.path, reason: error.localizedDescription)
            }
        }
        return files
    }

    /// A file name no earlier bookmark in this export has taken.
    ///
    /// Two bookmarks may share a display name — the same server under two accounts, say — and the
    /// second must not overwrite the first.
    private static func uniqueFileName(for host: RemoteHost, avoiding used: inout Set<String>) -> String {
        let name = DuckFormat.fileName(for: host)
        guard used.contains(name) else {
            used.insert(name)
            return name
        }

        let stem = (name as NSString).deletingPathExtension
        for suffix in 2... {
            let candidate = "\(stem) \(suffix).\(DuckFormat.fileExtension)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
        }
        return name       // unreachable: the loop only ends by returning
    }

    // MARK: - Mapping

    /// Builds a bookmark from a row, or `nil` if the row is unusable.
    private static func makeHost(_ row: Row) -> RemoteHost? {
        guard let id = try? row.uuid("id"),
              let identifier = try? row.string("protocol"),
              let hostname = try? row.string("hostname"),
              let port = try? row.integer("port")
        else { return nil }

        return RemoteHost(
            id: id,
            protocolIdentifier: ProtocolIdentifier(rawValue: identifier),
            hostname: hostname,
            port: Int(port),
            username: row.optionalString("username"),
            defaultPath: row.optionalString("default_path").map(RemotePath.init),
            nickname: row.optionalString("nickname"),
            comment: row.optionalString("comment"),
            properties: decodeProperties(row.optionalString("properties"))
        )
    }

    /// The protocol-specific bag, as JSON.
    ///
    /// A column rather than a child table: the keys differ per protocol, nothing queries inside it, and
    /// SQLite's JSON functions are available if that ever changes.
    private static func encodeProperties(_ properties: [String: String]) -> String {
        guard !properties.isEmpty,
              let data = try? JSONEncoder().encode(properties),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private static func decodeProperties(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let properties = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return properties
    }
}
