//
//  Transfer.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPTransfer moves bytes between the local disk and a remote file system: connection pooling, recursive
//  enumeration, bounded concurrency, progress, cancellation.
//
//  It may import Foundation, DPCore. It may NOT import SwiftUI, AppKit, or any DPProtocol* target — it
//  reaches backends only through `Session` and `SessionFactory`.
//

import DPCore
import Foundation

/// What to do when a file already exists at the destination.
public enum OverwritePolicy: Hashable, Sendable {
    /// Replace it.
    case overwrite
    /// Leave it alone and count the item as skipped.
    case skip
    /// Write alongside it as `name 2.txt`, `name 3.txt`, and so on.
    case rename
    /// Continue an interrupted transfer from the existing size.
    ///
    /// Falls back to ``overwrite`` when the backend lacks the matching resume capability, since appending
    /// to a server that cannot seek would corrupt the file.
    case resume
}

/// One queued job: a set of files to move in one direction, for one connection.
public struct Transfer: Identifiable, Sendable {

    /// The direction, and what is being moved.
    ///
    /// An enum rather than two optional pairs of fields, so a download with a remote destination or an
    /// upload with no source cannot be constructed.
    public enum Work: Sendable {
        /// Remote entries to fetch into a local directory.
        case download(sources: [RemotePath], destination: URL)
        /// Local files or folders to send into a remote directory.
        case upload(sources: [URL], destination: RemotePath)
    }

    /// Identity, used to cancel and to tag events.
    public let id: UUID
    /// The connection to run on.
    public let host: RemoteHost
    /// Direction and endpoints.
    public let work: Work
    /// What to do about existing files.
    public let overwritePolicy: OverwritePolicy

    /// Creates a transfer.
    ///
    /// - Parameters:
    ///   - id: Identity. Defaults to a fresh `UUID`.
    ///   - host: The connection to run on.
    ///   - work: Direction and endpoints.
    ///   - overwritePolicy: What to do about existing files. Defaults to ``OverwritePolicy/overwrite``.
    public init(
        id: UUID = UUID(),
        host: RemoteHost,
        work: Work,
        overwritePolicy: OverwritePolicy = .overwrite
    ) {
        self.id = id
        self.host = host
        self.work = work
        self.overwritePolicy = overwritePolicy
    }

    /// Whether this transfer reads from the server or writes to it.
    public var isDownload: Bool {
        if case .download = work { return true }
        return false
    }
}

/// One file or directory within a transfer, paired with where it lands.
public struct TransferItem: Identifiable, Hashable, Sendable {

    /// The remote side, whether that is the source or the destination.
    public let remote: RemotePath
    /// The local side.
    public let local: URL
    /// `true` when this entry only needs creating, not copying.
    public let isDirectory: Bool
    /// Size in bytes when known. Directories and unsized servers report `nil`.
    public let size: Int64?

    /// Identity within a transfer. The remote path is unique on both sides of a transfer.
    public var id: RemotePath { remote }

    /// Creates an item.
    ///
    /// - Parameters:
    ///   - remote: The remote path.
    ///   - local: The local URL.
    ///   - isDirectory: Whether this is a directory.
    ///   - size: Size in bytes, if known.
    public init(remote: RemotePath, local: URL, isDirectory: Bool, size: Int64? = nil) {
        self.remote = remote
        self.local = local
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// How one item ended.
public enum ItemOutcome: Hashable, Sendable {
    /// Moved, with the number of bytes written.
    case transferred(bytes: Int64)
    /// Left alone because of ``OverwritePolicy/skip``.
    case skipped
    /// Failed. The transfer continues with the remaining items.
    case failed(SessionError)
}

/// The tally a transfer ends with.
public struct TransferReport: Hashable, Sendable {
    /// Files moved.
    public var transferred: Int = 0
    /// Files left alone.
    public var skipped: Int = 0
    /// Files that failed.
    public var failed: Int = 0
    /// Total bytes written.
    public var bytes: Int64 = 0
    /// Whether the run was cancelled before finishing.
    public var wasCancelled: Bool = false

    /// Why the transfer could not start at all, if it could not.
    ///
    /// Set only for whole-transfer failures such as a refused connection — the case where planning every
    /// source would produce the same error. A single unreadable *file* is counted in ``failed`` instead,
    /// and does not stop the rest.
    public var failure: SessionError?

    /// Whether everything that was attempted succeeded.
    public var isSuccess: Bool { failed == 0 && failure == nil && !wasCancelled }

    /// Creates a report.
    ///
    /// Swift synthesises a memberwise initialiser, but it is `internal` for a `public` struct — so
    /// without this, nothing outside `DPTransfer` could build one, including tests and any UI wanting a
    /// placeholder.
    ///
    /// - Parameters:
    ///   - transferred: Files moved.
    ///   - skipped: Files left alone.
    ///   - failed: Files that failed.
    ///   - bytes: Total bytes written.
    ///   - wasCancelled: Whether the run was stopped early.
    ///   - failure: Why the transfer could not start at all, if it could not.
    public init(
        transferred: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        bytes: Int64 = 0,
        wasCancelled: Bool = false,
        failure: SessionError? = nil
    ) {
        self.transferred = transferred
        self.skipped = skipped
        self.failed = failed
        self.bytes = bytes
        self.wasCancelled = wasCancelled
        self.failure = failure
    }
}

/// What the UI observes while a transfer runs.
///
/// A stream of events rather than a delegate, matching how ``Session/read(_:from:)`` already streams.
/// `DPTransfer` must not know a main thread exists, so it publishes facts and lets the app decide how to
/// display them.
public enum TransferEvent: Sendable {
    /// Enumeration finished and the totals are known.
    ///
    /// Always the first event, including when nothing could be planned — a UI that sizes a progress bar
    /// from this can rely on seeing it.
    case planned(items: Int, bytes: Int64?)
    /// A file started moving.
    case itemStarted(TransferItem)
    /// Cumulative bytes across the whole transfer.
    case progress(bytes: Int64, of: Int64?)
    /// A file finished, one way or another.
    case itemFinished(TransferItem, ItemOutcome)
    /// The run ended. Exactly one of these, always last.
    case finished(TransferReport)
}
