//
//  SFTPAttributeMapping.swift
//  DPProtocolSFTP
//

import Citadel
import DPCore
import Foundation

/// Converts between SFTP's wire attributes and DriverPro's model types.
///
/// Kept apart from `SFTPSession` because it is pure, total, and therefore testable without a server —
/// which is what lets the trickiest conversions (file-type bits, missing fields) be covered by ordinary
/// offline unit tests.
enum SFTPAttributeMapping {

    // MARK: - File type bits

    /// Mask selecting the file-type bits of a Unix mode. `S_IFMT` in `<sys/stat.h>`.
    ///
    /// SFTP packs the file type and the permission bits into one `UInt32`, so the same field answers
    /// both "is this a directory?" and "who may write to it?".
    static let typeMask: UInt32 = 0xF000

    /// Directory. `S_IFDIR`.
    static let typeDirectory: UInt32 = 0x4000
    /// Symbolic link. `S_IFLNK`.
    static let typeSymbolicLink: UInt32 = 0xA000

    /// Determines what kind of entry a mode describes.
    ///
    /// Defaults to ``RemoteItem/Kind/file`` when the server sent no permissions at all. That is the safer
    /// guess: treating an unknown entry as a file means a failed download, whereas treating it as a
    /// directory means the browser navigates into something that cannot be listed.
    ///
    /// - Parameter mode: The raw mode from `SFTPFileAttributes.permissions`, or `nil` if absent.
    /// - Returns: The entry kind.
    static func kind(fromMode mode: UInt32?) -> RemoteItem.Kind {
        guard let mode else { return .file }

        switch mode & typeMask {
        case typeDirectory: return .directory
        // The target is unresolved: a plain listing does not include it, and resolving every link would
        // cost a round trip per entry. `stat` follows the link when the target actually matters.
        case typeSymbolicLink: return .symbolicLink(target: nil)
        default: return .file
        }
    }

    // MARK: - Attributes to model

    /// Builds a ``RemoteItem`` from SFTP attributes.
    ///
    /// - Parameters:
    ///   - attributes: The attributes the server sent.
    ///   - path: Where the entry lives.
    /// - Returns: The populated item. Fields the server omitted stay `nil` rather than being invented.
    static func item(from attributes: SFTPFileAttributes, at path: RemotePath) -> RemoteItem {
        RemoteItem(
            path: path,
            kind: kind(fromMode: attributes.permissions),
            size: attributes.size.map(Int64.init),
            modifiedAt: attributes.accessModificationTime?.modificationTime,
            permissions: attributes.permissions.map { POSIXPermissions(rawValue: UInt16($0 & 0o7777)) },
            owner: attributes.uidgid.map { String($0.userId) },
            group: attributes.uidgid.map { String($0.groupId) },
            extra: [:]
        )
    }

    // MARK: - Model to attributes

    /// Builds SFTP attributes carrying only a permission change.
    ///
    /// SFTP's `SETSTAT` applies exactly the fields whose flags are set, so sending only the permissions
    /// leaves size and timestamps untouched.
    ///
    /// - Parameter permissions: The mode to apply.
    /// - Returns: Attributes with only the permission field populated.
    static func attributes(forPermissions permissions: POSIXPermissions) -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(permissions.rawValue)
        return attributes
    }

    /// Builds SFTP attributes carrying only a modification-time change.
    ///
    /// SFTP sets access and modification time together — there is one flag for the pair — so the access
    /// time is set to the same value rather than being left alone. Preserving it would need a `stat`
    /// first, and no part of DriverPro reads access times.
    ///
    /// - Parameter date: The modification time to apply.
    /// - Returns: Attributes with only the time field populated.
    static func attributes(forModificationDate date: Date) -> SFTPFileAttributes {
        SFTPFileAttributes(
            accessModificationTime: SFTPFileAttributes.AccessModificationTime(
                accessTime: date,
                modificationTime: date
            )
        )
    }
}
