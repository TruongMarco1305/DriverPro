//
//  SessionError.swift
//  DPCore
//

import Foundation

/// Everything that can go wrong while talking to a remote file system, expressed protocol-neutrally.
///
/// Backends translate their own failures into these cases. That translation is not busywork: it is what
/// lets the browser, the transfer queue, and the retry logic make decisions without a `switch` over four
/// protocols' private error types. The engine needs to answer "should I retry this?" and "should I ask
/// the user for a new password?" — not "what did SFTP status code 3 mean?".
///
/// The original error is kept in ``underlying`` wherever one exists, so nothing is lost for logging.
///
/// ## Swift note — `Error` and typed throws
/// Swift errors are just values conforming to `Error`. Swift 6 also allows *typed* throws
/// (`func f() throws(SessionError)`), which document exactly what a function can fail with. ``Session``
/// deliberately does not use them: a backend may need to propagate a transport error it cannot
/// meaningfully translate, and typed throws would force it to either lie or lose information.
public enum SessionError: Error, Hashable, Sendable {

    // MARK: - Connection and authentication

    /// An operation was attempted before ``Session/connect(_:delegate:)`` succeeded, or after the
    /// connection dropped. Not retryable without reconnecting first.
    case notConnected

    /// The host could not be reached: DNS failure, refused connection, or an unreachable network.
    /// Usually worth retrying.
    case unreachable(host: String, reason: String)

    /// The server rejected the credentials. Retrying with the same credentials is pointless; the caller
    /// should prompt via ``SessionDelegate/requestCredentials(_:)``.
    case authenticationFailed(reason: String)

    /// The user declined to trust the server's host key or TLS certificate. Never retry — this was a
    /// deliberate human decision, and possibly a narrowly avoided machine-in-the-middle attack.
    case hostKeyRejected

    /// The operation exceeded its time limit.
    case timedOut

    // MARK: - File system

    /// Nothing exists at the given path.
    case notFound(RemotePath)

    /// The server refused on permission grounds.
    case accessDenied(RemotePath)

    /// A file was found where a directory was required, or the reverse.
    case notADirectory(RemotePath)

    /// Creating or moving would overwrite something that already exists.
    case alreadyExists(RemotePath)

    /// A directory was expected to be empty and was not.
    case directoryNotEmpty(RemotePath)

    /// The server or account is out of space.
    case insufficientStorage

    // MARK: - Capability and protocol

    /// The backend does not support this operation at all.
    ///
    /// Reaching this case is a bug in the *caller*: it should have consulted
    /// ``Session/capabilities`` first and never offered the command. The error exists as a backstop, and
    /// carries the missing capability so the message can say which one.
    case unsupported(SessionCapabilities, operation: String)

    /// The server's response could not be understood — a malformed listing, an unexpected status code,
    /// a truncated reply. Worth reporting with detail, since it usually means a server quirk that
    /// DriverPro should learn to handle.
    case protocolViolation(String)

    /// A transport-level failure, wrapping whatever the underlying library reported.
    case transport(String)

    /// The operation was cancelled, normally because the user cancelled it or the parent task was
    /// cancelled. Never surface this as an error alert.
    case cancelled
}

// MARK: - Retry classification

extension SessionError {
    /// Whether retrying the same operation could plausibly succeed without user intervention.
    ///
    /// The transfer engine consults this before scheduling a backoff retry. A wrong `true` here wastes
    /// the user's time hammering a server that will never say yes; a wrong `false` fails a transfer that
    /// a two-second wait would have fixed.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .timedOut, .transport, .notConnected:
            true
        case .authenticationFailed, .hostKeyRejected, .notFound, .accessDenied,
             .notADirectory, .alreadyExists, .directoryNotEmpty, .insufficientStorage,
             .unsupported, .protocolViolation, .cancelled:
            false
        }
    }

    /// Whether recovering requires new credentials from the user.
    public var needsCredentials: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }
}

// MARK: - Presentation

extension SessionError: LocalizedError {
    /// A short sentence naming what failed, suitable as an alert's title.
    ///
    /// ## Swift note — `LocalizedError`
    /// Conforming to `LocalizedError` rather than only `Error` is what makes `error.localizedDescription`
    /// produce these strings. Without it, AppKit falls back to text like
    /// "The operation couldn't be completed. (DPCore.SessionError error 4.)", which is useless to a user.
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to the server."
        case .unreachable(let host, let reason):
            "Could not reach \(host): \(reason)"
        case .authenticationFailed(let reason):
            "Login failed: \(reason)"
        case .hostKeyRejected:
            "The server's identity was not accepted."
        case .timedOut:
            "The server did not respond in time."
        case .notFound(let path):
            "\(path.name) does not exist on the server."
        case .accessDenied(let path):
            "You do not have permission to access \(path.name)."
        case .notADirectory(let path):
            "\(path.name) is not a folder."
        case .alreadyExists(let path):
            "\(path.name) already exists."
        case .directoryNotEmpty(let path):
            "\(path.name) is not empty."
        case .insufficientStorage:
            "There is not enough space on the server."
        case .unsupported(_, let operation):
            "This server does not support \(operation)."
        case .protocolViolation(let detail):
            "The server sent an unexpected response: \(detail)"
        case .transport(let detail):
            "The connection failed: \(detail)"
        case .cancelled:
            "The operation was cancelled."
        }
    }

    /// What the user might do about it, shown as an alert's informative text.
    public var recoverySuggestion: String? {
        switch self {
        case .notConnected, .unreachable:
            "Check your network connection and the server address, then try again."
        case .authenticationFailed:
            "Check your user name and password, then try again."
        case .hostKeyRejected:
            "Connect again and accept the server's key if you trust it."
        case .timedOut:
            "The server may be busy. Try again in a moment."
        case .accessDenied:
            "Ask the server administrator to grant you access."
        case .alreadyExists:
            "Choose a different name."
        case .directoryNotEmpty:
            "Delete the folder's contents first."
        case .insufficientStorage:
            "Free up space on the server, then try again."
        default:
            nil
        }
    }
}
