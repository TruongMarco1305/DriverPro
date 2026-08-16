//
//  DatabaseError.swift
//  DPDatabase
//

import Foundation

/// Failures from the database layer.
public enum DatabaseError: Error, Hashable, Sendable {

    /// The database file could not be opened or created.
    case openFailed(path: String, message: String)

    /// SQLite refused a statement. Carries its result code and message, which are far more useful than
    /// a generic "query failed" when the cause is a constraint or a typo.
    case statementFailed(code: Int32, message: String, sql: String)

    /// A column was missing, or held a different storage class than the caller asked for.
    case unexpectedType(column: String, expected: String)

    /// A migration failed. The schema is left at its previous version, not half-applied.
    case migrationFailed(version: Int, message: String)
}

extension DatabaseError: LocalizedError {
    /// A message naming what failed and what SQLite said about it.
    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let message):
            "Could not open the database at \(path): \(message)"
        case .statementFailed(let code, let message, _):
            "The database rejected a statement (\(code)): \(message)"
        case .unexpectedType(let column, let expected):
            "Column \(column) is missing or is not \(expected)."
        case .migrationFailed(let version, let message):
            "Database migration \(version) failed: \(message)"
        }
    }
}
