//
//  Migration.swift
//  DPDatabase
//

import Foundation

/// One numbered step in the schema's history.
///
/// Migrations are ordered and additive, and the applied version is recorded in SQLite's `user_version`
/// pragma — a four-byte integer in the file header that exists for exactly this purpose, so no bespoke
/// version table is needed.
///
/// Every migration runs inside a transaction: it applies completely or not at all, and a failure leaves
/// the schema at its previous version rather than half-changed.
///
/// **Migrations are append-only.** Editing one that has already run means a database in the wild has a
/// schema that no longer matches its recorded version. Add a new one instead.
public struct Migration: Sendable {

    /// Schema version this step produces. Must be greater than zero and increase across the list.
    public let version: Int

    /// Statements to run, in order.
    public let statements: [String]

    /// Creates a migration.
    ///
    /// - Parameters:
    ///   - version: The version this step produces.
    ///   - statements: SQL to run, in order.
    public init(version: Int, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}
