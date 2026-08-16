//
//  SQLValue.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPDatabase is the persistence layer: one SQLite connection, migrations, and typed access to rows.
//  It knows nothing about bookmarks, transfers, or any DriverPro model.
//
//  It may import Foundation and SQLite3. It may NOT import SwiftUI, AppKit, or any DP* target — which is
//  what lets DPBookmarks and (in M2) DPTransfer both sit on top of it without a cycle.
//

import Foundation

/// One of SQLite's five storage classes.
///
/// SQLite is dynamically typed: a column has an *affinity*, not a fixed type. This enum is the Swift
/// side of that, so binding and reading go through one exhaustive `switch` rather than a pile of
/// overloads.
public enum SQLValue: Hashable, Sendable {
    /// SQL `NULL`. Distinct from an empty string, which is why optionals map here rather than to `""`.
    case null
    /// A 64-bit signed integer.
    case integer(Int64)
    /// A double.
    case real(Double)
    /// UTF-8 text.
    case text(String)
    /// Raw bytes.
    case blob(Data)
}

// MARK: - Convenience construction

extension SQLValue {
    /// Wraps an integer.
    /// - Parameter value: The number to store.
    public init(_ value: Int) { self = .integer(Int64(value)) }

    /// Wraps a string, mapping `nil` to SQL `NULL`.
    ///
    /// One overload covers both: a non-optional `String` promotes, and `NULL` stays distinct from `""`.
    /// - Parameter value: The text to store, if any.
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }

    /// Wraps a date as seconds since 1970, which sorts correctly in SQL.
    /// - Parameter value: The date to store.
    public init(_ value: Date) { self = .real(value.timeIntervalSince1970) }

    /// Wraps a UUID as its string form, so rows stay readable in a SQLite browser.
    /// - Parameter value: The identifier to store.
    public init(_ value: UUID) { self = .text(value.uuidString) }
}

// MARK: - Row

/// One result row, as plain values.
///
/// A `Sendable` value type on purpose. `Database` is an actor, and returning rows as values means
/// nothing tied to the connection — no statement handle, no cursor — escapes it. The cost is that a
/// result set is materialised in memory rather than streamed, which is the right trade at the scale
/// this application queries and the wrong one for a million-row report.
public struct Row: Hashable, Sendable {

    /// The row's columns, keyed by name.
    public let values: [String: SQLValue]

    /// Creates a row.
    /// - Parameter values: Column values, keyed by column name.
    public init(values: [String: SQLValue]) {
        self.values = values
    }

    /// The raw value in a column, or `nil` if the column is not in the result set.
    /// - Parameter column: The column name.
    public subscript(column: String) -> SQLValue? { values[column] }

    // MARK: Typed access

    /// Reads a non-null string.
    ///
    /// - Parameter column: The column name.
    /// - Returns: The text.
    /// - Throws: ``DatabaseError/unexpectedType(column:expected:)`` if the column is missing or not text.
    public func string(_ column: String) throws -> String {
        guard case .text(let value)? = values[column] else {
            throw DatabaseError.unexpectedType(column: column, expected: "TEXT")
        }
        return value
    }

    /// Reads a string that may be `NULL`.
    /// - Parameter column: The column name.
    public func optionalString(_ column: String) -> String? {
        if case .text(let value)? = values[column] { return value }
        return nil
    }

    /// Reads a non-null integer.
    ///
    /// - Parameter column: The column name.
    /// - Returns: The number.
    /// - Throws: ``DatabaseError/unexpectedType(column:expected:)`` if the column is missing or not an
    ///   integer.
    public func integer(_ column: String) throws -> Int64 {
        guard case .integer(let value)? = values[column] else {
            throw DatabaseError.unexpectedType(column: column, expected: "INTEGER")
        }
        return value
    }

    /// Reads a non-null double.
    ///
    /// - Parameter column: The column name.
    /// - Returns: The number.
    /// - Throws: ``DatabaseError/unexpectedType(column:expected:)`` if the column is missing or not real.
    public func real(_ column: String) throws -> Double {
        guard case .real(let value)? = values[column] else {
            throw DatabaseError.unexpectedType(column: column, expected: "REAL")
        }
        return value
    }

    /// Reads a date stored as seconds since 1970.
    ///
    /// - Parameter column: The column name.
    /// - Returns: The date.
    /// - Throws: ``DatabaseError/unexpectedType(column:expected:)`` if the column is not real.
    public func date(_ column: String) throws -> Date {
        Date(timeIntervalSince1970: try real(column))
    }

    /// Reads a UUID stored as text.
    ///
    /// - Parameter column: The column name.
    /// - Returns: The identifier.
    /// - Throws: ``DatabaseError/unexpectedType(column:expected:)`` if the text is not a valid UUID.
    public func uuid(_ column: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(column)) else {
            throw DatabaseError.unexpectedType(column: column, expected: "UUID")
        }
        return value
    }
}

// MARK: - Statement

/// A statement and the values to bind into it.
///
/// Used by ``Database/transaction(_:)`` to describe a batch. Bindings are always separate from the SQL —
/// interpolating values into the text is how SQL injection happens, and prepared statements are faster
/// besides.
public struct SQL: Sendable {

    /// The statement text, with `?` placeholders.
    public let text: String
    /// Values for the placeholders, in order.
    public let bindings: [SQLValue]

    /// Creates a statement.
    ///
    /// - Parameters:
    ///   - text: SQL with `?` placeholders.
    ///   - bindings: Values for those placeholders.
    public init(_ text: String, _ bindings: [SQLValue] = []) {
        self.text = text
        self.bindings = bindings
    }
}
