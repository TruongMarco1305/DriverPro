//
//  RemoteItem.swift
//  DPCore
//

import Foundation

/// One entry in a remote directory listing — a file, a directory, or a symbolic link.
///
/// Every field except ``path`` and ``kind`` is optional, and that is the type doing its job. Backends
/// genuinely differ in what they report:
///
/// | | size | modified | permissions | owner |
/// |---|---|---|---|---|
/// | SFTP | ✓ | ✓ | ✓ | ✓ |
/// | WebDAV | ✓ | ✓ | — | — |
/// | S3 | ✓ | ✓ | — | — |
/// | FTP (`LIST`) | ✓ | approximate | sometimes | sometimes |
///
/// An optional forces every caller to decide what to show when a value is missing, instead of quietly
/// displaying `0 bytes` or `1 Jan 1970` for something the server never sent.
public struct RemoteItem: Hashable, Sendable, Identifiable {

    // MARK: - Kind

    /// What sort of entry this is.
    ///
    /// ## Swift note — enums with associated values
    /// `symbolicLink` carries its target path alongside the case itself. This is a *sum type*: a link is
    /// not a file with an extra field, it is its own kind of thing that happens to also have a target.
    /// The compiler then makes `switch` exhaustive, so adding a case later surfaces every site that must
    /// handle it rather than silently falling through a default.
    public enum Kind: Hashable, Sendable {
        /// A regular file.
        case file
        /// A directory that can be listed.
        case directory
        /// A symbolic link. The target is `nil` when the server reported a link without resolving it.
        case symbolicLink(target: RemotePath?)

        /// `true` for directories. Links are *not* treated as directories here — resolve the link first
        /// with ``Session/stat(_:)`` if you need to know what it points at.
        public var isDirectory: Bool { self == .directory }
    }

    // MARK: - Stored properties

    /// Where this item lives. Doubles as its identity.
    public var path: RemotePath

    /// Whether this is a file, a directory, or a link.
    public var kind: Kind

    /// Size in bytes, or `nil` when the server did not report one — and always `nil` for a directory.
    ///
    /// A directory's reported size is its own inode: SFTP says 4 KB for every folder on a typical Linux
    /// server, which is true and useless. It is not the size of the contents, so showing it invites
    /// exactly the wrong reading, and the enforcing happens here rather than in each backend.
    ///
    /// `Int64` rather than `Int` because a 32-bit `Int` cannot hold the size of a large file, and
    /// rather than `UInt64` because arithmetic on unsigned sizes traps on underflow the first time you
    /// subtract a progress value from a total.
    public var size: Int64?

    /// Last-modified timestamp, or `nil` when unavailable.
    ///
    /// Precision varies by protocol: SFTP gives whole seconds, FTP's `LIST` output is often only accurate
    /// to the minute and may omit the year. Never compare two of these for exact equality when deciding
    /// whether to re-transfer — allow a tolerance.
    public var modifiedAt: Date?

    /// Unix permission bits, or `nil` on backends with no POSIX permission model.
    public var permissions: POSIXPermissions?

    /// Owning user name, or `nil` if not reported.
    public var owner: String?

    /// Owning group name, or `nil` if not reported.
    public var group: String?

    /// Protocol-specific metadata that does not belong in the common model.
    ///
    /// Examples: S3 storage class, ETag, and version id; WebDAV's `getcontenttype`. Keeping these in a
    /// side dictionary is what stops `RemoteItem` from growing a field for every backend's quirks — the
    /// alternative is a model that is 80% `nil` for every protocol. Keys are namespaced by protocol, as
    /// in `"s3.storageClass"`.
    public var extra: [String: String]

    // MARK: - Initialisation

    /// Creates a directory entry.
    ///
    /// - Parameters:
    ///   - path: The item's location.
    ///   - kind: File, directory, or symbolic link.
    ///   - size: Size in bytes, if known. Ignored for directories.
    ///   - modifiedAt: Last-modified date, if known.
    ///   - permissions: POSIX mode, if the backend has one.
    ///   - owner: Owning user name, if reported.
    ///   - group: Owning group name, if reported.
    ///   - extra: Protocol-specific metadata.
    public init(
        path: RemotePath,
        kind: Kind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        permissions: POSIXPermissions? = nil,
        owner: String? = nil,
        group: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.path = path
        self.kind = kind
        self.size = kind.isDirectory ? nil : size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.extra = extra
    }

    // MARK: - Convenience

    /// Stable identity for SwiftUI lists and diffing: an item *is* its path.
    ///
    /// Deliberately not a `UUID`. Re-listing a directory creates fresh `RemoteItem` values, and if
    /// identity were random the browser would animate every row as a deletion plus an insertion on each
    /// refresh instead of updating in place.
    public var id: RemotePath { path }

    /// The item's display name — the final path component.
    public var name: String { path.name }

    /// `true` when the name begins with a dot.
    public var isHidden: Bool { path.isHidden }

    /// `true` for directories, ignoring unresolved symbolic links.
    public var isDirectory: Bool { kind.isDirectory }

}
