//
//  POSIXPermissions.swift
//  DPCore
//

import Foundation

/// A Unix permission mode — the `rwxr-xr-x` shown in the browser's Permissions column.
///
/// Only backends advertising ``SessionCapabilities/posixPermissions`` produce meaningful values here.
/// S3 and most consumer cloud storage have no such concept, so their items carry `nil` instead of a
/// fabricated `rw-r--r--`. Inventing a plausible-looking value would be worse than showing nothing: it
/// implies the user can change it.
public struct POSIXPermissions: Hashable, Sendable, Codable {

    // MARK: - Access

    /// The read/write/execute bits for one class of user.
    ///
    /// ## Swift note — `OptionSet`
    /// `OptionSet` is how Swift models a C-style bit flag field with type safety. The raw value is a
    /// single integer whose bits each mean one thing, but you write `[.read, .write]` and get set
    /// algebra — `contains`, `union`, `subtracting` — instead of `&` and `|`. `SessionCapabilities`
    /// uses the same pattern on a larger scale.
    public struct Access: OptionSet, Hashable, Sendable, Codable {
        /// The three permission bits, in the conventional `rwx` layout.
        public let rawValue: UInt8

        /// Creates an access set from raw permission bits.
        /// - Parameter rawValue: A three-bit value in the conventional `rwx` layout.
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Permission to read a file's contents, or to list a directory.
        public static let read = Access(rawValue: 0b100)
        /// Permission to modify a file, or to create and delete entries in a directory.
        public static let write = Access(rawValue: 0b010)
        /// Permission to execute a file, or to traverse *into* a directory.
        ///
        /// The directory meaning is the one that surprises people: without `x` on a directory you cannot
        /// reach anything inside it even when you can list its names.
        public static let execute = Access(rawValue: 0b001)

        /// The `rwx` fragment for this access set, using `-` for absent bits.
        public var symbolicString: String {
            (contains(.read) ? "r" : "-")
                + (contains(.write) ? "w" : "-")
                + (contains(.execute) ? "x" : "-")
        }
    }

    // MARK: - Storage

    /// The permission bits, including the setuid/setgid/sticky bits. Only the low 12 bits are used.
    public let rawValue: UInt16

    // MARK: - Creating a mode

    /// Creates permissions from a raw mode value.
    ///
    /// File-type bits above the low 12 are masked away, so it is safe to pass a full `st_mode` from a
    /// `stat` call straight in.
    ///
    /// - Parameter rawValue: A mode value such as `0o755`.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue & 0o7777
    }

    /// Creates permissions from the three access classes.
    ///
    /// - Parameters:
    ///   - owner: What the file's owner may do.
    ///   - group: What members of the file's group may do.
    ///   - other: What everybody else may do.
    public init(owner: Access, group: Access, other: Access) {
        self.rawValue = UInt16(owner.rawValue) << 6
            | UInt16(group.rawValue) << 3
            | UInt16(other.rawValue)
    }

    /// Parses an octal permission string such as `"755"` or `"0644"`.
    ///
    /// Returns `nil` if the string is not valid octal or exceeds four digits — this is the initialiser
    /// behind the Permissions field in the Info panel, where users type freely.
    ///
    /// - Parameter octalString: Three or four octal digits.
    public init?(octalString: String) {
        let trimmed = octalString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 4,
              let value = UInt16(trimmed, radix: 8)
        else { return nil }
        self.init(rawValue: value)
    }

    // MARK: - Access classes

    /// What the file's owner may do.
    public var owner: Access { Access(rawValue: UInt8((rawValue >> 6) & 0b111)) }
    /// What members of the file's group may do.
    public var group: Access { Access(rawValue: UInt8((rawValue >> 3) & 0b111)) }
    /// What everybody else may do.
    public var other: Access { Access(rawValue: UInt8(rawValue & 0b111)) }

    // MARK: - Special bits

    /// Run the file as its owner rather than as the invoking user.
    public var isSetUID: Bool { rawValue & 0o4000 != 0 }
    /// Run as the file's group; on a directory, new entries inherit that group.
    public var isSetGID: Bool { rawValue & 0o2000 != 0 }
    /// On a directory, only an entry's owner may delete it — the `/tmp` rule.
    public var isSticky: Bool { rawValue & 0o1000 != 0 }

    // MARK: - Display

    /// The mode as three octal digits, or four when a special bit is set. For example `"755"`, `"1777"`.
    public var octalString: String {
        let special = (rawValue >> 9) & 0b111
        let base = String(rawValue & 0o777, radix: 8)
        let padded = String(repeating: "0", count: max(0, 3 - base.count)) + base
        return special == 0 ? padded : String(special, radix: 8) + padded
    }

    /// The nine-character `ls -l` style string, for example `"rwxr-xr-x"`.
    ///
    /// Special bits replace the matching execute character exactly as `ls` renders them: `s` where
    /// execute is also set, uppercase `S` where it is not, and `t`/`T` for the sticky bit.
    public var symbolicString: String {
        var owner = Array(self.owner.symbolicString)
        var group = Array(self.group.symbolicString)
        var other = Array(self.other.symbolicString)

        if isSetUID { owner[2] = self.owner.contains(.execute) ? "s" : "S" }
        if isSetGID { group[2] = self.group.contains(.execute) ? "s" : "S" }
        if isSticky { other[2] = self.other.contains(.execute) ? "t" : "T" }

        return String(owner + group + other)
    }
}

// MARK: - Common modes

extension POSIXPermissions {
    /// `644` — the usual mode for an uploaded file.
    public static let defaultFile = POSIXPermissions(rawValue: 0o644)
    /// `755` — the usual mode for a created directory.
    public static let defaultDirectory = POSIXPermissions(rawValue: 0o755)
}

extension POSIXPermissions: CustomStringConvertible {
    /// Both renderings together, as `"rwxr-xr-x (755)"`, for logs and the Info panel.
    public var description: String { "\(symbolicString) (\(octalString))" }
}
