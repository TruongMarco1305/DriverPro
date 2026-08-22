//
//  TransferJournal.swift
//  DPTransfer
//

import DPCore
import DPDatabase
import Foundation

/// A transfer that was still unfinished when the app last stopped.
public struct StoredTransfer: Sendable, Identifiable {

    /// What to run again.
    public let transfer: Transfer
    /// What it was called in the list.
    public let title: String
    /// How far it had got, as of the last file it finished.
    public let report: TransferReport
    /// When it was first queued.
    public let queuedAt: Date

    /// The transfer's identity.
    public var id: UUID { transfer.id }

    /// Creates a restored transfer.
    ///
    /// - Parameters:
    ///   - transfer: What to run again.
    ///   - title: Name for the list.
    ///   - report: Counters as of the last completed file.
    ///   - queuedAt: When it was first queued.
    public init(transfer: Transfer, title: String, report: TransferReport, queuedAt: Date) {
        self.transfer = transfer
        self.title = title
        self.report = report
        self.queuedAt = queuedAt
    }
}

/// Remembers transfers that have not finished, so a quit does not lose them.
///
/// **The rule: a record exists if and only if the transfer is unfinished.** Written when it starts,
/// removed when it ends — completed, failed or cancelled alike. Quitting is the only path that leaves
/// one behind, which makes "what was interrupted?" the same question as "what is still recorded?"
/// There is no state to keep in step, and nothing to prune. See `docs/decisions/010-queue-persistence.md`.
///
/// A protocol so the queue names no storage: tests use an in-memory double, the app uses SQLite. Same
/// seam as `CredentialStore` — see `docs/swift-notes.md`, section 24.
public protocol TransferJournal: Sendable {

    /// Records a transfer as unfinished.
    ///
    /// - Parameters:
    ///   - transfer: What is being moved.
    ///   - title: What to call it in the list.
    /// - Throws: If the record cannot be written.
    func record(_ transfer: Transfer, title: String) async throws

    /// Updates how far a transfer has got. Unknown ids are ignored.
    ///
    /// - Parameters:
    ///   - id: Which transfer.
    ///   - report: Counters so far.
    /// - Throws: If the write fails.
    func updateCounters(for id: UUID, report: TransferReport) async throws

    /// Removes a transfer's record, because it has ended. Unknown ids are ignored.
    ///
    /// - Parameter id: Which transfer.
    /// - Throws: If the delete fails.
    func forget(_ id: UUID) async throws

    /// Every transfer still recorded, oldest first.
    ///
    /// - Returns: What was interrupted.
    /// - Throws: If the query fails.
    func unfinished() async throws -> [StoredTransfer]
}

/// The journal, in the shared database.
public actor SQLiteTransferJournal: TransferJournal {

    private let database: Database

    /// Schema this journal needs.
    ///
    /// Version 2: numbers are global to the database, not per-table, so this follows
    /// `BookmarkStore.migrations` version 1 rather than starting again.
    public static let migrations: [Migration] = [
        Migration(version: 2, statements: [
            """
            CREATE TABLE transfer (
                id          TEXT PRIMARY KEY NOT NULL,
                host_id     TEXT NOT NULL,
                title       TEXT NOT NULL,
                payload     TEXT NOT NULL,
                transferred INTEGER NOT NULL DEFAULT 0,
                skipped     INTEGER NOT NULL DEFAULT 0,
                failed      INTEGER NOT NULL DEFAULT 0,
                bytes       INTEGER NOT NULL DEFAULT 0,
                created_at  REAL NOT NULL,
                updated_at  REAL NOT NULL
            )
            """,
            "CREATE INDEX transfer_host ON transfer (host_id)",
        ]),
    ]

    /// Creates a journal over an open database.
    /// - Parameter database: A database migrated with at least ``migrations``.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Writing

    /// Records a transfer as unfinished, replacing any earlier record of the same id.
    ///
    /// Replacing matters for resume: running a restored transfer records it again under the id it
    /// already had, and two rows for one transfer would restore it twice.
    ///
    /// - Parameters:
    ///   - transfer: What is being moved.
    ///   - title: What to call it in the list.
    /// - Throws: ``DatabaseError`` if the write fails, or an encoding error if the transfer cannot be
    ///   serialised.
    public func record(_ transfer: Transfer, title: String) async throws {
        let payload = try JSONEncoder().encode(transfer)
        let now = Date()

        try await database.execute(
            """
            INSERT INTO transfer (id, host_id, title, payload, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                payload = excluded.payload,
                updated_at = excluded.updated_at
            """,
            [
                SQLValue(transfer.id), SQLValue(transfer.host.id), SQLValue(title),
                SQLValue(String(decoding: payload, as: UTF8.self)), SQLValue(now), SQLValue(now),
            ]
        )
    }

    /// Updates the counters. Called once per finished file, never per chunk.
    /// - Parameters:
    ///   - id: Which transfer.
    ///   - report: Counters so far.
    /// - Throws: ``DatabaseError`` if the write fails.
    public func updateCounters(for id: UUID, report: TransferReport) async throws {
        try await database.execute(
            """
            UPDATE transfer
               SET transferred = ?, skipped = ?, failed = ?, bytes = ?, updated_at = ?
             WHERE id = ?
            """,
            [
                SQLValue(report.transferred), SQLValue(report.skipped), SQLValue(report.failed),
                .integer(report.bytes), SQLValue(Date()), SQLValue(id),
            ]
        )
    }

    /// Removes a transfer's record.
    /// - Parameter id: Which transfer.
    /// - Throws: ``DatabaseError`` if the delete fails.
    public func forget(_ id: UUID) async throws {
        try await database.execute("DELETE FROM transfer WHERE id = ?", [SQLValue(id)])
    }

    // MARK: - Reading

    /// Every transfer still recorded, oldest first.
    ///
    /// A row whose payload will not decode is skipped rather than thrown on: one transfer written by an
    /// older build must not make the rest unrestorable. Same forgiveness as `BookmarkStore.load()`.
    ///
    /// - Returns: What was interrupted.
    /// - Throws: ``DatabaseError`` if the query itself fails.
    public func unfinished() async throws -> [StoredTransfer] {
        try await database.rows("SELECT * FROM transfer ORDER BY created_at ASC")
            .compactMap(Self.makeStoredTransfer)
    }

    private static func makeStoredTransfer(_ row: Row) -> StoredTransfer? {
        guard let payload = row.optionalString("payload"),
              let transfer = try? JSONDecoder().decode(Transfer.self, from: Data(payload.utf8)),
              let title = row.optionalString("title"),
              let queuedAt = try? row.date("created_at") else { return nil }

        let report = TransferReport(
            transferred: Int((try? row.integer("transferred")) ?? 0),
            skipped: Int((try? row.integer("skipped")) ?? 0),
            failed: Int((try? row.integer("failed")) ?? 0),
            bytes: (try? row.integer("bytes")) ?? 0
        )
        return StoredTransfer(transfer: transfer, title: title, report: report, queuedAt: queuedAt)
    }
}
