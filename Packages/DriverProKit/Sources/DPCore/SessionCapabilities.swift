//
//  SessionCapabilities.swift
//  DPCore
//

import Foundation

/// What a backend can actually do.
///
/// This is the type that keeps DriverPro honest. Remote storage systems differ *in kind*, not merely in
/// detail, and pretending otherwise is how file managers end up with menu items that fail at the moment
/// you click them:
///
/// - **S3** has no rename. Moving an object is a server-side copy followed by a delete, which is not
///   atomic and costs a request per object. It has no POSIX permissions and no true empty directories —
///   a "folder" is a shared key prefix that exists only while something sits under it.
/// - **FTP** has no dependable `stat`. Listing formats are server-specific and often lack a year on
///   older timestamps.
/// - **WebDAV** has `MOVE`, but resumable uploads only if the server implements a non-standard extension.
///
/// Two rules follow, and they are not optional:
///
/// 1. **The UI reads capabilities to enable or disable commands.** A greyed-out Rename with a tooltip
///    explaining why beats an error alert after the fact.
/// 2. **The transfer engine reads capabilities to choose a strategy.** No ``resumeUpload`` means restart
///    from zero rather than issuing an append that the server will silently mishandle.
///
/// ## Swift note — `OptionSet` at scale
/// Same mechanism as ``POSIXPermissions/Access``, one bit per capability in a `UInt32`. It gives set
/// algebra (`contains`, `isSuperset(of:)`, `subtracting`) over what is physically one integer, so a
/// capability check costs a bitwise AND rather than a dictionary lookup. Declaring the raw values as
/// explicit shifts (`1 << 4`) instead of literals makes the bit position obvious and makes it hard to
/// reuse one by accident.
public struct SessionCapabilities: OptionSet, Hashable, Sendable {

    /// The packed capability bits. One bit per capability; see the static members below.
    public let rawValue: UInt32

    /// Creates a capability set from its raw bit pattern.
    /// - Parameter rawValue: The packed capability bits.
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // MARK: - Namespace operations

    /// The backend can rename or move an entry in one atomic operation.
    ///
    /// Absent on S3, where a move is copy-then-delete and can leave both or neither copy behind if the
    /// connection drops in between.
    public static let rename = SessionCapabilities(rawValue: 1 << 0)

    /// The backend can copy server-side, without routing the bytes through this machine.
    ///
    /// Present on S3 (`CopyObject`) and WebDAV (`COPY`); absent on plain SFTP, where a copy means
    /// downloading and re-uploading.
    public static let serverSideCopy = SessionCapabilities(rawValue: 1 << 1)

    /// Directories can exist while empty.
    ///
    /// Absent on S3: a prefix with nothing under it is not visible, so a newly created "folder" vanishes
    /// on refresh unless the app writes a zero-byte placeholder object.
    public static let emptyDirectories = SessionCapabilities(rawValue: 1 << 2)

    /// A directory can be deleted together with its contents in a single request.
    ///
    /// When absent, the engine must walk the tree depth-first and delete each entry itself.
    public static let recursiveDelete = SessionCapabilities(rawValue: 1 << 3)

    /// The backend understands symbolic links.
    public static let symbolicLinks = SessionCapabilities(rawValue: 1 << 4)

    // MARK: - Metadata

    /// Entries carry Unix permission bits that can be read and written.
    public static let posixPermissions = SessionCapabilities(rawValue: 1 << 5)

    /// The modification timestamp of an entry can be set explicitly.
    ///
    /// This is what allows a downloaded file to keep the remote file's date rather than taking the time
    /// of the transfer.
    public static let timestamps = SessionCapabilities(rawValue: 1 << 6)

    /// Entries have an owning user and group that can be read and changed.
    public static let ownership = SessionCapabilities(rawValue: 1 << 7)

    /// The backend keeps multiple versions of an entry.
    public static let versioning = SessionCapabilities(rawValue: 1 << 8)

    /// The backend can report how much space is used and available.
    public static let quota = SessionCapabilities(rawValue: 1 << 9)

    // MARK: - Transfer

    /// A download can start at an arbitrary byte offset, so an interrupted one can be continued.
    public static let resumeDownload = SessionCapabilities(rawValue: 1 << 10)

    /// An upload can continue into an existing partial file rather than restarting.
    public static let resumeUpload = SessionCapabilities(rawValue: 1 << 11)

    /// One file can be transferred over several connections at once.
    ///
    /// Worth it for high-latency links and large files; pointless — and rude — against a small server
    /// that limits concurrent connections.
    public static let segmentedTransfer = SessionCapabilities(rawValue: 1 << 12)

    /// A file's checksum can be obtained from the server for post-transfer verification.
    public static let checksum = SessionCapabilities(rawValue: 1 << 13)

    // MARK: - Common groupings

    /// The minimum any backend must support: list, read, write, delete. Represented by the empty set,
    /// since these are not optional and so have no bit of their own.
    public static let none: SessionCapabilities = []

    /// What a full POSIX-style file server such as SFTP typically offers.
    public static let posixFileSystem: SessionCapabilities = [
        .rename, .emptyDirectories, .recursiveDelete, .symbolicLinks,
        .posixPermissions, .timestamps, .ownership,
        .resumeDownload, .resumeUpload,
    ]
}

// MARK: - Diagnostics

extension SessionCapabilities: CustomStringConvertible {
    /// A readable list of the capabilities present, for logs and test failure messages.
    ///
    /// Without this, a failing assertion prints `SessionCapabilities(rawValue: 3169)`, which tells you
    /// nothing about which bit was wrong.
    public var description: String {
        let names: [(SessionCapabilities, String)] = [
            (.rename, "rename"),
            (.serverSideCopy, "serverSideCopy"),
            (.emptyDirectories, "emptyDirectories"),
            (.recursiveDelete, "recursiveDelete"),
            (.symbolicLinks, "symbolicLinks"),
            (.posixPermissions, "posixPermissions"),
            (.timestamps, "timestamps"),
            (.ownership, "ownership"),
            (.versioning, "versioning"),
            (.quota, "quota"),
            (.resumeDownload, "resumeDownload"),
            (.resumeUpload, "resumeUpload"),
            (.segmentedTransfer, "segmentedTransfer"),
            (.checksum, "checksum"),
        ]
        let present = names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "[]" : "[\(present.joined(separator: ", "))]"
    }
}
