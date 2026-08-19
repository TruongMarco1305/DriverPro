//
//  CredentialStore.swift
//  DPCredentials
//

import DPCore
import Foundation

/// Somewhere secrets are kept.
///
/// `KeychainStore` is the real implementation. The protocol exists so that code wiring credentials into
/// a connection can be tested without the system Keychain — a test that writes to the user's real
/// Keychain is one that pollutes their machine and prompts for unlock on a locked one.
///
/// Passphrases sit alongside passwords here because the connection flow now reaches for both: choosing
/// public key authentication means a passphrase lookup on the same path a password lookup takes, and a
/// seam that covers only half of it cannot test the half that matters.
///
/// Note the two different addressing schemes, which is why these are six methods and not three
/// generic ones. A password belongs to a *connection*, so it is keyed by ``RemoteHost``. A passphrase
/// belongs to a *key file*, which several connections may share, so it is keyed by that file's path.
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

    /// The stored passphrase for a private key, or `nil` if none is saved.
    ///
    /// - Parameter path: The key file's path, which is how the item is addressed.
    /// - Returns: The passphrase, if one is stored.
    /// - Throws: If the store refuses the lookup.
    func passphrase(forPrivateKeyAt path: String) async throws -> String?

    /// Saves or replaces a key's passphrase.
    ///
    /// Call only once the passphrase has actually unlocked a key the server then accepted. A wrong
    /// passphrase saved here is worse than none: the next connection uses it without asking, fails,
    /// and gives the user nothing to correct.
    ///
    /// - Parameters:
    ///   - passphrase: The secret to store.
    ///   - path: The key file's path.
    /// - Throws: If the store refuses the write.
    func setPassphrase(_ passphrase: String, forPrivateKeyAt path: String) async throws

    /// Removes a stored passphrase. Removing one that is absent succeeds.
    ///
    /// - Parameter path: The key file's path.
    /// - Throws: If the store refuses the delete.
    func removePassphrase(forPrivateKeyAt path: String) async throws
}

/// `KeychainStore` already has exactly this shape, so conformance adds nothing but the declaration.
extension KeychainStore: CredentialStore {}
