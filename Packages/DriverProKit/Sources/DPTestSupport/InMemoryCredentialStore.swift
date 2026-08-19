//
//  InMemoryCredentialStore.swift
//  DPTestSupport
//

import DPCore
import DPCredentials
import Foundation

/// A `CredentialStore` that keeps passwords and key passphrases in memory.
///
/// Lets the connection flow be tested end to end without touching the user's Keychain. The real
/// `KeychainStore` is still covered by its own opt-in suite; what is proven here is the *wiring* —
/// whether a stored secret prevents a prompt.
public actor InMemoryCredentialStore: CredentialStore {

    private var passwords: [UUID: String] = [:]

    /// Passphrases keyed by key file path, matching how the Keychain addresses them.
    private var passphrases: [String: String] = [:]

    /// How many times a password has been read, so tests can assert the store was consulted.
    ///
    /// Also used the other way round: an agent connection must never look a password up, and the only
    /// way to prove a call did *not* happen is to count.
    public private(set) var readCount = 0

    /// How many times a passphrase has been read.
    public private(set) var passphraseReadCount = 0

    /// Creates an empty store.
    /// - Parameters:
    ///   - passwords: Passwords to start with, keyed by bookmark id.
    ///   - passphrases: Passphrases to start with, keyed by key file path.
    public init(passwords: [UUID: String] = [:], passphrases: [String: String] = [:]) {
        self.passwords = passwords
        self.passphrases = passphrases
    }

    /// The stored password, counting the lookup so tests can assert the store was consulted.
    public func password(for host: RemoteHost) async throws -> String? {
        readCount += 1
        return passwords[host.id]
    }

    /// Stores a password in memory.
    public func setPassword(_ password: String, for host: RemoteHost) async throws {
        passwords[host.id] = password
    }

    /// Forgets a password. Removing one that is absent succeeds.
    public func removePassword(for host: RemoteHost) async throws {
        passwords[host.id] = nil
    }

    /// Whether anything is stored for a bookmark, without counting as a read.
    /// - Parameter host: The connection to check.
    public func hasPassword(for host: RemoteHost) -> Bool {
        passwords[host.id] != nil
    }

    // MARK: - Passphrases

    /// The stored passphrase, counting the lookup so tests can assert the store was consulted.
    public func passphrase(forPrivateKeyAt path: String) async throws -> String? {
        passphraseReadCount += 1
        return passphrases[path]
    }

    /// Stores a passphrase in memory.
    public func setPassphrase(_ passphrase: String, forPrivateKeyAt path: String) async throws {
        passphrases[path] = passphrase
    }

    /// Forgets a passphrase. Removing one that is absent succeeds.
    public func removePassphrase(forPrivateKeyAt path: String) async throws {
        passphrases[path] = nil
    }

    /// Whether a passphrase is stored for a key, without counting as a read.
    /// - Parameter path: The key file's path.
    public func hasPassphrase(forPrivateKeyAt path: String) -> Bool {
        passphrases[path] != nil
    }
}
