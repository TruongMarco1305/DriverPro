//
//  SFTPErrorMapping.swift
//  DPProtocolSFTP
//

import Citadel
import DPCore
import Foundation

/// Translates Citadel and SFTP protocol errors into ``SessionError``.
///
/// This translation is the reason the layers above can make decisions. The transfer engine needs to
/// answer "should I retry this?" and the UI needs "should I re-prompt for a password?" — neither should
/// have to know that SFTP status code 3 means permission denied, and neither will, once the four
/// protocols are in place and each has done this job for itself.
enum SFTPErrorMapping {

    /// Maps any error thrown by Citadel into a protocol-neutral ``SessionError``.
    ///
    /// - Parameters:
    ///   - error: The error Citadel threw.
    ///   - path: The path being operated on, for errors that name one.
    /// - Returns: The equivalent `SessionError`. Anything unrecognised becomes
    ///   ``SessionError/transport(_:)`` rather than being swallowed.
    static func map(_ error: any Error, path: RemotePath? = nil) -> SessionError {
        // Already translated — do not wrap twice.
        if let sessionError = error as? SessionError { return sessionError }

        // Cancellation must stay cancellation all the way up, or the UI shows an error alert for
        // something the user deliberately stopped.
        if error is CancellationError { return .cancelled }

        if let sftpError = error as? SFTPError { return map(sftpError, path: path) }

        // Citadel throws `SFTPMessage.Status` *directly* for a failed operation, not wrapped in
        // `SFTPError.errorStatus`. Missing this case was a real bug: every "no such file" arrived as an
        // opaque `.transport("{1}(code: SSH_FX_NO_SUCH_FILE…)")`, so the layers above could not tell a
        // missing file from a dropped connection. Found by running against a real server — no amount of
        // reading the headers would have shown it.
        if let status = error as? SFTPMessage.Status {
            return map(status: status.errorCode, message: status.message, path: path)
        }

        return .transport(String(describing: error))
    }

    /// Maps Citadel's own error enum.
    private static func map(_ error: SFTPError, path: RemotePath?) -> SessionError {
        switch error {
        case .errorStatus(let status):
            return map(status: status.errorCode, message: status.message, path: path)

        case .connectionClosed, .noResponseTarget, .missingResponse:
            return .notConnected

        case .fileHandleInvalid:
            return .protocolViolation("the server invalidated a file handle mid-operation")

        case .unknownMessage, .invalidResponse, .invalidPayload, .unsupportedVersion:
            return .protocolViolation(String(describing: error))
        }
    }

    /// Maps an SFTP status code.
    ///
    /// The mapping is deliberately conservative around ``SFTPStatusCode/failure``: SFTP v3 uses code 4
    /// as a catch-all, so servers report "directory not empty", "disk full", and "already exists" all
    /// through it. The human-readable message is the only way to tell them apart, and matching on it is
    /// unavoidable — but it is inherently fuzzy, so it is done here in one place where it can be
    /// corrected as real servers reveal their wording.
    ///
    /// - Parameters:
    ///   - status: The SFTP status code.
    ///   - message: The server's message, used to disambiguate `failure`.
    ///   - path: The path being operated on.
    /// - Returns: The closest matching `SessionError`.
    static func map(status: SFTPStatusCode, message: String, path: RemotePath?) -> SessionError {
        let path = path ?? .root

        switch status {
        case .ok, .eof:
            // Not errors. Reaching here means a caller treated a normal status as a failure.
            return .protocolViolation("unexpected success status treated as an error")

        case .noSuchFile:
            return .notFound(path)

        case .permissionDenied:
            return .accessDenied(path)

        case .noConnection, .connectionLost:
            return .notConnected

        case .badMessage:
            return .protocolViolation(message.isEmpty ? "malformed message" : message)

        case .unsupportedOperation:
            return .unsupported([], operation: message.isEmpty ? "this operation" : message)

        case .failure, .unknown:
            return mapCatchAll(message: message, path: path)
        }
    }

    /// Disambiguates SFTP's catch-all failure using the server's message text.
    private static func mapCatchAll(message: String, path: RemotePath) -> SessionError {
        let text = message.lowercased()

        if text.contains("not empty") {
            return .directoryNotEmpty(path)
        }
        if text.contains("exists") {
            return .alreadyExists(path)
        }
        if text.contains("no space") || text.contains("quota") || text.contains("disk full") {
            return .insufficientStorage
        }
        if text.contains("permission") || text.contains("denied") {
            return .accessDenied(path)
        }
        if text.contains("not a directory") || text.contains("is a directory") {
            return .notADirectory(path)
        }

        return .transport(message.isEmpty ? "the server reported a failure" : message)
    }

    // MARK: - Connection errors

    /// Maps an error thrown while establishing the SSH connection, before SFTP starts.
    ///
    /// Authentication failures must be distinguished from network failures: the first should re-prompt
    /// for credentials, the second should offer a retry. Getting this wrong means a user with a typo in
    /// their password watches the app retry a server that will never say yes.
    ///
    /// - Parameters:
    ///   - error: The error thrown by `SSHClient.connect`.
    ///   - hostname: The host being connected to, for the message.
    /// - Returns: The equivalent `SessionError`.
    static func mapConnectionError(_ error: any Error, hostname: String) -> SessionError {
        if let sessionError = error as? SessionError { return sessionError }
        if error is CancellationError { return .cancelled }

        // A refused login surfaces as `SSHClientError.allAuthenticationOptionsFailed` — SSH does not
        // report *why* it refused, only that every method it was willing to try was exhausted.
        // Confirmed by pointing the spike at a real server with a wrong password; the previously
        // assumed `CitadelError.unauthorized` is never thrown on this path.
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed:
                return .authenticationFailed(reason: "the server rejected the credentials")
            case .unsupportedPasswordAuthentication:
                return .authenticationFailed(reason: "the server does not accept password authentication")
            case .unsupportedPrivateKeyAuthentication:
                return .authenticationFailed(reason: "the server does not accept this key type")
            case .unsupportedHostBasedAuthentication:
                return .authenticationFailed(reason: "the server does not accept host-based authentication")
            case .channelCreationFailed:
                return .transport("the SSH channel could not be opened")
            }
        }

        if let citadelError = error as? CitadelError {
            switch citadelError {
            case .unauthorized:
                return .authenticationFailed(reason: "the server rejected the credentials")
            default:
                return .transport(String(describing: citadelError))
            }
        }

        // Everything else at this stage is the network: DNS failure, refused connection, timeout.
        return .unreachable(host: hostname, reason: friendlyReason(for: error))
    }

    /// Extracts a readable reason from a transport error.
    ///
    /// NIO's errors describe themselves reasonably; `localizedDescription` on a plain Swift `Error` does
    /// not, and produces "The operation couldn't be completed" instead.
    private static func friendlyReason(for error: any Error) -> String {
        let description = String(describing: error)
        if description.contains("connectTimeout") || description.contains("timed out") {
            return "the connection timed out"
        }
        if description.contains("Connection refused") || description.contains("ECONNREFUSED") {
            return "the connection was refused"
        }
        if description.contains("nodename nor servname") || description.contains("Name or service not known") {
            return "the host name could not be found"
        }
        return description
    }
}
