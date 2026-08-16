//
//  DPCredentials.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPCredentials owns secrets and trust: where passwords are stored, which servers we have decided to
//  believe, and where SSH private keys live.
//
//  It owns:
//    • `KeychainStore`      — passwords and passphrases, via Security.framework
//    • `KnownHostsStore`    — reading and appending ~/.ssh/known_hosts
//    • `HostKeyFingerprint` — OpenSSH-format SHA256 fingerprints
//    • `PrivateKeyLocator`  — finding and classifying keys in ~/.ssh
//
//  It may import: Foundation, Security, CryptoKit, and DPCore.
//  It may NOT import: SwiftUI, AppKit, Citadel, NIO, or any DPProtocol* target.
//
//  Note what is absent from that list: no third-party code touches the user's passwords. Security and
//  CryptoKit are Apple's, shipped with the OS. That is a deliberate constraint, not an accident of
//  what was convenient.
//
//  This target is protocol-agnostic on purpose. It deals in key *blobs* (`Data`) and host/port pairs,
//  never in NIOSSH or Citadel types, so the SFTP backend can hand it bytes without this target growing
//  a dependency on an SSH library. WebDAV and S3 will reuse `KeychainStore` unchanged.
//

import Foundation

/// Errors from the credential layer.
///
/// Kept separate from `SessionError` because these are local failures — a Keychain that refused, a file
/// that could not be read — rather than anything a server said. `SFTPSession` translates the ones that
/// need to reach the user.
public enum CredentialError: Error, Hashable, Sendable {

    /// The Keychain refused an operation. Carries the raw `OSStatus` for diagnosis.
    ///
    /// Common values: `-25300` (`errSecItemNotFound`), `-25299` (`errSecDuplicateItem`),
    /// `-128` (`errSecUserCanceled`, meaning the user dismissed the unlock prompt).
    case keychain(status: Int32, operation: String)

    /// A file could not be read or written.
    case fileAccess(path: String, reason: String)

    /// A private key was found but is not in a format we can use.
    case unsupportedKeyFormat(path: String)
}

extension CredentialError: LocalizedError {
    /// A message naming what failed, without leaking the secret involved.
    public var errorDescription: String? {
        switch self {
        case .keychain(let status, let operation):
            "The keychain refused to \(operation) (error \(status))."
        case .fileAccess(let path, let reason):
            "Could not access \(path): \(reason)"
        case .unsupportedKeyFormat(let path):
            "The key at \(path) is in an unsupported format."
        }
    }
}
