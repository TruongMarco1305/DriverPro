//
//  PrivateKeyLocatorTests.swift
//  DPCredentialsTests
//

import Foundation
import Testing
@testable import DPCredentials

@Suite("PrivateKeyLocator")
struct PrivateKeyLocatorTests {

    private let anyURL = URL(fileURLWithPath: "/Users/test/.ssh/id_ed25519")

    @Test("An unencrypted OpenSSH key needs no passphrase")
    func detectsUnencryptedOpenSSHKey() throws {
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.unencryptedOpenSSHKey, at: anyURL))
        #expect(key.format == .openSSH)
        #expect(!key.isEncrypted)
    }

    @Test("An encrypted OpenSSH key is detected from its cipher field")
    func detectsEncryptedOpenSSHKey() throws {
        // The headers of the two OpenSSH fixtures are byte-identical — the difference is `aes256-ctr`
        // versus `none` inside the base64 body. Searching the text for "ENCRYPTED" finds nothing here,
        // which is precisely the bug this test exists to prevent.
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.encryptedOpenSSHKey, at: anyURL))
        #expect(key.format == .openSSH)
        #expect(key.isEncrypted)
    }

    @Test("The two OpenSSH fixtures really do have identical headers")
    func headersAreIndistinguishable() {
        let firstLine = { (text: String) in String(text.split(separator: "\n")[0]) }
        #expect(firstLine(Fixtures.unencryptedOpenSSHKey) == firstLine(Fixtures.encryptedOpenSSHKey))
    }

    @Test("A classic PEM key advertises encryption in the clear")
    func detectsEncryptedPEM() throws {
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.encryptedPEMKey, at: anyURL))
        #expect(key.format == .pem)
        #expect(key.isEncrypted)
    }

    @Test("Text that is not a private key is rejected", arguments: [
        "",
        "just some text",
        "ssh-ed25519 AAAAC3Nz… user@host",          // a *public* key
        "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
    ])
    func rejectsNonKeys(_ contents: String) {
        #expect(PrivateKeyLocator.inspect(contents: contents, at: anyURL) == nil)
    }

    @Test("A truncated OpenSSH body is treated as unencrypted rather than crashing")
    func handlesTruncatedBody() throws {
        // Reading a length field from bytes that are not there is exactly how a parser reads past the
        // end of a buffer. Returning false is the safe answer: attempting without a passphrase gives a
        // clearer error than prompting for one that may not be needed.
        let truncated = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n-----END OPENSSH PRIVATE KEY-----"
        let key = try #require(PrivateKeyLocator.inspect(contents: truncated, at: anyURL))
        #expect(!key.isEncrypted)
    }

    // MARK: - Discovery

    @Test("Discovery finds conventional key names and ignores everything else")
    func discoversConventionalKeys() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Fixtures.unencryptedOpenSSHKey.write(
            to: directory.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try Fixtures.encryptedPEMKey.write(
            to: directory.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
        // Files that live in ~/.ssh but are not private keys.
        try "ssh-ed25519 AAAA test".write(
            to: directory.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        try "Host *\n  User me".write(
            to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let keys = PrivateKeyLocator(sshDirectory: directory).discoverKeys()

        #expect(keys.count == 2)
        // Ed25519 first: the order is what the key picker offers, and the stronger algorithm should be
        // the default suggestion.
        #expect(keys.map(\.name) == ["id_ed25519", "id_rsa"])
        #expect(keys[0].isEncrypted == false)
        #expect(keys[1].isEncrypted == true)
    }

    @Test("A directory with no keys yields an empty list, not an error")
    func emptyDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(PrivateKeyLocator(sshDirectory: missing).discoverKeys().isEmpty)
    }
}
