//
//  KeychainStoreTests.swift
//  DPCredentialsTests
//

import DPCore
import Foundation
import Security
import Testing
@testable import DPCredentials

/// Tests that touch the real login Keychain.
///
/// Gated behind `DP_KEYCHAIN_TESTS=1` because they write to the user's actual Keychain — and on a
/// locked or headless machine `SecItemAdd` can raise an unlock prompt that blocks the test run
/// indefinitely. A default `swift test` must never hang waiting for a dialog.
///
/// ```sh
/// DP_KEYCHAIN_TESTS=1 swift test --filter KeychainStore
/// ```
///
/// ## Swift note — conditional test traits
/// `.enabled(if:)` is a *trait*: Swift Testing evaluates it before running, and reports skipped tests
/// as skipped rather than passed. That distinction matters — a suite that silently passes because it
/// never ran is worse than one that fails.
@Suite(
    "KeychainStore",
    .enabled(if: ProcessInfo.processInfo.environment["DP_KEYCHAIN_TESTS"] == "1",
             "set DP_KEYCHAIN_TESTS=1 to run tests that write to the login Keychain")
)
struct KeychainStoreTests {

    /// A throwaway bookmark on a `.invalid` host, so a stray item cannot collide with a genuine one.
    ///
    /// - Parameter port: The port, which is part of the item's Keychain identity.
    private static func makeHost(port: Int = 2222) -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: "driverpro-test-\(UUID().uuidString.prefix(8)).invalid",
            port: port,
            username: "tester"
        )
    }

    /// Runs a test body and then removes whatever it left in the Keychain, pass or fail.
    ///
    /// ## Swift note — why not `defer { Task { … } }`
    /// The obvious cleanup is a `defer` that fires off a `Task`. Swift 6 rejects it, and it is right to:
    /// a detached task is *fire and forget*, so the test can finish before the deletion runs, leaving
    /// stray items in the user's Keychain. Awaiting the cleanup inline makes it deterministic — and the
    /// error the compiler gave was about capturing a mutable local, which is the same problem wearing a
    /// different hat.
    ///
    /// - Parameters:
    ///   - hosts: Bookmarks whose passwords should be deleted afterwards.
    ///   - body: The test body, given a store.
    private func withCleanup(
        hosts: [RemoteHost],
        _ body: (KeychainStore) async throws -> Void
    ) async throws {
        let store = KeychainStore()
        do {
            try await body(store)
        } catch {
            for host in hosts { try? await store.removePassword(for: host) }
            throw error
        }
        for host in hosts { try? await store.removePassword(for: host) }
    }

    @Test("A password survives a write and read")
    func roundTrip() async throws {
        let host = Self.makeHost()
        try await withCleanup(hosts: [host]) { store in
            #expect(try await store.password(for: host) == nil)

            try await store.setPassword("hunter2", for: host)
            #expect(try await store.password(for: host) == "hunter2")
        }
    }

    @Test("Writing twice updates rather than duplicating")
    func updateReplaces() async throws {
        let host = Self.makeHost()
        try await withCleanup(hosts: [host]) { store in
            try await store.setPassword("first", for: host)
            try await store.setPassword("second", for: host)

            // SecItemAdd fails with errSecDuplicateItem rather than replacing, so this asserts the
            // update-then-add fallback actually works in that order.
            #expect(try await store.password(for: host) == "second")
        }
    }

    @Test("Deleting removes the item, and deleting again is not an error")
    func deleteIsIdempotent() async throws {
        let host = Self.makeHost()
        try await withCleanup(hosts: [host]) { store in
            try await store.setPassword("secret", for: host)
            try await store.removePassword(for: host)
            #expect(try await store.password(for: host) == nil)

            // The caller wanted it gone, and it is.
            try await store.removePassword(for: host)
        }
    }

    @Test("Two hosts differing only by port keep separate passwords")
    func portIsPartOfIdentity() async throws {
        // Built as two immutable values rather than one copied and mutated: the port is part of the
        // item's Keychain identity, so this is checking that identity is honoured.
        let base = Self.makeHost(port: 2222)
        var other = base
        other.port = 2223
        let second = other

        try await withCleanup(hosts: [base, second]) { store in
            try await store.setPassword("port-2222", for: base)
            try await store.setPassword("port-2223", for: second)

            #expect(try await store.password(for: base) == "port-2222")
            #expect(try await store.password(for: second) == "port-2223")
        }
    }

    @Test("Key passphrases round-trip independently of server passwords")
    func passphraseRoundTrip() async throws {
        let store = KeychainStore(serviceLabelPrefix: "DriverProTest")
        let path = "/tmp/driverpro-test-\(UUID().uuidString)/id_ed25519"

        #expect(try await store.passphrase(forPrivateKeyAt: path) == nil)
        try await store.setPassphrase("key-secret", forPrivateKeyAt: path)
        #expect(try await store.passphrase(forPrivateKeyAt: path) == "key-secret")

        try await store.removePassphrase(forPrivateKeyAt: path)
        #expect(try await store.passphrase(forPrivateKeyAt: path) == nil)
    }
}

/// Query construction, which needs no Keychain access and so always runs.
@Suite("KeychainStore queries")
struct KeychainQueryTests {

    @Test("Protocols map to the Keychain constants other tools expect")
    func protocolMapping() {
        // `ssh` and Cyberduck look for kSecAttrProtocolSSH specifically. Getting this wrong produces an
        // item that works for us and is invisible to everything else.
        #expect(KeychainStore.protocolAttribute(for: .sftp) == kSecAttrProtocolSSH)
        #expect(KeychainStore.protocolAttribute(for: .ftp) == kSecAttrProtocolFTP)
        #expect(KeychainStore.protocolAttribute(for: .webdav) == kSecAttrProtocolHTTPS)
        #expect(KeychainStore.protocolAttribute(for: .s3) == kSecAttrProtocolHTTPS)
    }

    @Test("An unrecognised protocol falls back to HTTPS rather than failing")
    func unknownProtocolFallsBack() {
        let custom = ProtocolIdentifier(rawValue: "some-future-protocol")
        #expect(KeychainStore.protocolAttribute(for: custom) == kSecAttrProtocolHTTPS)
    }

    @Test("The keychain label is the readable URL form")
    func labelFormat() {
        let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 2222, username: "duck")
        #expect(host.keychainService == "sftp://example.com:2222")
        #expect(host.keychainAccount == "duck")
    }
}
