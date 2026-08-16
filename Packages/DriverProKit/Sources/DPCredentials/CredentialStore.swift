//
//  CredentialStore.swift
//  DPCredentials
//

import DPCore
import Foundation

/// Somewhere passwords are kept.
///
/// `KeychainStore` is the real implementation. The protocol exists so that code wiring credentials into
/// a connection can be tested without the system Keychain — a test that writes to the user's real
/// Keychain is one that pollutes their machine and prompts for unlock on a locked one.
///
/// Only passwords are here. Private key passphrases stay on ``KeychainStore`` directly, because nothing
/// in the connection flow needs to fake them yet.
public protocol CredentialStore: Sendable {

    /// The stored password for a connection, or `nil` if none is saved.
    ///
    /// - Parameter host: The connection to look up.
    /// - Returns: The password, if one is stored.
    /// - Throws: If the store refuses the lookup.
    func password(for host: RemoteHost) async throws -> String?

    /// Saves or replaces a password.
    ///
    /// Call only after the server has accepted it — storing an unverified password produces a bookmark
    /// that silently fails forever.
    ///
    /// - Parameters:
    ///   - password: The secret to store.
    ///   - host: The connection it belongs to.
    /// - Throws: If the store refuses the write.
    func setPassword(_ password: String, for host: RemoteHost) async throws

    /// Removes a stored password. Removing one that is absent succeeds.
    ///
    /// - Parameter host: The connection to forget.
    /// - Throws: If the store refuses the delete.
    func removePassword(for host: RemoteHost) async throws
}

/// `KeychainStore` already has exactly this shape, so conformance adds nothing but the declaration.
extension KeychainStore: CredentialStore {}
