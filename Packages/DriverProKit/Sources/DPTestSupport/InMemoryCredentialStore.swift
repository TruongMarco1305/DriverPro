//
//  InMemoryCredentialStore.swift
//  DPTestSupport
//

import DPCore
import DPCredentials
import Foundation

/// A `CredentialStore` that keeps passwords in memory.
///
/// Lets the connection flow be tested end to end without touching the user's Keychain. The real
/// `KeychainStore` is still covered by its own opt-in suite; what is proven here is the *wiring* —
/// whether a stored password prevents a prompt.
public actor InMemoryCredentialStore: CredentialStore {

    private var passwords: [UUID: String] = [:]

    /// How many times a password has been read, so tests can assert the store was consulted.
    public private(set) var readCount = 0

    /// Creates an empty store.
    /// - Parameter passwords: Passwords to start with, keyed by bookmark id.
    public init(passwords: [UUID: String] = [:]) {
        self.passwords = passwords
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
}
